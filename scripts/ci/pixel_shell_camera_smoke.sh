#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./pixel_camera_runtime_common.sh
source "$SCRIPT_DIR/lib/pixel_camera_runtime_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
run_dir="$(pixel_prepare_named_run_dir "$(pixel_shell_runs_dir)")"
run_log="$run_dir/pixel-shell-camera-smoke.log"
broker_log_path="$run_dir/shadow-camera-provider-host-serve.log"
session_output_path=""
logcat_path=""
launcher_args=(--app camera)
render_latency_budget_ms="${PIXEL_SHELL_CAMERA_RENDER_LATENCY_BUDGET_MS:-12000}"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run-only)
        launcher_args=(--run-only "${launcher_args[@]}")
        shift
        ;;
      *)
        echo "pixel_shell_camera_smoke: unsupported argument $1" >&2
        exit 64
        ;;
    esac
  done
}

parse_args "$@"

dump_run_log() {
  if [[ -f "$run_log" ]]; then
    printf '\n== pixel-shell-camera-smoke log ==\n' >&2
    sed -n '1,260p' "$run_log" >&2
  fi
}

cleanup() {
  pixel_stop_shadow_session_best_effort "$serial"
  pixel_restore_android_best_effort "$serial" 60
}

trap cleanup EXIT

pixel_stop_shadow_session_best_effort "$serial"
pixel_restore_android_best_effort "$serial" 60

(
  cd "$REPO_ROOT"
  PIXEL_SERIAL="$serial" \
  PIXEL_SHELL_RENDERER=gpu_softbuffer \
  PIXEL_SHELL_EXTRA_GUEST_CLIENT_ENV='SHADOW_BLITZ_RUNTIME_AUTO_CLICK_TARGET=capture' \
  PIXEL_SHELL_EXTRA_REQUIRED_MARKERS='runtime-event-dispatched source=auto type=click target=capture' \
  PIXEL_GUEST_REQUIRED_MARKER_TIMEOUT_SECS="${PIXEL_GUEST_REQUIRED_MARKER_TIMEOUT_SECS:-60}" \
  PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS="${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS:-10000}" \
  PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-90}" \
    "$SCRIPT_DIR/pixel/pixel_shell_drm.sh" "${launcher_args[@]}"
) >"$run_log" 2>&1 || {
  dump_run_log
  exit 1
}

session_output_path="$(
  RUN_LOG="$run_log" python3 - <<'PY'
import json
import os
import re
import sys

log = open(os.environ["RUN_LOG"], "r", encoding="utf-8").read()
matches = re.findall(r'\{\n(?:.*\n)*?\}', log)
for block in reversed(matches):
    try:
        data = json.loads(block)
    except json.JSONDecodeError:
        continue
    run_dir = data.get("run_dir")
    if run_dir:
        print(os.path.join(run_dir, "session-output.txt"))
        break
else:
    raise SystemExit("pixel-shell-camera-smoke: failed to locate run_dir in shell log")
PY
)"

logcat_path="$(dirname "$session_output_path")/logcat.txt"

pixel_root_shell "$serial" "cat '$(pixel_camera_runtime_daemon_log_path)' 2>/dev/null || true" >"$broker_log_path"

SESSION_OUTPUT_PATH="$session_output_path" \
LOGCAT_PATH="$logcat_path" \
BROKER_LOG_PATH="$broker_log_path" \
SERIAL="$serial" \
RUN_LOG="$run_log" \
RENDER_LATENCY_BUDGET_MS="$render_latency_budget_ms" \
python3 - <<'PY'
import json
import os
import re

session_output = open(os.environ["SESSION_OUTPUT_PATH"], "r", encoding="utf-8").read()
logcat = open(os.environ["LOGCAT_PATH"], "r", encoding="utf-8").read()
broker_log = open(os.environ["BROKER_LOG_PATH"], "r", encoding="utf-8").read()
render_latency_budget_ms = int(os.environ["RENDER_LATENCY_BUDGET_MS"])
session_lines = session_output.splitlines()

def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"pixel-shell-camera-smoke: {message}")

def line_index_after(start: int, needle: str) -> int | None:
    for index, line in enumerate(session_lines[start:], start):
        if needle in line:
            return index
    return None

def runtime_offset_ms_at(line_index: int) -> int | None:
    if line_index is None:
        return None
    match = re.search(r"\+\s*(\d+)ms\]", session_lines[line_index])
    if not match:
        return None
    return int(match.group(1))

click_line_index = line_index_after(0, "runtime-event-dispatched source=auto type=click target=capture")
expect(click_line_index is not None, "missing auto capture click dispatch marker")
expect(
    "[shadow-guest-compositor] surface-app-tracked app=camera" in session_output,
    "camera app was not tracked by the guest compositor",
)
expect(
    broker_log.count("socket-server-accepted") >= 2,
    f"expected camera broker list+capture requests, got log: {broker_log!r}",
)
expect(
    'data-shadow-status-kind="ready"' in session_output,
    "camera app did not publish a ready status marker",
)
expect(
    'data-shadow-last-capture-is-mock="false"' in session_output,
    "camera app did not publish a live capture marker",
)
expect(
    'data-shadow-last-capture-bytes="' in session_output,
    "camera app did not publish capture byte metadata",
)
expect(
    "GCH_CameraDeviceSession: Create: Created a device session for camera 0" in logcat,
    "missing live camera device-session logcat marker",
)
expect(
    "run-app-error:" not in session_output,
    "runtime app exited with an error before smoke completion",
)

capture_complete_line_index = line_index_after(
    click_line_index + 1,
    "[shadow-runtime-camera] camera-capture-complete",
)
expect(capture_complete_line_index is not None, "missing camera capture completion marker")
expect(
    "isMock=false" in session_lines[capture_complete_line_index],
    "camera capture completion marker reported a mock frame",
)

dirty_render_line_index = line_index_after(
    capture_complete_line_index + 1,
    "runtime-dirty-render-applied",
)

click_offset_ms = runtime_offset_ms_at(click_line_index)
dirty_render_offset_ms = runtime_offset_ms_at(dirty_render_line_index)
expect(click_offset_ms is not None, "missing runtime auto click timing marker")
expect(
    dirty_render_offset_ms is not None,
    "missing runtime dirty render marker after live capture completion",
)
expect(
    dirty_render_offset_ms >= click_offset_ms,
    "dirty render marker appeared before the capture click marker",
)
expect(
    dirty_render_offset_ms - click_offset_ms <= render_latency_budget_ms,
    f"capture result did not render within {render_latency_budget_ms}ms (delta={dirty_render_offset_ms - click_offset_ms}ms)",
)

print(
    json.dumps(
        {
            "brokerLog": os.environ["BROKER_LOG_PATH"],
            "log": os.environ["RUN_LOG"],
            "renderLatencyBudgetMs": render_latency_budget_ms,
            "renderLatencyDeltaMs": dirty_render_offset_ms - click_offset_ms,
            "result": "pixel-shell-camera-ok",
            "serial": os.environ["SERIAL"],
            "sessionOutput": os.environ["SESSION_OUTPUT_PATH"],
        },
        indent=2,
    )
)
PY
