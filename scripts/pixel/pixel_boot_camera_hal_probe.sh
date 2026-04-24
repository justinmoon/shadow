#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_DIR=""
DRY_RUN=0
ADB_TIMEOUT_SECS="${PIXEL_BOOT_CAMERA_HAL_ADB_TIMEOUT_SECS:-240}"
BOOT_TIMEOUT_SECS="${PIXEL_BOOT_CAMERA_HAL_BOOT_TIMEOUT_SECS:-180}"
HOLD_SECS="${PIXEL_BOOT_CAMERA_HAL_HOLD_SECS:-2}"
WATCHDOG_TIMEOUT_SECS="${PIXEL_BOOT_CAMERA_HAL_WATCHDOG_TIMEOUT_SECS:-45}"
CAMERA_LINKER_CAPSULE_MODE="${PIXEL_BOOT_CAMERA_HAL_LINKER_CAPSULE_MODE:-auto}"
CAMERA_LINKER_CAPSULE_DIR="${PIXEL_CAMERA_LINKER_CAPSULE_DIR:-}"
CAMERA_LINKER_CAPSULE_INCLUDE_COMPONENTS="${PIXEL_BOOT_CAMERA_HAL_LINKER_CAPSULE_INCLUDE_COMPONENTS:-false}"
CAMERA_HAL_CAMERA_ID="${PIXEL_BOOT_CAMERA_HAL_CAMERA_ID:-${PIXEL_CAMERA_HAL_CAMERA_ID:-0}}"
CAMERA_HAL_CALL_OPEN="${PIXEL_BOOT_CAMERA_HAL_CALL_OPEN:-${PIXEL_CAMERA_HAL_CALL_OPEN:-false}}"
ORIGINAL_ARGS=("$@")

serial=""
run_token=""
image_path=""
status_path=""
build_output_path=""
oneshot_output_path=""
oneshot_stderr_path=""
oneshot_dir=""
recover_dir=""
probe_json_path=""
device_output_path=""
dmesg_path=""
capsule_output_path=""
failure_stage=""
build_succeeded=false
capsule_collected=false
oneshot_attempted=false
oneshot_status=""
probe_summary_present=false
frame_captured=false

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_camera_hal_probe.sh [--output DIR]
                                                    [--adb-timeout SECONDS]
                                                    [--boot-timeout SECONDS]
                                                    [--hold-secs SECONDS]
                                                    [--watchdog-timeout SECONDS]
                                                    [--camera-id ID]
                                                    [--camera-hal-call-open true|false]
                                                    [--camera-linker-capsule DIR]
                                                    [--camera-linker-capsule-components true|false]
                                                    [--no-camera-linker-capsule]
                                                    [--dry-run]

Build and one-shot boot the Rust-owned Shadow boot camera HAL probe. The probe
directly attempts /vendor/lib64/hw/camera.sm6150.so from hello-init userspace and
recovers the durable metadata bundle after Android returns.
EOF
}

bool_word() {
  if [[ "$1" == "1" || "$1" == "true" ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

validate_bool_arg() {
  local label value
  label="$1"
  value="$2"
  case "$value" in
    true|false)
      ;;
    *)
      echo "pixel_boot_camera_hal_probe: $label must be true or false: $value" >&2
      exit 1
      ;;
  esac
}

safe_path_component() {
  tr -c 'A-Za-z0-9._-' '_' <<<"$1" | sed 's/_$//'
}

resolve_serial_for_mode() {
  if [[ "$DRY_RUN" == "1" && -n "${PIXEL_SERIAL:-}" ]]; then
    printf '%s\n' "$PIXEL_SERIAL"
    return 0
  fi

  pixel_resolve_serial
}

prepare_output_dir() {
  local safe_serial

  if [[ -z "$OUTPUT_DIR" ]]; then
    safe_serial="$(safe_path_component "$serial")"
    OUTPUT_DIR="$(pixel_dir)/camera-boot-hal/$(pixel_timestamp)-$safe_serial"
  fi

  if [[ -e "$OUTPUT_DIR" ]] && find "$OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    echo "pixel_boot_camera_hal_probe: output dir must be empty or absent: $OUTPUT_DIR" >&2
    exit 1
  fi

  if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p "$OUTPUT_DIR"
  fi
}

default_run_token() {
  local safe_serial token
  safe_serial="$(safe_path_component "$serial")"
  token="camera-hal-$(date -u +%Y%m%dT%H%M%SZ)-$safe_serial"
  printf '%.63s\n' "$token"
}

copy_if_present() {
  local source_path destination_path placeholder
  source_path="$1"
  destination_path="$2"
  placeholder="$3"

  if [[ -s "$source_path" ]]; then
    cp "$source_path" "$destination_path"
  else
    printf '%s\n' "$placeholder" >"$destination_path"
  fi
}

write_blocker_probe_json() {
  local reason
  reason="$1"
  python3 - "$probe_json_path" "$run_token" "$reason" <<'PY'
import json
import sys

output, run_token, reason = sys.argv[1:4]
payload = {
    "schemaVersion": 1,
    "kind": "camera-boot-hal-probe",
    "mode": "camera-hal-link-probe",
    "runToken": run_token,
    "halPath": "/vendor/lib64/hw/camera.sm6150.so",
    "androidCameraApiUse": {
        "ICameraProvider": False,
        "cameraserver": False,
        "javaCamera2": False,
        "rootedAndroidShellCameraApi": False,
        "rootedAndroidShellRecoveryOnly": True,
    },
    "frameCapture": {"attempted": False, "captured": False, "artifactPath": None},
    "blockerStage": "recover",
    "blocker": reason,
}
with open(output, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

write_status_json() {
  local exit_code ok
  exit_code="${1:-1}"
  ok=false
  if [[ "$exit_code" -eq 0 ]]; then
    ok=true
  fi

  [[ -n "$status_path" ]] || return 0

  python3 - \
    "$status_path" \
    "$ok" \
    "$serial" \
    "$OUTPUT_DIR" \
    "$run_token" \
    "$image_path" \
    "$build_output_path" \
    "$oneshot_output_path" \
    "$oneshot_stderr_path" \
    "$oneshot_dir" \
    "$recover_dir" \
    "$probe_json_path" \
    "$device_output_path" \
    "$dmesg_path" \
    "$CAMERA_HAL_CAMERA_ID" \
    "$CAMERA_HAL_CALL_OPEN" \
    "$CAMERA_LINKER_CAPSULE_DIR" \
    "$CAMERA_LINKER_CAPSULE_INCLUDE_COMPONENTS" \
    "$capsule_output_path" \
    "$failure_stage" \
    "$build_succeeded" \
    "$capsule_collected" \
    "$oneshot_attempted" \
    "$oneshot_status" \
    "$probe_summary_present" \
    "$frame_captured" <<'PY'
import json
import sys
from pathlib import Path

(
    output,
    ok,
    serial,
    output_dir,
    run_token,
    image_path,
    build_output_path,
    oneshot_output_path,
    oneshot_stderr_path,
    oneshot_dir,
    recover_dir,
    probe_json_path,
    device_output_path,
    dmesg_path,
    camera_hal_camera_id,
    camera_hal_call_open,
    camera_linker_capsule_dir,
    camera_linker_capsule_include_components,
    capsule_output_path,
    failure_stage,
    build_succeeded,
    capsule_collected,
    oneshot_attempted,
    oneshot_status,
    probe_summary_present,
    frame_captured,
) = sys.argv[1:27]

probe = {}
probe_path = Path(probe_json_path)
if probe_path.is_file():
    try:
        probe = json.loads(probe_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        probe = {"parseError": str(exc)}

recover_status_path = Path(recover_dir) / "status.json" if recover_dir else None
oneshot_status_path = Path(oneshot_dir) / "status.json" if oneshot_dir else None

payload = {
    "kind": "camera_boot_hal_probe_run",
    "ok": ok == "true",
    "proof_ok": probe_summary_present == "true",
    "serial": serial,
    "output_dir": output_dir,
    "run_token": run_token,
    "image": image_path,
    "build_output_path": build_output_path,
    "oneshot_output_path": oneshot_output_path,
    "oneshot_stderr_path": oneshot_stderr_path,
    "oneshot_dir": oneshot_dir,
    "oneshot_status_path": str(oneshot_status_path) if oneshot_status_path else "",
    "oneshot_status": int(oneshot_status) if oneshot_status not in ("", None) else None,
    "recover_dir": recover_dir,
    "recover_status_path": str(recover_status_path) if recover_status_path else "",
    "boot_hal_probe_json": probe_json_path,
    "device_output_path": device_output_path,
    "dmesg_path": dmesg_path,
    "camera_hal_camera_id": camera_hal_camera_id,
    "camera_hal_call_open": camera_hal_call_open == "true",
    "camera_linker_capsule_dir": camera_linker_capsule_dir,
    "camera_linker_capsule_include_components": camera_linker_capsule_include_components == "true",
    "capsule_output_path": capsule_output_path,
    "failure_stage": failure_stage,
    "build_succeeded": build_succeeded == "true",
    "capsule_collected": capsule_collected == "true",
    "oneshot_attempted": oneshot_attempted == "true",
    "probe_summary_present": probe_summary_present == "true",
    "frame_captured": frame_captured == "true",
    "blocker_stage": probe.get("blockerStage", ""),
    "blocker": probe.get("blocker", ""),
    "android_camera_api_use": probe.get("androidCameraApiUse", {}),
}
if probe:
    payload["probe"] = probe

with open(output, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

finish() {
  local exit_code=$?
  trap - EXIT
  write_status_json "$exit_code"
  exit "$exit_code"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_DIR="${2:?missing value for --output}"
      shift 2
      ;;
    --adb-timeout)
      ADB_TIMEOUT_SECS="${2:?missing value for --adb-timeout}"
      shift 2
      ;;
    --boot-timeout)
      BOOT_TIMEOUT_SECS="${2:?missing value for --boot-timeout}"
      shift 2
      ;;
    --hold-secs)
      HOLD_SECS="${2:?missing value for --hold-secs}"
      shift 2
      ;;
    --watchdog-timeout)
      WATCHDOG_TIMEOUT_SECS="${2:?missing value for --watchdog-timeout}"
      shift 2
      ;;
    --camera-id)
      CAMERA_HAL_CAMERA_ID="${2:?missing value for --camera-id}"
      shift 2
      ;;
    --camera-hal-call-open)
      CAMERA_HAL_CALL_OPEN="${2:?missing value for --camera-hal-call-open}"
      shift 2
      ;;
    --camera-linker-capsule)
      CAMERA_LINKER_CAPSULE_DIR="${2:?missing value for --camera-linker-capsule}"
      CAMERA_LINKER_CAPSULE_MODE="provided"
      shift 2
      ;;
    --camera-linker-capsule-components)
      CAMERA_LINKER_CAPSULE_INCLUDE_COMPONENTS="${2:?missing value for --camera-linker-capsule-components}"
      shift 2
      ;;
    --no-camera-linker-capsule)
      CAMERA_LINKER_CAPSULE_MODE="none"
      CAMERA_LINKER_CAPSULE_DIR=""
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "pixel_boot_camera_hal_probe: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

for numeric_value in "$ADB_TIMEOUT_SECS" "$BOOT_TIMEOUT_SECS" "$HOLD_SECS" "$WATCHDOG_TIMEOUT_SECS"; do
  if [[ ! "$numeric_value" =~ ^[0-9]+$ ]]; then
    echo "pixel_boot_camera_hal_probe: timeout and hold values must be integers" >&2
    exit 1
  fi
done
validate_bool_arg camera-linker-capsule-components "$CAMERA_LINKER_CAPSULE_INCLUDE_COMPONENTS"
validate_bool_arg camera-hal-call-open "$CAMERA_HAL_CALL_OPEN"
if [[ ! "$CAMERA_HAL_CAMERA_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "pixel_boot_camera_hal_probe: camera id must be a non-empty safe token: $CAMERA_HAL_CAMERA_ID" >&2
  exit 1
fi

serial="$(resolve_serial_for_mode)"
pixel_prepare_dirs
prepare_output_dir

run_token="${PIXEL_BOOT_CAMERA_HAL_RUN_TOKEN:-$(default_run_token)}"
image_path="$OUTPUT_DIR/camera-boot-hal.img"
status_path="$OUTPUT_DIR/status.json"
build_output_path="$OUTPUT_DIR/build-output.txt"
oneshot_output_path="$OUTPUT_DIR/oneshot-output.txt"
oneshot_stderr_path="$OUTPUT_DIR/oneshot-stderr.txt"
oneshot_dir="$OUTPUT_DIR/oneshot"
recover_dir="$oneshot_dir/recover-traces"
probe_json_path="$OUTPUT_DIR/boot-hal-probe.json"
device_output_path="$OUTPUT_DIR/device-output.txt"
dmesg_path="$OUTPUT_DIR/dmesg.txt"
capsule_output_path="$OUTPUT_DIR/camera-linker-capsule-output.txt"
if [[ "$CAMERA_LINKER_CAPSULE_MODE" == "auto" ]]; then
  CAMERA_LINKER_CAPSULE_DIR="$OUTPUT_DIR/camera-linker-capsule"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  dry_run_capsule_command=disabled
  dry_run_build_command="$SCRIPT_DIR/pixel/pixel_boot_build_orange_gpu.sh --output \"$image_path\" --orange-gpu-mode camera-hal-link-probe --orange-gpu-metadata-stage-breadcrumb true --run-token \"$run_token\" --camera-hal-camera-id \"$CAMERA_HAL_CAMERA_ID\" --camera-hal-call-open $CAMERA_HAL_CALL_OPEN"
  if [[ "$CAMERA_LINKER_CAPSULE_MODE" != "none" ]]; then
    dry_run_capsule_command="$SCRIPT_DIR/pixel/pixel_camera_hal_collect_capsule.sh --output \"$CAMERA_LINKER_CAPSULE_DIR\" --include-camera-components $CAMERA_LINKER_CAPSULE_INCLUDE_COMPONENTS"
    dry_run_build_command+=" --camera-linker-capsule \"$CAMERA_LINKER_CAPSULE_DIR\""
  fi
  cat <<EOF
pixel_boot_camera_hal_probe: dry-run
serial=$serial
output_dir=$OUTPUT_DIR
run_token=$run_token
image=$image_path
adb_timeout_secs=$ADB_TIMEOUT_SECS
boot_timeout_secs=$BOOT_TIMEOUT_SECS
hold_secs=$HOLD_SECS
watchdog_timeout_secs=$WATCHDOG_TIMEOUT_SECS
camera_id=$CAMERA_HAL_CAMERA_ID
camera_hal_call_open=$CAMERA_HAL_CALL_OPEN
camera_linker_capsule_mode=$CAMERA_LINKER_CAPSULE_MODE
camera_linker_capsule_dir=$CAMERA_LINKER_CAPSULE_DIR
camera_linker_capsule_include_components=$CAMERA_LINKER_CAPSULE_INCLUDE_COMPONENTS
capsule_command=$dry_run_capsule_command
build_command=$dry_run_build_command
run_command=$SCRIPT_DIR/pixel/pixel_boot_oneshot.sh --image "$image_path" --output "$oneshot_dir" --skip-collect --recover-traces-after --no-wait-boot-completed
EOF
  exit 0
fi

trap finish EXIT

if [[ "$CAMERA_LINKER_CAPSULE_MODE" != "none" ]]; then
  if [[ "$CAMERA_LINKER_CAPSULE_MODE" == "auto" ]]; then
    if ! PIXEL_SERIAL="$serial" "$SCRIPT_DIR/pixel/pixel_camera_hal_collect_capsule.sh" \
      --output "$CAMERA_LINKER_CAPSULE_DIR" \
      --include-camera-components "$CAMERA_LINKER_CAPSULE_INCLUDE_COMPONENTS" \
      --adb-timeout "$ADB_TIMEOUT_SECS" \
      >"$capsule_output_path" 2>&1; then
      failure_stage="collect-camera-linker-capsule"
      write_blocker_probe_json "failed to collect camera HAL linker capsule from rooted Android"
      exit 1
    fi
    capsule_collected=true
  elif [[ ! -d "$CAMERA_LINKER_CAPSULE_DIR" ]]; then
    failure_stage="camera-linker-capsule"
    write_blocker_probe_json "camera HAL linker capsule directory was not found"
    exit 1
  fi
fi

build_args=(
  "$SCRIPT_DIR/pixel/pixel_boot_build_orange_gpu.sh"
  --output "$image_path"
  --orange-gpu-mode camera-hal-link-probe
  --orange-gpu-metadata-stage-breadcrumb true
  --hold-secs "$HOLD_SECS"
  --orange-gpu-watchdog-timeout-secs "$WATCHDOG_TIMEOUT_SECS"
  --reboot-target bootloader
  --run-token "$run_token"
  --dev-mount tmpfs
  --mount-dev true
  --mount-proc true
  --mount-sys true
  --camera-hal-camera-id "$CAMERA_HAL_CAMERA_ID"
  --camera-hal-call-open "$CAMERA_HAL_CALL_OPEN"
)
if [[ "$CAMERA_LINKER_CAPSULE_MODE" != "none" ]]; then
  build_args+=(--camera-linker-capsule "$CAMERA_LINKER_CAPSULE_DIR")
fi

if ! "${build_args[@]}" >"$build_output_path" 2>&1; then
  failure_stage="build"
  write_blocker_probe_json "failed to build camera HAL boot probe image"
  exit 1
fi
build_succeeded=true

oneshot_attempted=true
set +e
PIXEL_SERIAL="$serial" \
  "$SCRIPT_DIR/pixel/pixel_boot_oneshot.sh" \
    --image "$image_path" \
    --output "$oneshot_dir" \
    --adb-timeout "$ADB_TIMEOUT_SECS" \
    --boot-timeout "$BOOT_TIMEOUT_SECS" \
    --skip-collect \
    --recover-traces-after \
    --no-wait-boot-completed \
    >"$oneshot_output_path" 2>"$oneshot_stderr_path"
oneshot_status=$?
set -e

if [[ -s "$recover_dir/channels/metadata-probe-summary.json" ]]; then
  cp "$recover_dir/channels/metadata-probe-summary.json" "$probe_json_path"
  probe_summary_present=true
else
  failure_stage="${failure_stage:-recover-summary}"
  write_blocker_probe_json "metadata probe summary was not recovered from the boot run"
fi

copy_if_present \
  "$recover_dir/channels/metadata-probe-report.txt" \
  "$device_output_path" \
  "metadata probe report was not recovered"
copy_if_present \
  "$recover_dir/channels/kernel-current-best-effort.txt" \
  "$dmesg_path" \
  "kernel log was not recovered"

frame_captured="$(
  python3 - "$probe_json_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)
frame = payload.get("frameCapture", {})
print("true" if isinstance(frame, dict) and frame.get("captured") is True else "false")
PY
)"

if [[ "$probe_summary_present" == "true" ]]; then
  printf 'Recovered camera boot HAL probe: %s\n' "$probe_json_path"
  printf 'Run status: %s\n' "$status_path"
  exit 0
fi

printf 'Camera boot HAL probe did not recover a summary; see %s\n' "$status_path" >&2
exit 1
