#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
run_dir="$(pixel_prepare_named_run_dir "$(pixel_drm_guest_runs_dir)")"
logcat_path="$run_dir/logcat.txt"
session_output_path="$run_dir/session-output.txt"
frame_artifact="$run_dir/shadow-frame.ppm"
pull_log_path="$run_dir/frame-pull.txt"
frame_path="$(pixel_frame_path)"
runtime_dir="$(pixel_runtime_dir)"
session_dst="$(pixel_session_dst)"
compositor_dst="$(pixel_compositor_dst)"
client_dst="$(pixel_guest_client_dst)"
compositor_exit_on_first_frame="${PIXEL_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME-1}"
compositor_exit_on_client_disconnect="${PIXEL_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT-}"
client_exit_on_configure="${PIXEL_GUEST_CLIENT_EXIT_ON_CONFIGURE-1}"
counter_linger_ms="${PIXEL_GUEST_COUNTER_LINGER_MS-500}"
session_timeout_secs="${PIXEL_GUEST_SESSION_TIMEOUT_SECS-}"
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
pixel_adb "$serial" logcat -c || true
pixel_adb "$serial" logcat -v threadtime >"$logcat_path" 2>&1 &
logcat_pid="$!"

phone_script="$(
  cat <<EOF
$(pixel_takeover_stop_services_script)
rm -rf $runtime_dir && mkdir -p $runtime_dir && chmod 700 $runtime_dir && rm -f $frame_path
${session_timeout_secs:+timeout $session_timeout_secs }env SHADOW_SESSION_MODE=guest-ui SHADOW_RUNTIME_DIR=$runtime_dir SHADOW_GUEST_COMPOSITOR_BIN=$compositor_dst SHADOW_GUEST_CLIENT=$client_dst SHADOW_GUEST_COMPOSITOR_TRANSPORT=direct SHADOW_GUEST_COMPOSITOR_ENABLE_DRM=1 ${compositor_exit_on_first_frame:+SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME=$compositor_exit_on_first_frame }${compositor_exit_on_client_disconnect:+SHADOW_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT=$compositor_exit_on_client_disconnect }${client_exit_on_configure:+SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE=$client_exit_on_configure }${counter_linger_ms:+SHADOW_GUEST_COUNTER_LINGER_MS=$counter_linger_ms }SHADOW_GUEST_FRAME_PATH=$frame_path RUST_LOG=shadow_compositor_guest=info,shadow_counter_guest=info,smithay=warn $session_dst
status=\$?
$(pixel_takeover_start_services_script)
exit \$status
EOF
)"

set +e
session_output="$(pixel_root_shell "$serial" "$phone_script" 2>&1)"
session_status="$?"
set -e

printf '%s\n' "$session_output" | tee "$session_output_path"

set +e
pixel_adb "$serial" pull "$frame_path" "$frame_artifact" >"$pull_log_path" 2>&1
set -e

sleep 3
cleanup
logcat_pid=""
pixel_capture_processes "$serial" "$run_dir/processes-after.txt"

set +e
PIXEL_RUN_DIR="$run_dir" "$SCRIPT_DIR/pixel_verify.sh"
verify_status="$?"
set -e

presented=false
if grep -Fq "[shadow-guest-compositor] presented-frame" "$session_output_path"; then
  presented=true
fi

pixel_write_status_json "$run_dir/status.json" \
  run_dir="$run_dir" \
  session_exit="$session_status" \
  verify_exit="$verify_status" \
  presented_frame="$presented" \
  success="$([[ "$session_status" -eq 0 && "$verify_status" -eq 0 && "$presented" == true ]] && echo true || echo false)"

cat "$run_dir/status.json"

if [[ "$session_status" -ne 0 || "$verify_status" -ne 0 || "$presented" != true ]]; then
  exit 1
fi

printf 'Pixel rooted guest UI takeover succeeded: %s\n' "$run_dir"
