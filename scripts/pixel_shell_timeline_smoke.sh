#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
run_dir="$(pixel_prepare_named_run_dir "$(pixel_shell_runs_dir)")"
run_log="$run_dir/pixel-shell-timeline-smoke.log"
state_after_open_path="$run_dir/state-after-open.json"
state_after_home_path="$run_dir/state-after-home.json"
state_after_reopen_path="$run_dir/state-after-reopen.json"
control_socket_path="$(pixel_shell_control_socket_path)"
session_pid=""
latest_state_json=""

dump_run_log() {
  if [[ -f "$run_log" ]]; then
    printf '\n== pixel-shell-timeline-smoke log ==\n' >&2
    sed -n '1,260p' "$run_log" >&2
  fi
}

cleanup() {
  PIXEL_SERIAL="$serial" "$SCRIPT_DIR/pixel_restore_android.sh" >/dev/null 2>&1 || true
  if [[ -n "${session_pid:-}" ]]; then
    wait "$session_pid" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

session_still_running() {
  [[ -n "${session_pid:-}" ]] && kill -0 "$session_pid" >/dev/null 2>&1
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

state_matches() {
  local expected_focused="$1"
  local mapped_contains="$2"
  local mapped_absent="$3"
  local shelved_contains="$4"
  local shelved_absent="$5"

  capture_state_json || return 1

  STATE_JSON="$latest_state_json" \
  EXPECTED_FOCUSED="$expected_focused" \
  MAPPED_CONTAINS="$mapped_contains" \
  MAPPED_ABSENT="$mapped_absent" \
  SHELVED_CONTAINS="$shelved_contains" \
  SHELVED_ABSENT="$shelved_absent" \
  python3 - <<'PY' >/dev/null
import json
import os
import sys

state = json.loads(os.environ["STATE_JSON"])
focused = state.get("focused")
expected_focused = os.environ["EXPECTED_FOCUSED"]
mapped = state.get("mapped", [])
shelved = state.get("shelved", [])

if expected_focused:
    if focused != expected_focused:
        sys.exit(1)
else:
    if focused not in ("", None):
        sys.exit(1)

mapped_contains = os.environ["MAPPED_CONTAINS"]
if mapped_contains and mapped_contains not in mapped:
    sys.exit(1)

mapped_absent = os.environ["MAPPED_ABSENT"]
if mapped_absent and mapped_absent in mapped:
    sys.exit(1)

shelved_contains = os.environ["SHELVED_CONTAINS"]
if shelved_contains and shelved_contains not in shelved:
    sys.exit(1)

shelved_absent = os.environ["SHELVED_ABSENT"]
if shelved_absent and shelved_absent in shelved:
    sys.exit(1)
PY
}

wait_for_state() {
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
      echo "pixel-shell-timeline-smoke: session exited before ${description}" >&2
      exit 1
    fi
    sleep 1
  done

  if "$@"; then
    return 0
  fi

  dump_run_log
  echo "pixel-shell-timeline-smoke: timed out waiting for ${description}" >&2
  exit 1
}

shell_control_socket_ready() {
  pixel_root_socket_exists "$serial" "$control_socket_path"
}

PIXEL_SERIAL="$serial" "$SCRIPT_DIR/pixel_restore_android.sh" >/dev/null 2>&1 || true

(
  cd "$REPO_ROOT"
  PIXEL_SERIAL="$serial" \
  PIXEL_SHELL_RENDERER=gpu_softbuffer \
  PIXEL_SHELL_START_APP_ID=timeline \
    "$SCRIPT_DIR/pixel_shell_drm_hold.sh"
) >"$run_log" 2>&1 &
session_pid="$!"

wait_for_state "rooted Pixel shell control socket" 300 shell_control_socket_ready
wait_for_state "timeline launch through rooted Pixel shell" 60 \
  state_matches timeline timeline '' '' timeline
printf '%s\n' "$latest_state_json" >"$state_after_open_path"

"$SCRIPT_DIR/shadowctl" --target "$serial" home >/dev/null
wait_for_state "timeline shelved after home" 30 \
  state_matches '' '' timeline timeline ''
printf '%s\n' "$latest_state_json" >"$state_after_home_path"

"$SCRIPT_DIR/shadowctl" --target "$serial" open timeline >/dev/null
wait_for_state "timeline reopen through rooted Pixel shell" 30 \
  state_matches timeline timeline '' '' timeline
printf '%s\n' "$latest_state_json" >"$state_after_reopen_path"

STATE_AFTER_OPEN="$(cat "$state_after_open_path")" \
STATE_AFTER_HOME="$(cat "$state_after_home_path")" \
STATE_AFTER_REOPEN="$(cat "$state_after_reopen_path")" \
RUN_LOG="$run_log" \
SERIAL="$serial" \
python3 - <<'PY'
import json
import os

open_state = json.loads(os.environ["STATE_AFTER_OPEN"])
home_state = json.loads(os.environ["STATE_AFTER_HOME"])
reopen_state = json.loads(os.environ["STATE_AFTER_REOPEN"])


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"pixel-shell-timeline-smoke: {message}")


expect(open_state.get("focused") == "timeline", f"open focused={open_state.get('focused')!r}")
expect("timeline" in open_state.get("launched", []), f"open launched={open_state.get('launched')!r}")
expect("timeline" in open_state.get("mapped", []), f"open mapped={open_state.get('mapped')!r}")
expect("timeline" not in open_state.get("shelved", []), f"open shelved={open_state.get('shelved')!r}")

expect(home_state.get("focused") in ("", None), f"home focused={home_state.get('focused')!r}")
expect("timeline" in home_state.get("launched", []), f"home launched={home_state.get('launched')!r}")
expect("timeline" not in home_state.get("mapped", []), f"home mapped={home_state.get('mapped')!r}")
expect("timeline" in home_state.get("shelved", []), f"home shelved={home_state.get('shelved')!r}")

expect(reopen_state.get("focused") == "timeline", f"reopen focused={reopen_state.get('focused')!r}")
expect("timeline" in reopen_state.get("launched", []), f"reopen launched={reopen_state.get('launched')!r}")
expect("timeline" in reopen_state.get("mapped", []), f"reopen mapped={reopen_state.get('mapped')!r}")
expect("timeline" not in reopen_state.get("shelved", []), f"reopen shelved={reopen_state.get('shelved')!r}")

print(
    json.dumps(
        {
            "result": "pixel-shell-timeline-ok",
            "serial": os.environ["SERIAL"],
            "log": os.environ["RUN_LOG"],
        },
        indent=2,
    )
)
PY
