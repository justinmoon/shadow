#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs
serial="$(pixel_resolve_serial)"
repo="$(repo_root)"
run_root="$(pixel_dir)/camera-rs"
run_dir="$(pixel_prepare_named_run_dir "$run_root")"
artifact="$(pixel_artifact_path shadow-camera-provider-host)"
android_shell_ref="$repo#android"
android_abi="arm64-v8a"
android_target="aarch64-linux-android"
android_platform="${PIXEL_CAMERA_RS_PLATFORM:-31}"
device_binary="${PIXEL_CAMERA_RS_DEVICE_BINARY:-/data/local/tmp/shadow-camera-provider-host}"
profile="${PIXEL_CAMERA_RS_PROFILE:-debug}"
command="${1:-ping}"

if [[ "$#" -gt 0 ]]; then
  shift
fi

build_log_path="$run_dir/build-output.txt"
device_output_path="$run_dir/device-output.txt"
device_command_path="$run_dir/device-command.txt"
checkpoint_log_path="$run_dir/checkpoints.txt"
file_output_path="$run_dir/file.txt"

build_device_command() {
  local quoted=()
  local arg
  for arg in "$@"; do
    quoted+=("$(printf '%q' "$arg")")
  done
  printf '%s' "${quoted[*]}"
}

printf '[camera-rs] run_dir=%s\n' "$run_dir" | tee -a "$checkpoint_log_path"
printf '[camera-rs] serial=%s\n' "$serial" | tee -a "$checkpoint_log_path"
printf '[camera-rs] android_shell=%s\n' "$android_shell_ref" | tee -a "$checkpoint_log_path"
printf '[camera-rs] android_platform=%s\n' "$android_platform" | tee -a "$checkpoint_log_path"

release_flag=""
if [[ "$profile" == "release" ]]; then
  release_flag=" --release"
elif [[ "$profile" != "debug" ]]; then
  echo "pixel_camera_rs_run: unsupported PIXEL_CAMERA_RS_PROFILE: $profile" >&2
  exit 1
fi

build_command="cd $(printf '%q' "$repo/rust/shadow-camera-provider-host") && cargo ndk -P $android_platform -t $android_abi build$release_flag"
nix develop --accept-flake-config "$android_shell_ref" -c bash -lc "$build_command" >"$build_log_path" 2>&1

binary_path="$repo/rust/shadow-camera-provider-host/target/$android_target/$profile/shadow-camera-provider-host"
if [[ ! -f "$binary_path" ]]; then
  echo "pixel_camera_rs_run: expected built binary not found: $binary_path" >&2
  exit 1
fi

cp "$binary_path" "$artifact"
chmod 0755 "$artifact"
file "$artifact" | tee "$file_output_path"
printf '[camera-rs] built=%s\n' "$artifact" | tee -a "$checkpoint_log_path"

pixel_adb "$serial" push "$artifact" "$device_binary" >/dev/null
printf '[camera-rs] pushed=%s\n' "$device_binary" | tee -a "$checkpoint_log_path"

device_command="$(build_device_command "$device_binary" "$command" "$@")"
printf 'chmod 0755 %s && id && getenforce && %s\n' \
  "$(printf '%q' "$device_binary")" \
  "$device_command" >"$device_command_path"

set +e
pixel_root_shell "$serial" "$(cat "$device_command_path")" >"$device_output_path" 2>&1
run_status="$?"
set -e

helper_status=1
if [[ "$run_status" -eq 0 ]]; then
  if pixel_last_json_ok "$device_output_path"; then
    helper_status=0
  else
    helper_status="$?"
  fi
fi

pixel_write_status_json "$run_dir/status.json" \
  androidShell="$android_shell_ref" \
  androidPlatform="$android_platform" \
  androidTarget="$android_target" \
  command="$command" \
  deviceBinary="$device_binary" \
  helperSucceeded="$([[ "$helper_status" -eq 0 ]] && printf true || printf false)" \
  profile="$profile" \
  runSucceeded="$([[ "$run_status" -eq 0 ]] && printf true || printf false)" \
  serial="$serial"

if [[ "$run_status" -ne 0 ]]; then
  echo "pixel_camera_rs_run: device command failed; see $device_output_path" >&2
  exit "$run_status"
fi

cat "$device_output_path"
printf '[camera-rs] success -> %s\n' "$run_dir" | tee -a "$checkpoint_log_path"

if [[ "$helper_status" -ne 0 ]]; then
  echo "pixel_camera_rs_run: helper reported ok=false; see $device_output_path" >&2
  exit 1
fi
