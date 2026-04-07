#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs
serial="$(pixel_resolve_serial)"
repo="$(repo_root)"
run_root="$(pixel_dir)/camera-rs-takeover"
run_dir="$(pixel_prepare_named_run_dir "$run_root")"
checkpoint_log_path="$run_dir/checkpoints.txt"
build_log_path="$run_dir/build-output.txt"
file_output_path="$run_dir/file.txt"
device_command_path="$run_dir/device-command.txt"
device_output_path="$run_dir/device-output.txt"
logcat_path="$run_dir/logcat.txt"
service_states_path="$run_dir/service-states.txt"
device_props_path="$run_dir/device-props.txt"
processes_before_path="$run_dir/processes-before.txt"
processes_after_stop_path="$run_dir/processes-after-stop.txt"
artifact="$(pixel_artifact_path shadow-camera-provider-host)"
android_shell_ref="$repo#android"
android_abi="arm64-v8a"
android_target="aarch64-linux-android"
android_platform="${PIXEL_CAMERA_RS_PLATFORM:-31}"
device_binary="${PIXEL_CAMERA_RS_DEVICE_BINARY:-/data/local/tmp/shadow-camera-provider-host}"
profile="${PIXEL_CAMERA_RS_PROFILE:-debug}"
device_timeout_secs="${PIXEL_CAMERA_RS_TAKEOVER_DEVICE_TIMEOUT_SECS:-20}"
command="${1:-capture}"
stop_allocator="${PIXEL_CAMERA_RS_TAKEOVER_STOP_ALLOCATOR:-0}"

if [[ "$#" -gt 0 ]]; then
  shift
fi

android_restored=false
run_status=1

build_device_command() {
  local quoted=()
  local arg
  for arg in "$@"; do
    quoted+=("$(printf '%q' "$arg")")
  done
  printf '%s' "${quoted[*]}"
}

capture_service_states() {
  local prefix
  prefix="$1"
  pixel_root_shell "$serial" "$(
    cat <<EOF
printf '%ssurfaceflinger=%s\n' '$prefix' "\$(getprop init.svc.surfaceflinger | tr -d '\r')"
printf '%svendor.hwcomposer-2-4=%s\n' '$prefix' "\$(getprop init.svc.vendor.hwcomposer-2-4 | tr -d '\r')"
printf '%svendor.qti.hardware.display.allocator=%s\n' '$prefix' "\$(getprop init.svc.vendor.qti.hardware.display.allocator | tr -d '\r')"
printf '%sgetenforce=%s\n' '$prefix' "\$(getenforce | tr -d '\r')"
EOF
  )" >>"$service_states_path" 2>&1 || true
}

restore_android_now() {
  if [[ "$android_restored" == true ]]; then
    return 0
  fi
  printf '[camera-rs-takeover] restoring Android display services\n' | tee -a "$checkpoint_log_path"
  if pixel_root_shell "$serial" "$(pixel_takeover_start_services_script)" >>"$checkpoint_log_path" 2>&1; then
    android_restored=true
    printf '[camera-rs-takeover] restored Android display services\n' | tee -a "$checkpoint_log_path"
    return 0
  fi
  printf '[camera-rs-takeover] restore failed\n' | tee -a "$checkpoint_log_path"
  return 1
}

cleanup() {
  set +e
  restore_android_now >/dev/null 2>&1 || true
  adb -s "$serial" logcat -d >"$logcat_path" 2>&1 || true
  capture_service_states "afterRestore."
  pixel_write_status_json "$run_dir/status.json" \
    command="$command" \
    runSucceeded="$([[ "$run_status" -eq 0 ]] && printf true || printf false)" \
    serial="$serial" \
    stopAllocator="$([[ "$stop_allocator" != "0" ]] && printf true || printf false)"
}
trap cleanup EXIT

printf '[camera-rs-takeover] run_dir=%s\n' "$run_dir" | tee -a "$checkpoint_log_path"
printf '[camera-rs-takeover] serial=%s\n' "$serial" | tee -a "$checkpoint_log_path"
printf '[camera-rs-takeover] command=%s\n' "$command" | tee -a "$checkpoint_log_path"
printf '[camera-rs-takeover] stop_allocator=%s\n' "$stop_allocator" | tee -a "$checkpoint_log_path"
printf '[camera-rs-takeover] android_shell=%s\n' "$android_shell_ref" | tee -a "$checkpoint_log_path"
printf '[camera-rs-takeover] android_platform=%s\n' "$android_platform" | tee -a "$checkpoint_log_path"

release_flag=""
if [[ "$profile" == "release" ]]; then
  release_flag=" --release"
elif [[ "$profile" != "debug" ]]; then
  echo "pixel_camera_rs_takeover: unsupported PIXEL_CAMERA_RS_PROFILE: $profile" >&2
  exit 1
fi

build_command="cd $(printf '%q' "$repo/rust/shadow-camera-provider-host") && cargo ndk -P $android_platform -t $android_abi build$release_flag"
nix develop --accept-flake-config "$android_shell_ref" -c bash -lc "$build_command" >"$build_log_path" 2>&1

binary_path="$repo/rust/shadow-camera-provider-host/target/$android_target/$profile/shadow-camera-provider-host"
if [[ ! -f "$binary_path" ]]; then
  echo "pixel_camera_rs_takeover: expected built binary not found: $binary_path" >&2
  exit 1
fi

cp "$binary_path" "$artifact"
chmod 0755 "$artifact"
file "$artifact" | tee "$file_output_path"
printf '[camera-rs-takeover] built=%s\n' "$artifact" | tee -a "$checkpoint_log_path"
pixel_adb "$serial" push "$artifact" "$device_binary" >/dev/null
printf '[camera-rs-takeover] pushed=%s\n' "$device_binary" | tee -a "$checkpoint_log_path"

pixel_capture_props "$serial" "$device_props_path"
pixel_capture_processes "$serial" "$processes_before_path"
adb -s "$serial" logcat -c || true

printf '[camera-rs-takeover] stopping display services\n' | tee -a "$checkpoint_log_path"
pixel_root_shell "$serial" "$(pixel_takeover_stop_services_script "$stop_allocator")" >>"$checkpoint_log_path" 2>&1
capture_service_states "afterStop."
pixel_adb "$serial" shell 'ps -A -o USER,PID,PPID,NAME,ARGS 2>/dev/null' >"$processes_after_stop_path" || true

device_command="$(build_device_command "$device_binary" "$command" "$@")"
printf 'chmod 0755 %s && id && getenforce && timeout %s %s\n' \
  "$(printf '%q' "$device_binary")" \
  "$device_timeout_secs" \
  "$device_command" >"$device_command_path"

set +e
pixel_root_shell "$serial" "$(cat "$device_command_path")" >"$device_output_path" 2>&1
run_status="$?"
set -e

cat "$device_output_path"

if [[ "$run_status" -ne 0 ]]; then
  printf '[camera-rs-takeover] helper failed -> %s\n' "$run_dir" | tee -a "$checkpoint_log_path"
  exit "$run_status"
fi

printf '[camera-rs-takeover] success -> %s\n' "$run_dir" | tee -a "$checkpoint_log_path"
