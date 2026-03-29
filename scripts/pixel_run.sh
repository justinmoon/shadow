#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
run_dir="$(pixel_prepare_run_dir)"
logcat_path="$run_dir/logcat.txt"
session_output_path="$run_dir/session-output.txt"
frame_artifact="$run_dir/shadow-frame.ppm"
pull_log_path="$run_dir/frame-pull.txt"
session_status=0
verify_status=0
logcat_pid=""

cleanup() {
  if [[ -n "${logcat_pid:-}" ]]; then
    kill "$logcat_pid" >/dev/null 2>&1 || true
    wait "$logcat_pid" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

if ! pixel_require_runtime_artifacts; then
  "$SCRIPT_DIR/pixel_build.sh"
fi
"$SCRIPT_DIR/pixel_push.sh"

pixel_capture_props "$serial" "$run_dir/device-props.txt"
pixel_capture_processes "$serial" "$run_dir/processes-before.txt"
pixel_write_status_json "$run_dir/status.json" run_dir="$run_dir" success=false phase=starting

pixel_adb "$serial" logcat -c || true
pixel_adb "$serial" logcat -v threadtime >"$logcat_path" 2>&1 &
logcat_pid="$!"

runtime_dir="$(pixel_runtime_dir)"
frame_path="$(pixel_frame_path)"
session_dst="$(pixel_session_dst)"
compositor_dst="$(pixel_compositor_dst)"
counter_dst="$(pixel_counter_dst)"

pixel_adb "$serial" shell \
  "rm -rf $runtime_dir && mkdir -p $runtime_dir && chmod 700 $runtime_dir && rm -f $frame_path"

set +e
session_output="$(
  pixel_adb "$serial" shell \
    "env SHADOW_SESSION_MODE=guest-ui SHADOW_RUNTIME_DIR=$runtime_dir SHADOW_GUEST_COMPOSITOR_BIN=$compositor_dst SHADOW_GUEST_CLIENT=$counter_dst SHADOW_GUEST_COMPOSITOR_TRANSPORT=direct SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME=1 SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE=1 SHADOW_GUEST_COUNTER_LINGER_MS=500 SHADOW_GUEST_FRAME_PATH=$frame_path RUST_LOG=shadow_compositor_guest=info,shadow_counter_guest=info,smithay=warn $session_dst" \
    2>&1
)"
session_status="$?"
set -e

printf '%s\n' "$session_output" | tee "$session_output_path"

sleep 1
cleanup
logcat_pid=""

set +e
pixel_adb "$serial" pull "$frame_path" "$frame_artifact" >"$pull_log_path" 2>&1
set -e

pixel_capture_processes "$serial" "$run_dir/processes-after.txt"

set +e
PIXEL_RUN_DIR="$run_dir" "$SCRIPT_DIR/pixel_verify.sh"
verify_status="$?"
set -e

if [[ "$session_status" -ne 0 || "$verify_status" -ne 0 ]]; then
  exit 1
fi

printf 'Pixel run succeeded: %s\n' "$run_dir"
