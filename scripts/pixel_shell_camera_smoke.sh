#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
# shellcheck source=./pixel_camera_runtime_common.sh
source "$SCRIPT_DIR/pixel_camera_runtime_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
run_dir="$(pixel_prepare_named_run_dir "$(pixel_shell_runs_dir)")"
run_log="$run_dir/pixel-shell-camera-smoke.log"
broker_log_path="$run_dir/shadow-camera-provider-host-serve.log"
session_output_path=""
logcat_path=""

dump_run_log() {
  if [[ -f "$run_log" ]]; then
    printf '\n== pixel-shell-camera-smoke log ==\n' >&2
    sed -n '1,260p' "$run_log" >&2
  fi
}

cleanup() {
  PIXEL_SERIAL="$serial" "$SCRIPT_DIR/pixel_restore_android.sh" >/dev/null 2>&1 || true
}

trap cleanup EXIT

PIXEL_SERIAL="$serial" "$SCRIPT_DIR/pixel_restore_android.sh" >/dev/null 2>&1 || true

(
  cd "$REPO_ROOT"
  PIXEL_SERIAL="$serial" \
  PIXEL_SHELL_START_APP_ID=camera \
  PIXEL_SHELL_EXTRA_GUEST_CLIENT_ENV='SHADOW_BLITZ_RUNTIME_AUTO_CLICK_TARGET=capture' \
  PIXEL_SHELL_EXTRA_REQUIRED_MARKERS='runtime-event-dispatched source=auto type=click target=capture' \
  PIXEL_GUEST_REQUIRED_MARKER_TIMEOUT_SECS="${PIXEL_GUEST_REQUIRED_MARKER_TIMEOUT_SECS:-60}" \
  PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS="${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS:-10000}" \
  PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-90}" \
    "$SCRIPT_DIR/pixel_shell_drm.sh"
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
python3 - <<'PY'
import json
import os

session_output = open(os.environ["SESSION_OUTPUT_PATH"], "r", encoding="utf-8").read()
logcat = open(os.environ["LOGCAT_PATH"], "r", encoding="utf-8").read()
broker_log = open(os.environ["BROKER_LOG_PATH"], "r", encoding="utf-8").read()

def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"pixel-shell-camera-smoke: {message}")

expect(
    "runtime-event-dispatched source=auto type=click target=capture" in session_output,
    "missing auto capture click dispatch marker",
)
expect(
    "[shadow-guest-compositor] surface-app-tracked app=camera" in session_output,
    "camera app was not tracked by the guest compositor",
)
expect(
    broker_log.count("socket-server-accepted") >= 2,
    f"expected camera broker list+capture requests, got log: {broker_log!r}",
)
expect(
    "GCH_CameraDeviceSession: Create: Created a device session for camera 0" in logcat,
    "missing live camera device-session logcat marker",
)

print(
    json.dumps(
        {
            "brokerLog": os.environ["BROKER_LOG_PATH"],
            "log": os.environ["RUN_LOG"],
            "result": "pixel-shell-camera-ok",
            "serial": os.environ["SERIAL"],
            "sessionOutput": os.environ["SESSION_OUTPUT_PATH"],
        },
        indent=2,
    )
)
PY
