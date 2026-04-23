#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs
serial="$(pixel_resolve_serial)"
pixel_require_host_lock "$serial" "$0" "$@"
repo="$(repo_root)"
artifact="$(pixel_artifact_path shadow-camera-provider-host)"
android_shell_ref="$repo#android"
android_abi="arm64-v8a"
android_target="aarch64-linux-android"
android_platform="${PIXEL_CAMERA_RS_PLATFORM:-31}"
device_binary="${PIXEL_CAMERA_RS_DEVICE_BINARY:-/data/local/tmp/shadow-camera-provider-host}"
profile="${PIXEL_CAMERA_RS_PROFILE:-debug}"
command="${1:-ping}"

case "$command" in
  linux-probe)
    run_root="$(pixel_dir)/camera-linux-api"
    ;;
  hal-probe | hal-frame-probe | hal-provider-frame-probe)
    run_root="$(pixel_dir)/camera-hal-api"
    ;;
  *)
    run_root="$(pixel_dir)/camera-rs"
    ;;
esac
run_dir="$(pixel_prepare_named_run_dir "$run_root")"

if [[ "$#" -gt 0 ]]; then
  shift
fi

build_log_path="$run_dir/build-output.txt"
device_output_path="$run_dir/device-output.txt"
device_command_path="$run_dir/device-command.txt"
checkpoint_log_path="$run_dir/checkpoints.txt"
file_output_path="$run_dir/file.txt"
linux_probe_json_path="$run_dir/linux-probe.json"
hal_probe_json_path="$run_dir/hal-probe.json"
frame_output_path="$run_dir/provider-frame.jpg"
frame_pull_log_path="$run_dir/pull-frame.txt"
frame_device_path=""
frame_pulled=false

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

probe_json_path=""
case "$command" in
  linux-probe)
    probe_json_path="$linux_probe_json_path"
    ;;
  hal-probe | hal-frame-probe | hal-provider-frame-probe)
    probe_json_path="$hal_probe_json_path"
    ;;
esac

if [[ -n "$probe_json_path" ]]; then
  python3 - "$device_output_path" "$probe_json_path" <<'PY'
import json
import sys

input_path, output_path = sys.argv[1:3]
payload = None

with open(input_path, "r", encoding="utf-8", errors="replace") as fh:
    for raw_line in fh:
        line = raw_line.strip()
        if not line.startswith("{") or not line.endswith("}"):
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue

if payload is None:
    sys.exit(0)

with open(output_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
fi

if [[ "$command" == "hal-frame-probe" || "$command" == "hal-provider-frame-probe" ]]; then
  if [[ -f "$hal_probe_json_path" ]]; then
    frame_device_path="$(python3 - "$hal_probe_json_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

path = (
    payload.get("frameCapture", {}).get("outputPath")
    or payload.get("providerFrameAttempt", {}).get("outputPath")
    or ""
)
if path:
    print(path)
PY
)"
  fi

  if [[ -n "$frame_device_path" ]]; then
    quoted_frame_path="$(printf '%q' "$frame_device_path")"
    pixel_root_shell "$serial" "chmod 0644 $quoted_frame_path" >/dev/null 2>&1 || true
    if pixel_adb "$serial" shell "[ -f $quoted_frame_path ]" >/dev/null 2>&1; then
      if pixel_adb "$serial" pull "$frame_device_path" "$frame_output_path" >"$frame_pull_log_path" 2>&1; then
        frame_pulled=true
      fi
    else
      printf 'missing: %s\n' "$frame_device_path" >"$frame_pull_log_path"
    fi
  else
    printf 'no frame outputPath in %s\n' "$hal_probe_json_path" >"$frame_pull_log_path"
  fi

  if [[ "$helper_status" -eq 0 && "$frame_pulled" != true ]]; then
    helper_status=1
  fi
fi

pixel_write_status_json "$run_dir/status.json" \
  androidShell="$android_shell_ref" \
  androidPlatform="$android_platform" \
  androidTarget="$android_target" \
  command="$command" \
  deviceBinary="$device_binary" \
  frameDevicePath="$frame_device_path" \
  frameOutputPath="$([[ "$frame_pulled" == true ]] && printf '%s' "$frame_output_path" || printf '')" \
  framePulled="$frame_pulled" \
  helperSucceeded="$([[ "$helper_status" -eq 0 ]] && printf true || printf false)" \
  halProbeJson="$([[ "$command" == "hal-probe" || "$command" == "hal-frame-probe" || "$command" == "hal-provider-frame-probe" ]] && printf '%s' "$hal_probe_json_path" || printf '')" \
  linuxProbeJson="$([[ "$command" == "linux-probe" ]] && printf '%s' "$linux_probe_json_path" || printf '')" \
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
