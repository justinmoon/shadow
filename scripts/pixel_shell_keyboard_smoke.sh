#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
run_dir="$(pixel_prepare_named_run_dir "$(pixel_shell_runs_dir)")"
guest_run_dir="$run_dir/guest"
run_log="$run_dir/pixel-shell-keyboard-smoke.log"
session_output_path="$guest_run_dir/session-output.txt"
state_after_launch_path="$run_dir/state-after-launch.json"
control_socket_path="$(pixel_shell_control_socket_path)"
startup_timeout_secs="${PIXEL_SHELL_SMOKE_STARTUP_TIMEOUT_SECS:-600}"
restore_timeout_secs="${PIXEL_SHELL_SMOKE_RESTORE_TIMEOUT_SECS:-60}"
session_pid=""
latest_state_json=""
latest_panel_point_json=""

dump_run_log() {
  if [[ -f "$run_log" ]]; then
    printf '\n== pixel-shell-keyboard-smoke log ==\n' >&2
    sed -n '1,260p' "$run_log" >&2
  fi
  if [[ -f "$session_output_path" ]]; then
    printf '\n== pixel-shell-keyboard-smoke session output ==\n' >&2
    sed -n '1,260p' "$session_output_path" >&2
  fi
}

cleanup() {
  restore_android_best_effort
  if [[ -n "${session_pid:-}" ]]; then
    wait "$session_pid" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

session_still_running() {
  if [[ -n "${session_pid:-}" ]] && kill -0 "$session_pid" >/dev/null 2>&1; then
    return 0
  fi

  if pixel_root_socket_exists "$serial" "$control_socket_path"; then
    return 0
  fi

  pixel_root_process_exists "$serial" "$(basename "$(pixel_compositor_dst)")"
}

capture_state_json() {
  local output
  if ! session_still_running; then
    return 1
  fi
  if ! output="$("$SCRIPT_DIR/shadowctl" --target "$serial" state --json 2>/dev/null)"; then
    return 1
  fi
  latest_state_json="$output"
}

shell_control_socket_ready() {
  pixel_root_socket_exists "$serial" "$control_socket_path"
}

session_output_has_marker() {
  local marker="$1"
  [[ -f "$session_output_path" ]] && grep -Fq "$marker" "$session_output_path"
}

wait_for_checkpoint() {
  local description="$1"
  local timeout_secs="$2"
  shift 2

  local deadline=$((SECONDS + timeout_secs))
  while (( SECONDS < deadline )); do
    if "$@"; then
      return 0
    fi
    if ! session_still_running; then
      dump_run_log
      echo "pixel-shell-keyboard-smoke: session exited before ${description}" >&2
      exit 1
    fi
    sleep 1
  done

  if "$@"; then
    return 0
  fi

  dump_run_log
  echo "pixel-shell-keyboard-smoke: timed out waiting for ${description}" >&2
  exit 1
}

capture_target_panel_point() {
  local target_id="$1"
  local output
  if ! session_still_running || [[ ! -f "$session_output_path" ]]; then
    return 1
  fi
  if ! output="$(
    SESSION_OUTPUT_PATH="$session_output_path" \
    TARGET_ID="$target_id" \
    python3 - <<'PY'
import json
import os
import re
import sys

target_id = os.environ["TARGET_ID"]
session_output_path = os.environ["SESSION_OUTPUT_PATH"]
log = open(session_output_path, "r", encoding="utf-8").read()

hitmap_pattern = re.compile(
    r"target-hitmap id=(?P<id>\S+) kind=(?P<kind>\S+) surface=(?P<surface_w>\d+)x(?P<surface_h>\d+) "
    r"hits=(?P<hits>\d+) bbox=(?P<min_x>\d+)\.\.(?P<max_x>\d+),(?P<min_y>\d+)\.\.(?P<max_y>\d+) "
    r"sample=(?P<sample_x>\d+),(?P<sample_y>\d+)"
)
frame_pattern = re.compile(
    r"frame-content-rect panel=(?P<panel_w>\d+)x(?P<panel_h>\d+) frame=\d+x\d+ "
    r"rect=(?P<rect_w>\d+)x(?P<rect_h>\d+)\+(?P<rect_x>\d+),(?P<rect_y>\d+)"
)

hitmap_match = None
for match in hitmap_pattern.finditer(log):
    if match.group("id") == target_id:
        hitmap_match = match

frame_match = None
for match in frame_pattern.finditer(log):
    frame_match = match

if hitmap_match is None or frame_match is None:
    sys.exit(1)

surface_w = int(hitmap_match.group("surface_w"))
surface_h = int(hitmap_match.group("surface_h"))
rect_w = int(frame_match.group("rect_w"))
rect_h = int(frame_match.group("rect_h"))
rect_x = int(frame_match.group("rect_x"))
rect_y = int(frame_match.group("rect_y"))
min_x = int(hitmap_match.group("min_x"))
max_x = int(hitmap_match.group("max_x"))
min_y = int(hitmap_match.group("min_y"))
max_y = int(hitmap_match.group("max_y"))

local_x = (min_x + max_x) / 2.0
local_y = (min_y + max_y) / 2.0
panel_x = round(rect_x + (local_x / surface_w) * rect_w)
panel_y = round(rect_y + (local_y / surface_h) * rect_h)

print(
    json.dumps(
        {
            "targetId": target_id,
            "panelX": panel_x,
            "panelY": panel_y,
            "panelWidth": int(frame_match.group("panel_w")),
            "panelHeight": int(frame_match.group("panel_h")),
            "localX": local_x,
            "localY": local_y,
            "surfaceWidth": surface_w,
            "surfaceHeight": surface_h,
            "rectWidth": rect_w,
            "rectHeight": rect_h,
            "rectX": rect_x,
            "rectY": rect_y,
        }
    )
)
PY
  )"; then
    return 1
  fi
  latest_panel_point_json="$output"
}

timeline_compose_ready() {
  session_output_has_marker '[shadow-guest-compositor] surface-app-tracked app=timeline' || return 1
  capture_target_panel_point draft
}

tap_target() {
  local target_id="$1"
  local panel_x panel_y panel_width panel_height
  panel_x="$(
    PANEL_POINT_JSON="$latest_panel_point_json" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["PANEL_POINT_JSON"])["panelX"])
PY
  )"
  panel_y="$(
    PANEL_POINT_JSON="$latest_panel_point_json" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["PANEL_POINT_JSON"])["panelY"])
PY
  )"
  panel_width="$(
    PANEL_POINT_JSON="$latest_panel_point_json" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["PANEL_POINT_JSON"])["panelWidth"])
PY
  )"
  panel_height="$(
    PANEL_POINT_JSON="$latest_panel_point_json" python3 - <<'PY'
import json
import os
print(json.loads(os.environ["PANEL_POINT_JSON"])["panelHeight"])
PY
  )"
  pixel_touchscreen_tap_panel "$serial" "$panel_x" "$panel_y" "${panel_width}x${panel_height}"
  printf 'tap target=%s panel=%s,%s\n' "$target_id" "$panel_x" "$panel_y" >>"$run_dir/taps.txt"
}

restore_android_best_effort() {
  local pid=""
  (
    PIXEL_SERIAL="$serial" "$SCRIPT_DIR/pixel_restore_android.sh" >/dev/null 2>&1 || true
  ) &
  pid="$!"

  local deadline=$((SECONDS + restore_timeout_secs))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      wait "$pid" >/dev/null 2>&1 || true
      return 0
    fi
    sleep 1
  done

  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
  printf 'pixel-shell-keyboard-smoke: warning: pixel_restore_android timed out after %ss\n' \
    "$restore_timeout_secs" >>"$run_log"
  return 0
}

restore_android_best_effort

(
  cd "$REPO_ROOT"
  PIXEL_SERIAL="$serial" \
  PIXEL_GUEST_RUN_DIR="$guest_run_dir" \
  PIXEL_SHELL_RENDERER=gpu_softbuffer \
  PIXEL_SHELL_START_APP_ID=timeline \
  PIXEL_SHELL_EXTRA_GUEST_CLIENT_ENV='SHADOW_BLITZ_DEBUG_TARGET_HITMAP_IDS=draft,__shadow_keyboard__a' \
    "$SCRIPT_DIR/pixel_shell_drm_hold.sh"
) >"$run_log" 2>&1 &
session_pid="$!"

wait_for_checkpoint "rooted Pixel shell control socket" "$startup_timeout_secs" shell_control_socket_ready
wait_for_checkpoint "timeline compose field through rooted Pixel shell" 60 timeline_compose_ready
if capture_state_json; then
  printf '%s\n' "$latest_state_json" >"$state_after_launch_path"
else
  printf '%s\n' '{"focused":null,"mapped":["timeline"],"shelved":[],"source":"session-output"}' >"$state_after_launch_path"
fi

wait_for_checkpoint "draft target hitmap" 30 capture_target_panel_point draft
tap_target draft

wait_for_checkpoint "draft click dispatch" 30 \
  session_output_has_marker 'runtime-event-dispatched source=ui type=click target=draft'
wait_for_checkpoint "software keyboard target hitmap" 30 \
  capture_target_panel_point __shadow_keyboard__a
tap_target __shadow_keyboard__a

wait_for_checkpoint "software keyboard keydown dispatch" 30 \
  session_output_has_marker 'runtime-event-dispatched source=osk type=keydown target=draft'
wait_for_checkpoint "software keyboard input dispatch" 30 \
  session_output_has_marker 'runtime-event-dispatched source=osk type=input target=draft'

STATE_AFTER_LAUNCH="$(cat "$state_after_launch_path")" \
RUN_LOG="$run_log" \
RUN_DIR="$run_dir" \
SERIAL="$serial" \
SESSION_OUTPUT_PATH="$session_output_path" \
python3 - <<'PY'
import json
import os

launch_state = json.loads(os.environ["STATE_AFTER_LAUNCH"])
if "timeline" not in launch_state.get("mapped", []):
    raise SystemExit(
        f"pixel-shell-keyboard-smoke: launch mapped={launch_state.get('mapped')!r}"
    )

print(
    json.dumps(
        {
            "log": os.environ["RUN_LOG"],
            "launchState": launch_state,
            "result": "pixel-shell-keyboard-ok",
            "runDir": os.environ["RUN_DIR"],
            "serial": os.environ["SERIAL"],
            "sessionOutput": os.environ["SESSION_OUTPUT_PATH"],
        },
        indent=2,
    )
)
PY
