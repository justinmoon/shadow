#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
run_dir="${PIXEL_GUEST_RUN_DIR-}"
if [[ -z "$run_dir" ]]; then
  run_dir="$(pixel_prepare_named_run_dir "$(pixel_drm_guest_runs_dir)")"
else
  mkdir -p "$run_dir"
fi
logcat_path="$run_dir/logcat.txt"
session_output_path="$run_dir/session-output.txt"
checkpoint_log_path="$run_dir/checkpoints.txt"
frame_artifact="$run_dir/shadow-frame.ppm"
pull_log_path="$run_dir/frame-pull.txt"
host_pid_path="${PIXEL_GUEST_UI_HOST_PID_PATH-}"
guest_run_config_path="${PIXEL_GUEST_RUN_CONFIG-}"
frame_path="$(pixel_frame_path)"
runtime_dir="$(pixel_runtime_dir)"
session_dst="$(pixel_session_dst)"
compositor_dst="$(pixel_compositor_dst)"
client_dst="$(pixel_guest_client_dst)"
compositor_name="$(basename "$compositor_dst")"
client_name="$(basename "$client_dst")"
startup_config_host_path=""
guest_client_launch_dst="$client_dst"
guest_session_launch_env_lines=""
compositor_exit_on_first_frame="${PIXEL_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME-1}"
compositor_exit_on_client_disconnect="${PIXEL_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT-}"
client_exit_on_configure="${PIXEL_GUEST_CLIENT_EXIT_ON_CONFIGURE-1}"
session_timeout_secs="${PIXEL_GUEST_SESSION_TIMEOUT_SECS-}"
guest_config_client_env="${PIXEL_GUEST_CONFIG_CLIENT_ENV-}"
guest_config_session_env="${PIXEL_GUEST_CONFIG_SESSION_ENV-}"
guest_client_env_overlay="${PIXEL_GUEST_CLIENT_ENV_OVERLAY-}"
guest_session_env_overlay="${PIXEL_GUEST_SESSION_ENV_OVERLAY-}"
legacy_guest_client_env_overlay="$guest_client_env_overlay"
legacy_guest_session_env_overlay="$guest_session_env_overlay"
frame_capture_mode="${PIXEL_GUEST_FRAME_CAPTURE_MODE-}"
guest_precreate_dirs="${PIXEL_GUEST_PRECREATE_DIRS-}"
guest_pre_session_device_script="${PIXEL_GUEST_PRE_SESSION_DEVICE_SCRIPT-}"
guest_post_session_device_script="${PIXEL_GUEST_POST_SESSION_DEVICE_SCRIPT-}"
expect_compositor_process="${PIXEL_GUEST_EXPECT_COMPOSITOR_PROCESS-1}"
expect_client_process="${PIXEL_GUEST_EXPECT_CLIENT_PROCESS-1}"
expect_client_marker="${PIXEL_GUEST_EXPECT_CLIENT_MARKER-1}"
verify_require_client_marker="${PIXEL_VERIFY_REQUIRE_CLIENT_MARKER-1}"
verify_forbidden_markers="${PIXEL_VERIFY_FORBIDDEN_MARKERS-}"
skip_push="${PIXEL_GUEST_SKIP_PUSH-}"
restore_android="${PIXEL_TAKEOVER_RESTORE_ANDROID-1}"
restore_in_session="${PIXEL_TAKEOVER_RESTORE_IN_SESSION:-1}"
reboot_on_restore_failure="${PIXEL_TAKEOVER_REBOOT_ON_RESTORE_FAILURE:-0}"
stop_allocator="${PIXEL_TAKEOVER_STOP_ALLOCATOR-1}"
# These launcher-level defaults have no in-repo callers today.
stop_checkpoint_timeout_secs=15
process_checkpoint_timeout_secs=15
compositor_marker_timeout_secs="${PIXEL_GUEST_COMPOSITOR_MARKER_TIMEOUT_SECS-20}"
client_marker_timeout_secs=20
required_markers_raw="${PIXEL_GUEST_REQUIRED_MARKERS-}"
required_marker_timeout_secs="${PIXEL_GUEST_REQUIRED_MARKER_TIMEOUT_SECS-$client_marker_timeout_secs}"
frame_checkpoint_timeout_secs="${PIXEL_GUEST_FRAME_CHECKPOINT_TIMEOUT_SECS-20}"
restore_checkpoint_timeout_secs="${PIXEL_TAKEOVER_RESTORE_CHECKPOINT_TIMEOUT_SECS-60}"
session_exit_timeout_secs="${PIXEL_GUEST_SESSION_EXIT_TIMEOUT_SECS-15}"
restore_reboot_timeout_secs="${PIXEL_TAKEOVER_RESTORE_REBOOT_TIMEOUT_SECS-120}"
runtime_summary_renderer="${PIXEL_RUNTIME_SUMMARY_RENDERER-}"
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
required_markers_seen=false
forbidden_markers_clear=true
frame_on_device=false
android_restored=false
android_restore_rebooted=false
checkpoint_failure_kind=""
checkpoint_failure_description=""
checkpoint_failure_message=""
post_success_adb_lost=false
post_success_transport_warning=""

if [[ -n "$guest_run_config_path" ]]; then
  guest_run_materialized_path="$run_dir/guest-run-config.env"
  pixel_materialize_guest_run_config "$guest_run_config_path" "$guest_run_materialized_path"
  # shellcheck source=/dev/null
  source "$guest_run_materialized_path"

  startup_config_host_path="$pixel_guest_run_config_startup_config_path"
  runtime_dir="$pixel_guest_run_config_runtime_dir"
  guest_client_launch_dst="$pixel_guest_run_config_client_launch_path"
  guest_session_launch_env_lines="$pixel_guest_run_config_session_launch_env"
  guest_client_env_overlay="$pixel_guest_run_config_client_env_overlay"
  if [[ -n "$legacy_guest_client_env_overlay" ]]; then
    if [[ -n "$guest_client_env_overlay" ]]; then
      guest_client_env_overlay="${guest_client_env_overlay}"$'\n'"$legacy_guest_client_env_overlay"
    else
      guest_client_env_overlay="$legacy_guest_client_env_overlay"
    fi
  fi
  legacy_overlay_session_launch_env="$(
    pixel_guest_session_overlay_passthrough_env_lines "$legacy_guest_session_env_overlay"
  )"
  if [[ -n "$legacy_overlay_session_launch_env" ]]; then
    if [[ -n "$guest_session_launch_env_lines" ]]; then
      guest_session_launch_env_lines="${guest_session_launch_env_lines}"$'\n'"$legacy_overlay_session_launch_env"
    else
      guest_session_launch_env_lines="$legacy_overlay_session_launch_env"
    fi
  fi
  if [[ -n "$pixel_guest_run_config_frame_artifact_path" ]]; then
    frame_path="$pixel_guest_run_config_frame_artifact_path"
  fi
  frame_capture_mode="$pixel_guest_run_config_frame_capture_mode"
  session_timeout_secs="$pixel_guest_run_config_session_timeout_secs"
  guest_precreate_dirs="$pixel_guest_run_config_precreate_dirs"
  guest_pre_session_device_script="$pixel_guest_run_config_pre_session_device_script"
  guest_post_session_device_script="$pixel_guest_run_config_post_session_device_script"
  expect_compositor_process="$pixel_guest_run_config_expect_compositor_process"
  expect_client_process="$pixel_guest_run_config_expect_client_process"
  expect_client_marker="$pixel_guest_run_config_expect_client_marker"
  verify_require_client_marker="$pixel_guest_run_config_verify_require_client_marker"
  verify_forbidden_markers="$pixel_guest_run_config_forbidden_markers"
  required_markers_raw="$pixel_guest_run_config_required_markers"
  compositor_marker_timeout_secs="${pixel_guest_run_config_compositor_marker_timeout_secs:-$compositor_marker_timeout_secs}"
  required_marker_timeout_secs="${pixel_guest_run_config_required_marker_timeout_secs:-$required_marker_timeout_secs}"
  frame_checkpoint_timeout_secs="${pixel_guest_run_config_frame_checkpoint_timeout_secs:-$frame_checkpoint_timeout_secs}"
  restore_checkpoint_timeout_secs="${pixel_guest_run_config_restore_checkpoint_timeout_secs:-$restore_checkpoint_timeout_secs}"
  session_exit_timeout_secs="${pixel_guest_run_config_session_exit_timeout_secs:-$session_exit_timeout_secs}"
  restore_reboot_timeout_secs="${pixel_guest_run_config_restore_reboot_timeout_secs:-$restore_reboot_timeout_secs}"
  restore_android="$pixel_guest_run_config_restore_android"
  restore_in_session="$pixel_guest_run_config_restore_in_session"
  reboot_on_restore_failure="$pixel_guest_run_config_reboot_on_restore_failure"
  stop_allocator="$pixel_guest_run_config_stop_allocator"
  client_name="$(basename "$guest_client_launch_dst")"
  if [[ -n "$pixel_guest_run_config_compositor_marker" ]]; then
    export PIXEL_COMPOSITOR_MARKER="$pixel_guest_run_config_compositor_marker"
  else
    unset PIXEL_COMPOSITOR_MARKER || true
  fi
  if [[ -n "$pixel_guest_run_config_client_marker" ]]; then
    export PIXEL_CLIENT_MARKER="$pixel_guest_run_config_client_marker"
  else
    unset PIXEL_CLIENT_MARKER || true
  fi
fi

if [[ -z "$frame_capture_mode" ]]; then
  if [[ -n "$compositor_exit_on_first_frame" ]]; then
    frame_capture_mode="publish"
  else
    frame_capture_mode="request"
  fi
fi

case "$frame_capture_mode" in
  publish | request | off) ;;
  *)
    echo "pixel_guest_ui_drm: unsupported PIXEL_GUEST_FRAME_CAPTURE_MODE=$frame_capture_mode" >&2
    exit 2
    ;;
esac

if [[ -n "$host_pid_path" ]]; then
  mkdir -p "$(dirname "$host_pid_path")"
  printf '%s\n' "$$" >"$host_pid_path"
fi

display_services_stopped_condition() {
  if [[ "$stop_allocator" == "0" ]]; then
    pixel_display_services_stopped_keep_allocator "$serial"
    return
  fi
  pixel_display_services_stopped "$serial"
}

cleanup() {
  if [[ -n "${session_pid:-}" && "${startup_ok:-false}" != true && "${android_restored:-false}" != true ]]; then
    if kill -0 "$session_pid" >/dev/null 2>&1; then
      kill "$session_pid" >/dev/null 2>&1 || true
      wait "$session_pid" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "$guest_post_session_device_script" ]]; then
    pixel_root_shell "$serial" "$guest_post_session_device_script" >/dev/null 2>&1 || true
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

session_not_running() {
  ! session_still_running
}

session_output_exit_status() {
  local status_line status_value

  [[ -f "$session_output_path" ]] || return 1
  status_line="$(
    grep -F "[shadow-session]" "$session_output_path" \
      | grep -F " exited with exit status: " \
      | tail -n 1 || true
  )"
  [[ -n "$status_line" ]] || return 1
  status_value="${status_line##* exit status: }"
  [[ "$status_value" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$status_value"
}

session_completed() {
  local observed_exit_code

  if ! session_still_running; then
    return 0
  fi

  observed_exit_code="$(session_output_exit_status)" || return 1
  if [[ -z "${session_status:-}" ]]; then
    session_status="$observed_exit_code"
  fi
  return 0
}

required_markers_all_seen() {
  local marker

  [[ -n "$required_markers_raw" ]] || return 0
  while IFS= read -r marker; do
    [[ -n "$marker" ]] || continue
    if ! session_output_has_marker "$marker"; then
      return 1
    fi
  done <<< "$required_markers_raw"
  return 0
}

forbidden_markers_absent() {
  local marker

  [[ -n "$verify_forbidden_markers" ]] || return 0
  while IFS= read -r marker; do
    [[ -n "$marker" ]] || continue
    if session_output_has_marker "$marker"; then
      return 1
    fi
  done <<< "$verify_forbidden_markers"
  return 0
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

  checkpoint_failure_kind=""
  checkpoint_failure_description=""
  checkpoint_failure_message=""

  checkpoint_note "expecting: $description"
  if pixel_wait_for_condition "$timeout_secs" 1 "$@"; then
    checkpoint_note "observed: $description"
    return 0
  fi

  if session_completed; then
    if session_still_running; then
      kill "$session_pid" >/dev/null 2>&1 || true
      wait "$session_pid" >/dev/null 2>&1 || true
    else
      wait "$session_pid" >/dev/null 2>&1 || true
    fi
    checkpoint_failure_kind="session-exited-before-checkpoint"
    checkpoint_failure_description="$description"
    checkpoint_failure_message="session exited before checkpoint: $description"
    checkpoint_note "failed: $checkpoint_failure_message"
  else
    checkpoint_failure_kind="checkpoint-timeout"
    checkpoint_failure_description="$description"
    checkpoint_failure_message="timed out waiting for checkpoint: $description"
    checkpoint_note "failed: $checkpoint_failure_message"
  fi
  return 1
}

restore_android_now() {
  if [[ "$android_restored" == true ]]; then
    return 0
  fi
  checkpoint_note "restoring Android display services"
  if ! pixel_root_shell "$serial" "$(pixel_takeover_start_services_script)"; then
    checkpoint_note "failed: Android display service restore command did not complete cleanly"
    return 1
  fi
  if pixel_wait_for_condition "$restore_checkpoint_timeout_secs" 1 pixel_android_display_restored "$serial"; then
    android_restored=true
    checkpoint_note "restored Android display services"
    return 0
  fi
  checkpoint_note "failed: Android display service restore did not complete cleanly"
  return 1
}

restore_android_via_reboot() {
  if [[ "$android_restored" == true ]]; then
    return 0
  fi
  checkpoint_note "restore fallback: rebooting device"
  if ! pixel_adb "$serial" reboot >/dev/null 2>&1; then
    checkpoint_note "failed: reboot command for Android restore fallback"
    return 1
  fi
  if ! pixel_wait_for_adb "$serial" "$restore_reboot_timeout_secs" >/dev/null 2>&1; then
    checkpoint_note "failed: device did not reconnect after Android restore fallback reboot"
    return 1
  fi
  if ! pixel_wait_for_boot_completed "$serial" "$restore_reboot_timeout_secs" >/dev/null 2>&1; then
    checkpoint_note "failed: device did not finish boot after Android restore fallback reboot"
    return 1
  fi
  if pixel_wait_for_condition "$restore_reboot_timeout_secs" 1 pixel_android_display_restored "$serial"; then
    android_restored=true
    android_restore_rebooted=true
    checkpoint_note "restored Android display services via reboot fallback"
    return 0
  fi
  checkpoint_note "failed: Android display stack still not restored after reboot fallback"
  return 1
}

note_post_success_transport_warning() {
  local message
  message="$1"
  if [[ "$post_success_transport_warning" != "$message" ]]; then
    post_success_transport_warning="$message"
  fi
  checkpoint_note "warning: $message"
}

ensure_post_success_adb() {
  local timeout_secs
  timeout_secs="${1:-5}"

  if pixel_connected_serials | grep -Fxq "$serial"; then
    return 0
  fi

  note_post_success_transport_warning "adb device unavailable during post-success cleanup; waiting up to ${timeout_secs}s for reconnect"
  if pixel_wait_for_adb "$serial" "$timeout_secs" >/dev/null 2>&1; then
    checkpoint_note "observed: adb device reconnected during post-success cleanup"
    return 0
  fi

  post_success_adb_lost=true
  note_post_success_transport_warning "adb device remained unavailable during post-success cleanup"
  return 1
}

request_frame_artifact() {
  PIXEL_RUNTIME_DIR="$runtime_dir" \
  PIXEL_FRAME_PATH="$frame_path" \
    "$SCRIPT_DIR/shadowctl" frame -t "$serial" --remote-path "$frame_path" "$frame_artifact" >"$pull_log_path" 2>&1
}

if [[ -z "$skip_push" ]]; then
  if ! pixel_require_runtime_artifacts; then
    "$SCRIPT_DIR/pixel/pixel_build.sh"
  fi
  "$SCRIPT_DIR/pixel/pixel_push.sh"
fi

startup_config_dst="$(pixel_guest_startup_config_dst "$(basename "$run_dir")-$$")"
if [[ -z "$guest_run_config_path" ]]; then
  startup_config_host_path="$(pixel_guest_startup_config_host_path "$run_dir")"
  guest_config_session_env_for_config="$guest_config_session_env"
  while IFS= read -r env_line; do
    [[ -n "$env_line" ]] || continue
    if [[ -n "$guest_config_session_env_for_config" ]]; then
      guest_config_session_env_for_config="${guest_config_session_env_for_config}"$'\n'"$env_line"
    else
      guest_config_session_env_for_config="$env_line"
    fi
  done < <(pixel_guest_session_overlay_config_env_lines "$guest_session_env_overlay")
  guest_session_env_passthrough="$(pixel_guest_session_overlay_passthrough_env_lines "$guest_session_env_overlay")"
  guest_client_override="$(pixel_env_assignment_last_value SHADOW_GUEST_CLIENT "$guest_config_session_env_for_config" || true)"
  if [[ -n "$guest_client_override" ]]; then
    guest_client_launch_dst="$guest_client_override"
    client_name="$(basename "$guest_client_launch_dst")"
  fi

  pixel_write_guest_ui_startup_config \
    "$startup_config_host_path" \
    "$runtime_dir" \
    "$client_dst" \
    "$compositor_exit_on_first_frame" \
    "$compositor_exit_on_client_disconnect" \
    "$client_exit_on_configure" \
    "$guest_config_client_env" \
    "$guest_config_session_env_for_config" \
    "$frame_path" \
    "$frame_capture_mode"
  guest_session_launch_env_lines="$(pixel_guest_session_launch_env_lines "$guest_config_session_env")"
  while IFS= read -r env_line; do
    [[ -n "$env_line" ]] || continue
    if [[ -n "$guest_session_launch_env_lines" ]]; then
      guest_session_launch_env_lines="${guest_session_launch_env_lines}"$'\n'"$env_line"
    else
      guest_session_launch_env_lines="$env_line"
    fi
  done < <(printf '%s\n' "$guest_session_env_passthrough")
fi
pixel_validate_env_assignment_lines "guest client overlay env" "$guest_client_env_overlay"
pixel_validate_env_assignment_lines "guest session launch env" "$guest_session_launch_env_lines"
pixel_push_device_file_verified "$serial" "$startup_config_host_path" "$startup_config_dst" 0644

guest_session_launch_env_args=(
  "XKB_CONFIG_ROOT=$(pixel_runtime_xkb_config_root)"
  "SHADOW_SESSION_MODE=guest-ui"
  "SHADOW_RUNTIME_DIR=$runtime_dir"
  "SHADOW_GUEST_SESSION_CONFIG=$startup_config_dst"
  "SHADOW_GUEST_COMPOSITOR_BIN=$compositor_dst"
  "SHADOW_GUEST_COMPOSITOR_ENABLE_DRM=1"
  "SHADOW_GUEST_CLIENT=$guest_client_launch_dst"
)
if [[ -n "$guest_client_env_overlay" ]]; then
  guest_session_launch_env_args+=("SHADOW_GUEST_CLIENT_ENV=$guest_client_env_overlay")
fi
while IFS= read -r env_line; do
  [[ -n "$env_line" ]] || continue
  guest_session_launch_env_args+=("$env_line")
done < <(printf '%s\n' "$guest_session_launch_env_lines")
guest_session_launch_env="$(pixel_shell_words_quoted "${guest_session_launch_env_args[@]}")"
guest_precreate_dir_words="$(pixel_lines_quoted "$guest_precreate_dirs")"
session_command_word="$(pixel_shell_words_quoted "$session_dst")"

pixel_capture_props "$serial" "$run_dir/device-props.txt"
pixel_capture_processes "$serial" "$run_dir/processes-before.txt"
pixel_adb "$serial" logcat -c || true
pixel_adb "$serial" logcat -v threadtime >"$logcat_path" 2>&1 &
logcat_pid="$!"

phone_script="$(
  cat <<EOF
$(pixel_takeover_stop_services_script "$stop_allocator")
rm -rf $runtime_dir && mkdir -p $runtime_dir && chmod 700 $runtime_dir && rm -f $frame_path
${guest_precreate_dir_words:+for prep_dir in ${guest_precreate_dir_words}; do mkdir -p "\$prep_dir"; done}
${guest_pre_session_device_script:+$guest_pre_session_device_script}
${session_timeout_secs:+timeout $session_timeout_secs }env ${guest_session_launch_env}${session_command_word}
status=\$?
rm -f '$startup_config_dst'
$(if [[ -n "$restore_android" && "$restore_in_session" != "0" ]]; then pixel_takeover_start_services_script; fi)
exit \$status
EOF
)"

set +e
pixel_root_shell "$serial" "$phone_script" >"$session_output_path" 2>&1 &
session_pid="$!"
set -e

stop_description="Android display services stopped"
if [[ "$stop_allocator" == "0" ]]; then
  stop_description="Android display services stopped with allocator preserved"
fi

if wait_for_checkpoint "$stop_description" "$stop_checkpoint_timeout_secs" display_services_stopped_condition; then
  services_stopped=true
else
  failure_message="timed out waiting for $stop_description"
fi

if [[ -z "$failure_message" && -n "$expect_compositor_process" ]]; then
  if wait_for_checkpoint "$compositor_name startup observed" "$process_checkpoint_timeout_secs" compositor_start_observed "$serial" "$compositor_name"; then
    compositor_started=true
  else
    failure_message="$checkpoint_failure_message"
  fi
fi

if [[ -z "$failure_message" && -n "$expect_client_process" ]]; then
  if wait_for_checkpoint "$client_name startup observed" "$process_checkpoint_timeout_secs" client_start_observed "$serial" "$client_name"; then
    client_started=true
  else
    failure_message="$checkpoint_failure_message"
  fi
fi

if [[ -z "$failure_message" ]]; then
  compositor_marker="$(pixel_compositor_marker)"
  if wait_for_checkpoint "compositor marker seen" "$compositor_marker_timeout_secs" session_output_has_marker "$compositor_marker"; then
    compositor_marker_seen=true
    presented=true
  else
    failure_message="$checkpoint_failure_message"
  fi
fi

if [[ -z "$failure_message" && -n "$expect_client_marker" ]]; then
  client_marker="$(pixel_client_marker)"
  if wait_for_checkpoint "client marker seen" "$client_marker_timeout_secs" session_output_has_marker "$client_marker"; then
    client_marker_seen=true
  else
    failure_message="$checkpoint_failure_message"
  fi
fi

if [[ -z "$failure_message" && -n "$required_markers_raw" ]]; then
  while IFS= read -r required_marker; do
    [[ -n "$required_marker" ]] || continue
    if wait_for_checkpoint "required marker seen" "$required_marker_timeout_secs" session_output_has_marker "$required_marker"; then
      :
    else
      failure_message="$checkpoint_failure_message"
      break
    fi
  done <<< "$required_markers_raw"
  if [[ -z "$failure_message" ]]; then
    required_markers_seen=true
  fi
fi

if [[ -z "$failure_message" ]]; then
  case "$frame_capture_mode" in
    publish)
      if wait_for_checkpoint "frame artifact written on device" "$frame_checkpoint_timeout_secs" pixel_root_file_nonempty "$serial" "$frame_path"; then
        frame_on_device=true
      else
        failure_message="$checkpoint_failure_message"
      fi
      ;;
    request)
      if wait_for_checkpoint "frame artifact requested from compositor" "$frame_checkpoint_timeout_secs" request_frame_artifact; then
        frame_on_device=true
      else
        failure_message="$checkpoint_failure_message"
      fi
      ;;
    off)
      checkpoint_note "skipping frame artifact capture"
      ;;
  esac
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
  if [[ -z "$session_exit_timeout_secs" ]]; then
    set +e
    wait "$session_pid"
    session_status="$?"
    set -e
  elif pixel_wait_for_condition "$session_exit_timeout_secs" 1 session_completed; then
    if session_still_running; then
      checkpoint_note "observed: session exit recorded in output; ending lingering host shell"
      kill "$session_pid" >/dev/null 2>&1 || true
      set +e
      wait "$session_pid" >/dev/null 2>&1 || true
      set -e
    else
      set +e
      wait "$session_pid"
      if [[ -z "${session_status:-}" ]]; then
        session_status="$?"
      fi
      set -e
    fi
  else
    checkpoint_note "session still running after success window; forcing cleanup"
    kill "$session_pid" >/dev/null 2>&1 || true
    wait "$session_pid" >/dev/null 2>&1 || session_status="$?"
    if [[ -n "$restore_android" ]]; then
      restore_android_now || true
    fi
  fi
fi

set +e
if [[ ! -s "$frame_artifact" ]]; then
  if ensure_post_success_adb 5; then
    pixel_adb "$serial" pull "$frame_path" "$frame_artifact" >"$pull_log_path" 2>&1
  else
    printf 'skipped: adb unavailable during post-success frame pull\n' >"$pull_log_path"
  fi
fi
set -e

sleep 3
cleanup
logcat_pid=""
set +e
if ensure_post_success_adb 5; then
  pixel_capture_processes "$serial" "$run_dir/processes-after.txt"
else
  : >"$run_dir/processes-after.txt"
fi
set -e

if [[ ! -s "$frame_artifact" && "$frame_on_device" == true ]]; then
  set +e
  if ensure_post_success_adb 5; then
    pixel_adb "$serial" pull "$frame_path" "$frame_artifact" >"$pull_log_path" 2>&1
  fi
  set -e
fi

set +e
verify_frame_required=1
if [[ "$frame_capture_mode" == "off" ]]; then
  verify_frame_required=""
fi
PIXEL_VERIFY_FRAME_REQUIRED="$verify_frame_required" \
PIXEL_VERIFY_REQUIRE_CLIENT_MARKER="$verify_require_client_marker" \
PIXEL_VERIFY_REQUIRED_MARKERS="$required_markers_raw" \
PIXEL_VERIFY_FORBIDDEN_MARKERS="$verify_forbidden_markers" \
PIXEL_RUN_DIR="$run_dir" \
  "$SCRIPT_DIR/pixel/pixel_verify.sh"
verify_status="$?"
set -e
if [[ "$compositor_marker_seen" != true ]] && session_output_has_marker "$(pixel_compositor_marker)"; then
  compositor_marker_seen=true
  presented=true
fi
if [[ "$client_marker_seen" != true ]] && session_output_has_marker "$(pixel_client_marker)"; then
  client_marker_seen=true
fi
if [[ "$required_markers_seen" != true ]] && required_markers_all_seen; then
  required_markers_seen=true
fi
if [[ "$forbidden_markers_clear" != false ]] && ! forbidden_markers_absent; then
  forbidden_markers_clear=false
fi
if [[ "$frame_on_device" != true && -s "$frame_artifact" ]]; then
  frame_on_device=true
fi

if [[ -n "$restore_android" && "$android_restored" != true ]]; then
  if [[ "$restore_in_session" != "0" ]] \
    && ensure_post_success_adb "$restore_checkpoint_timeout_secs" \
    && pixel_wait_for_condition "$restore_checkpoint_timeout_secs" 1 pixel_android_display_restored "$serial"; then
    android_restored=true
  fi
  if [[ "$android_restored" != true ]] && ensure_post_success_adb "$restore_checkpoint_timeout_secs"; then
    restore_android_now || true
  fi
  if [[ "$android_restored" != true && "$reboot_on_restore_failure" != "0" ]]; then
    restore_android_via_reboot || true
  fi
  if [[ "$android_restored" != true ]]; then
    failure_message="${failure_message:-timed out waiting for Android display stack restore}"
  fi
fi

if [[ "$startup_ok" == true ]]; then
  if [[ -n "$restore_android" && "$android_restored" != true ]]; then
    session_ok=false
  elif [[ "$verify_status" -eq 0 && "$presented" == true ]]; then
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
  required_markers_expected="$([[ -n "$required_markers_raw" ]] && echo true || echo false)" \
  forbidden_markers_expected="$([[ -n "$verify_forbidden_markers" ]] && echo true || echo false)" \
  compositor_marker_seen="$compositor_marker_seen" \
  client_marker_seen="$client_marker_seen" \
  required_markers_seen="$required_markers_seen" \
  forbidden_markers_clear="$forbidden_markers_clear" \
  frame_capture_mode="$frame_capture_mode" \
  frame_on_device="$frame_on_device" \
  presented_frame="$presented" \
  session_ok="$session_ok" \
  android_restored="$android_restored" \
  android_restore_rebooted="$android_restore_rebooted" \
  post_success_adb_lost="$post_success_adb_lost" \
  post_success_transport_warning="$post_success_transport_warning" \
  failure_kind="$checkpoint_failure_kind" \
  failure_description="$checkpoint_failure_description" \
  failure_message="$failure_message" \
  success="$([[ "$session_ok" == true && "$verify_status" -eq 0 && "$presented" == true ]] && echo true || echo false)"

cat "$run_dir/status.json"

if [[ -n "$runtime_summary_renderer" ]]; then
  python3 "$SCRIPT_DIR/pixel/pixel_runtime_summary.py" \
    "$run_dir" \
    --renderer "$runtime_summary_renderer" \
    --output "$run_dir/gpu-summary.json"
fi

if [[ "$startup_ok" != true || "$session_ok" != true || "$verify_status" -ne 0 || "$presented" != true ]]; then
  if [[ -n "$failure_message" ]]; then
    echo "pixel_guest_ui_drm: $failure_message" >&2
    echo "pixel_guest_ui_drm: checkpoints: $checkpoint_log_path" >&2
  fi
  exit 1
fi

printf 'Pixel rooted guest UI takeover succeeded: %s\n' "$run_dir"
