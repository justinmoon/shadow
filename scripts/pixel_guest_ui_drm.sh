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
checkpoint_log_path="$run_dir/checkpoints.txt"
frame_artifact="$run_dir/shadow-frame.ppm"
pull_log_path="$run_dir/frame-pull.txt"
frame_path="$(pixel_frame_path)"
runtime_dir="$(pixel_runtime_dir)"
session_dst="$(pixel_session_dst)"
compositor_dst="$(pixel_compositor_dst)"
client_dst="$(pixel_guest_client_dst)"
compositor_name="$(basename "$compositor_dst")"
client_name="$(basename "$client_dst")"
compositor_exit_on_first_frame="${PIXEL_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME-1}"
compositor_exit_on_client_disconnect="${PIXEL_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT-}"
client_exit_on_configure="${PIXEL_GUEST_CLIENT_EXIT_ON_CONFIGURE-1}"
counter_linger_ms="${PIXEL_GUEST_COUNTER_LINGER_MS-500}"
session_timeout_secs="${PIXEL_GUEST_SESSION_TIMEOUT_SECS-}"
guest_client_env="${PIXEL_GUEST_CLIENT_ENV-}"
guest_selftest_drm="${PIXEL_GUEST_COMPOSITOR_SELFTEST_DRM-}"
expect_compositor_process="${PIXEL_GUEST_EXPECT_COMPOSITOR_PROCESS-1}"
expect_client_process="${PIXEL_GUEST_EXPECT_CLIENT_PROCESS-1}"
expect_client_marker="${PIXEL_GUEST_EXPECT_CLIENT_MARKER-1}"
verify_require_client_marker="${PIXEL_VERIFY_REQUIRE_CLIENT_MARKER-1}"
restore_android="${PIXEL_TAKEOVER_RESTORE_ANDROID-1}"
restore_delay_secs="${PIXEL_TAKEOVER_RESTORE_DELAY_SECS-}"
stop_checkpoint_timeout_secs="${PIXEL_GUEST_STOP_CHECKPOINT_TIMEOUT_SECS-15}"
process_checkpoint_timeout_secs="${PIXEL_GUEST_PROCESS_CHECKPOINT_TIMEOUT_SECS-15}"
compositor_marker_timeout_secs="${PIXEL_GUEST_COMPOSITOR_MARKER_TIMEOUT_SECS-20}"
client_marker_timeout_secs="${PIXEL_GUEST_CLIENT_MARKER_TIMEOUT_SECS-20}"
frame_checkpoint_timeout_secs="${PIXEL_GUEST_FRAME_CHECKPOINT_TIMEOUT_SECS-20}"
restore_checkpoint_timeout_secs="${PIXEL_GUEST_RESTORE_CHECKPOINT_TIMEOUT_SECS-20}"
logcat_pid=""
session_pid=""
session_status=""
session_ok=false
verify_status=1
presented=false
startup_ok=false
failure_message=""
services_stopped=false
compositor_started=false
client_started=false
compositor_marker_seen=false
client_marker_seen=false
frame_on_device=false
android_restored=false

cleanup() {
  if [[ -n "${session_pid:-}" && "${startup_ok:-false}" != true && "${android_restored:-false}" != true ]]; then
    if kill -0 "$session_pid" >/dev/null 2>&1; then
      kill "$session_pid" >/dev/null 2>&1 || true
      wait "$session_pid" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "${logcat_pid:-}" ]]; then
    kill "$logcat_pid" >/dev/null 2>&1 || true
    wait "$logcat_pid" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

checkpoint_note() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$checkpoint_log_path" >&2
}

session_output_has_marker() {
  local marker
  marker="$1"
  [[ -f "$session_output_path" ]] && grep -Fq "$marker" "$session_output_path"
}

session_still_running() {
  [[ -n "${session_pid:-}" ]] && kill -0 "$session_pid" >/dev/null 2>&1
}

client_start_observed() {
  local serial client_name
  serial="$1"
  client_name="$2"

  if pixel_root_process_exists "$serial" "$client_name"; then
    return 0
  fi

  if [[ -n "$expect_client_marker" ]] && session_output_has_marker "$(pixel_client_marker)"; then
    return 0
  fi

  return 1
}

compositor_start_observed() {
  local serial compositor_name
  serial="$1"
  compositor_name="$2"

  if pixel_root_process_exists "$serial" "$compositor_name"; then
    return 0
  fi

  if session_output_has_marker "$(pixel_compositor_marker)"; then
    return 0
  fi

  return 1
}

wait_for_checkpoint() {
  local description timeout_secs
  description="$1"
  timeout_secs="$2"
  shift 2

  checkpoint_note "expecting: $description"
  if pixel_wait_for_condition "$timeout_secs" 1 "$@"; then
    checkpoint_note "observed: $description"
    return 0
  fi

  if ! session_still_running; then
    wait "$session_pid" >/dev/null 2>&1 || session_status="$?"
    checkpoint_note "failed: session exited before checkpoint: $description"
  else
    checkpoint_note "failed: timed out waiting for checkpoint: $description"
  fi
  return 1
}

restore_android_now() {
  if [[ "$android_restored" == true ]]; then
    return 0
  fi
  checkpoint_note "restoring Android display services"
  if pixel_root_shell "$serial" "$(pixel_takeover_start_services_script)"; then
    android_restored=true
    checkpoint_note "restored Android display services"
    return 0
  fi
  checkpoint_note "failed: Android display service restore did not complete cleanly"
  return 1
}

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
${session_timeout_secs:+timeout $session_timeout_secs }env SHADOW_SESSION_MODE=guest-ui SHADOW_RUNTIME_DIR=$runtime_dir SHADOW_GUEST_COMPOSITOR_BIN=$compositor_dst SHADOW_GUEST_CLIENT=$client_dst SHADOW_GUEST_COMPOSITOR_TRANSPORT=direct SHADOW_GUEST_COMPOSITOR_ENABLE_DRM=1 ${guest_selftest_drm:+SHADOW_GUEST_COMPOSITOR_SELFTEST_DRM=$guest_selftest_drm }${compositor_exit_on_first_frame:+SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME=$compositor_exit_on_first_frame }${compositor_exit_on_client_disconnect:+SHADOW_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT=$compositor_exit_on_client_disconnect }${client_exit_on_configure:+SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE=$client_exit_on_configure }${counter_linger_ms:+SHADOW_GUEST_COUNTER_LINGER_MS=$counter_linger_ms }${guest_client_env:+SHADOW_GUEST_CLIENT_ENV=$guest_client_env }SHADOW_GUEST_FRAME_PATH=$frame_path RUST_LOG=shadow_compositor_guest=info,shadow_counter_guest=info,smithay=warn $session_dst
status=\$?
${restore_delay_secs:+sleep $restore_delay_secs}
$(if [[ -n "$restore_android" ]]; then pixel_takeover_start_services_script; fi)
exit \$status
EOF
)"

set +e
pixel_root_shell "$serial" "$phone_script" >"$session_output_path" 2>&1 &
session_pid="$!"
set -e

if wait_for_checkpoint "Android display services stopped" "$stop_checkpoint_timeout_secs" pixel_display_services_stopped "$serial"; then
  services_stopped=true
else
  failure_message="timed out waiting for Android display services to stop"
fi

if [[ -z "$failure_message" && -n "$expect_compositor_process" ]]; then
  if wait_for_checkpoint "$compositor_name startup observed" "$process_checkpoint_timeout_secs" compositor_start_observed "$serial" "$compositor_name"; then
    compositor_started=true
  else
    failure_message="timed out waiting for $compositor_name startup"
  fi
fi

if [[ -z "$failure_message" && -n "$expect_client_process" ]]; then
  if wait_for_checkpoint "$client_name startup observed" "$process_checkpoint_timeout_secs" client_start_observed "$serial" "$client_name"; then
    client_started=true
  else
    failure_message="timed out waiting for $client_name startup"
  fi
fi

if [[ -z "$failure_message" ]]; then
  compositor_marker="$(pixel_compositor_marker)"
  if wait_for_checkpoint "compositor marker seen" "$compositor_marker_timeout_secs" session_output_has_marker "$compositor_marker"; then
    compositor_marker_seen=true
    presented=true
  else
    failure_message="timed out waiting for compositor marker: $compositor_marker"
  fi
fi

if [[ -z "$failure_message" && -n "$expect_client_marker" ]]; then
  client_marker="$(pixel_client_marker)"
  if wait_for_checkpoint "client marker seen" "$client_marker_timeout_secs" session_output_has_marker "$client_marker"; then
    client_marker_seen=true
  else
    failure_message="timed out waiting for client marker: $client_marker"
  fi
fi

if [[ -z "$failure_message" ]]; then
  if wait_for_checkpoint "frame artifact written on device" "$frame_checkpoint_timeout_secs" pixel_root_file_nonempty "$serial" "$frame_path"; then
    frame_on_device=true
  else
    failure_message="timed out waiting for non-empty on-device frame artifact: $frame_path"
  fi
fi

if [[ -n "$failure_message" ]]; then
  checkpoint_note "startup checkpoint failure: $failure_message"
  if session_still_running; then
    kill "$session_pid" >/dev/null 2>&1 || true
    wait "$session_pid" >/dev/null 2>&1 || session_status="$?"
  fi
  restore_android_now || true
else
  startup_ok=true
fi

if [[ -z "${session_status:-}" ]]; then
  set +e
  wait "$session_pid"
  session_status="$?"
  set -e
fi

set +e
pixel_adb "$serial" pull "$frame_path" "$frame_artifact" >"$pull_log_path" 2>&1
set -e

sleep 3
cleanup
logcat_pid=""
pixel_capture_processes "$serial" "$run_dir/processes-after.txt"

set +e
PIXEL_VERIFY_REQUIRE_CLIENT_MARKER="$verify_require_client_marker" PIXEL_RUN_DIR="$run_dir" "$SCRIPT_DIR/pixel_verify.sh"
verify_status="$?"
set -e
if [[ "$compositor_marker_seen" != true ]] && session_output_has_marker "$(pixel_compositor_marker)"; then
  compositor_marker_seen=true
  presented=true
fi
if [[ "$client_marker_seen" != true ]] && session_output_has_marker "$(pixel_client_marker)"; then
  client_marker_seen=true
fi
if [[ "$frame_on_device" != true && -s "$frame_artifact" ]]; then
  frame_on_device=true
fi

if [[ -n "$restore_android" && "$android_restored" != true ]]; then
  if pixel_wait_for_condition "$restore_checkpoint_timeout_secs" 1 pixel_android_display_restored "$serial"; then
    android_restored=true
  else
    restore_android_now || true
    if pixel_wait_for_condition "$restore_checkpoint_timeout_secs" 1 pixel_android_display_restored "$serial"; then
      android_restored=true
    else
      failure_message="${failure_message:-timed out waiting for Android display stack restore}"
    fi
  fi
fi

if [[ "$startup_ok" == true ]]; then
  if [[ -n "$restore_android" && "$android_restored" != true ]]; then
    session_ok=false
  elif [[ "$session_status" -eq 0 ]]; then
    session_ok=true
  elif [[ -z "$restore_android" && "$verify_status" -eq 0 && "$presented" == true ]]; then
    session_ok=true
  fi
fi

pixel_write_status_json "$run_dir/status.json" \
  run_dir="$run_dir" \
  session_exit="$session_status" \
  verify_exit="$verify_status" \
  startup_checkpoints_ok="$startup_ok" \
  display_services_stopped="$services_stopped" \
  compositor_process_expected="$([[ -n "$expect_compositor_process" ]] && echo true || echo false)" \
  client_process_expected="$([[ -n "$expect_client_process" ]] && echo true || echo false)" \
  compositor_process_started="$compositor_started" \
  client_process_started="$client_started" \
  client_marker_expected="$([[ -n "$expect_client_marker" ]] && echo true || echo false)" \
  compositor_marker_seen="$compositor_marker_seen" \
  client_marker_seen="$client_marker_seen" \
  frame_on_device="$frame_on_device" \
  presented_frame="$presented" \
  session_ok="$session_ok" \
  android_restored="$android_restored" \
  failure_message="$failure_message" \
  success="$([[ "$session_ok" == true && "$verify_status" -eq 0 && "$presented" == true ]] && echo true || echo false)"

cat "$run_dir/status.json"

if [[ "$startup_ok" != true || "$session_ok" != true || "$verify_status" -ne 0 || "$presented" != true ]]; then
  if [[ -n "$failure_message" ]]; then
    echo "pixel_guest_ui_drm: $failure_message" >&2
    echo "pixel_guest_ui_drm: checkpoints: $checkpoint_log_path" >&2
  fi
  exit 1
fi

printf 'Pixel rooted guest UI takeover succeeded: %s\n' "$run_dir"
