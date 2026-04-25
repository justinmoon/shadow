#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_DIR=""
DRY_RUN=0
ADB_TIMEOUT_SECS="${PIXEL_BOOT_WIFI_ADB_TIMEOUT_SECS:-240}"
BOOT_TIMEOUT_SECS="${PIXEL_BOOT_WIFI_BOOT_TIMEOUT_SECS:-180}"
HOLD_SECS="${PIXEL_BOOT_WIFI_HOLD_SECS:-2}"
WATCHDOG_TIMEOUT_SECS="${PIXEL_BOOT_WIFI_WATCHDOG_TIMEOUT_SECS:-180}"
PROOF_MODE="${PIXEL_BOOT_WIFI_PROOF_MODE:-scan}"
WIFI_HELPER_PROFILE="${PIXEL_BOOT_WIFI_HELPER_PROFILE:-vnd-sm-core-binder-node}"
WIFI_CREDENTIALS_FILE="${PIXEL_BOOT_WIFI_CREDENTIALS_FILE:-}"
WIFI_DHCP_CLIENT_BINARY="${PIXEL_BOOT_WIFI_DHCP_CLIENT_BIN:-}"
WIFI_ASSETS_MODE="${PIXEL_BOOT_WIFI_ASSETS_MODE:-auto}"
WIFI_ASSETS_DIR="${PIXEL_WIFI_BOOT_ASSETS_DIR:-}"
WIFI_LINKER_CAPSULE_MODE="${PIXEL_BOOT_WIFI_LINKER_CAPSULE_MODE:-auto}"
WIFI_LINKER_CAPSULE_DIR="${PIXEL_WIFI_LINKER_CAPSULE_DIR:-${PIXEL_CAMERA_LINKER_CAPSULE_DIR:-}}"

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
assets_output_path=""
capsule_output_path=""
failure_stage=""
assets_collected=false
capsule_collected=false
build_succeeded=false
oneshot_attempted=false
oneshot_status=""
probe_summary_present=false
scan_proof_ok=false
wifi_credentials_device_path=""
wifi_credentials_remote_tmp=""
wifi_credentials_tmp_device_path=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_wifi_probe.sh [--output DIR]
                                               [--adb-timeout SECONDS]
                                               [--boot-timeout SECONDS]
                                               [--hold-secs SECONDS]
                                               [--watchdog-timeout SECONDS]
                                               [--proof-mode surface|scan|association|ip]
                                               [--wifi-helper-profile full|no-service-managers|no-pm|no-modem-svc|no-rfs-storage|no-pd-mapper|no-cnss|qrtr-only|qrtr-pd|qrtr-pd-tftp|qrtr-pd-rfs|qrtr-pd-rfs-cnss|qrtr-pd-rfs-modem|qrtr-pd-rfs-modem-cnss|qrtr-pd-rfs-modem-pm|qrtr-pd-rfs-modem-pm-cnss|aidl-sm-core|vnd-sm-core|vnd-sm-core-binder-node|all-sm-core|none]
                                               [--wifi-credentials FILE]
                                               [--wifi-dhcp-client BIN]
                                               [--wifi-assets DIR]
                                               [--wifi-linker-capsule DIR]
                                               [--no-wifi-linker-capsule]
                                               [--dry-run]

Collect, build, one-shot boot, and recover the Rust-owned Shadow boot Wi-Fi
probe. Success means the recovered summary proves wlan0 activation plus vendor
wpa_supplicant control-socket PING, SCAN, and redacted SCAN_RESULTS.
EOF
}

validate_int() {
  local label value
  label="$1"
  value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "pixel_boot_wifi_probe: $label must be an integer: $value" >&2
    exit 1
  fi
}

safe_path_component() {
  tr -c 'A-Za-z0-9._-' '_' <<<"$1" | sed 's/_$//'
}

device_shell_quote() {
  local value
  value="${1:?device_shell_quote requires a value}"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

stage_wifi_credentials() {
  local command

  timeout "$ADB_TIMEOUT_SECS" adb -s "$serial" push "$WIFI_CREDENTIALS_FILE" "$wifi_credentials_remote_tmp" >/dev/null
  command=$(
    cat <<EOF
set -eu
trap 'rm -f $(device_shell_quote "$wifi_credentials_remote_tmp") $(device_shell_quote "$wifi_credentials_tmp_device_path")' EXIT
umask 077
mkdir -p /metadata/shadow-wifi-credentials/by-token
cp $(device_shell_quote "$wifi_credentials_remote_tmp") $(device_shell_quote "$wifi_credentials_tmp_device_path")
chmod 0600 $(device_shell_quote "$wifi_credentials_tmp_device_path")
chown 0:0 $(device_shell_quote "$wifi_credentials_tmp_device_path") 2>/dev/null || true
mv $(device_shell_quote "$wifi_credentials_tmp_device_path") $(device_shell_quote "$wifi_credentials_device_path")
rm -f $(device_shell_quote "$wifi_credentials_remote_tmp")
trap - EXIT
EOF
  )
  pixel_root_shell_timeout "$ADB_TIMEOUT_SECS" "$serial" "$command" >/dev/null
}

cleanup_wifi_credentials_best_effort() {
  local command timeout_secs
  if [[ -z "$wifi_credentials_device_path" && -z "$wifi_credentials_remote_tmp" && -z "$wifi_credentials_tmp_device_path" ]]; then
    return 0
  fi
  timeout_secs="${PIXEL_BOOT_WIFI_CREDENTIAL_CLEANUP_TIMEOUT_SECS:-10}"
  command=$(
    cat <<EOF
rm -f $(device_shell_quote "$wifi_credentials_device_path") $(device_shell_quote "$wifi_credentials_tmp_device_path") $(device_shell_quote "$wifi_credentials_remote_tmp")
EOF
  )
  pixel_root_shell_timeout "$timeout_secs" "$serial" "$command" >/dev/null 2>&1 || true
}

find_wifi_dhcp_client() {
  if [[ -n "$WIFI_DHCP_CLIENT_BINARY" ]]; then
    printf '%s\n' "$WIFI_DHCP_CLIENT_BINARY"
    return 0
  fi
  find /nix/store -maxdepth 3 -type f \
    -path '*busybox-static-aarch64-unknown-linux-musl-*/bin/busybox' \
    -perm -111 -print 2>/dev/null | sort | sed -n '1p'
}

validate_wifi_dhcp_client() {
  local binary_path file_output
  binary_path="${1:?validate_wifi_dhcp_client requires a binary path}"
  if [[ ! -x "$binary_path" ]]; then
    return 1
  fi
  file_output="$(file "$binary_path" 2>/dev/null || true)"
  [[ "$file_output" == *ELF* && "$file_output" == *"ARM aarch64"* && "$file_output" != *"dynamically linked"* ]]
}

resolve_serial_for_mode() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s\n' "${PIXEL_SERIAL:-dry-run}"
    return 0
  fi

  pixel_resolve_serial
}

prepare_output_dir() {
  local safe_serial

  if [[ -z "$OUTPUT_DIR" ]]; then
    safe_serial="$(safe_path_component "$serial")"
    OUTPUT_DIR="$(pixel_dir)/wifi-boot/$(pixel_timestamp)-$safe_serial"
  fi

  if [[ -e "$OUTPUT_DIR" ]] && find "$OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    echo "pixel_boot_wifi_probe: output dir must be empty or absent: $OUTPUT_DIR" >&2
    exit 1
  fi

  if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p "$OUTPUT_DIR"
  fi
}

default_run_token() {
  local safe_serial token
  safe_serial="$(safe_path_component "$serial")"
  token="wifi-$PROOF_MODE-$(date -u +%Y%m%dT%H%M%SZ)-$safe_serial"
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
  python3 - "$probe_json_path" "$run_token" "$reason" "$PROOF_MODE" <<'PY'
import json
import sys

output, run_token, reason, proof_mode = sys.argv[1:5]
payload = {
    "schemaVersion": 1,
    "kind": f"wifi-{proof_mode}-probe",
    "mode": "wifi-linux-surface-probe",
    "proofMode": proof_mode,
    "runToken": run_token,
    "surfaceReady": False,
    "blockerStage": "host-wrapper",
    "blocker": reason,
}
with open(output, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

evaluate_scan_proof() {
  python3 - "$probe_json_path" "$PROOF_MODE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)
proof_mode = sys.argv[2]
supplicant = payload.get("supplicantProbe") or {}
scan_results = supplicant.get("scanResults") or {}
association = supplicant.get("association") or {}
ip = supplicant.get("ip") or {}
activation = payload.get("activationProbe") or {}
scan_ok = (
    payload.get("surfaceReady") is True
    and activation.get("success") is True
    and supplicant.get("socketReady") is True
    and (supplicant.get("ping") or {}).get("ok") is True
    and (supplicant.get("scan") or {}).get("ok") is True
    and scan_results.get("ok") is True
    and int(scan_results.get("bssCount") or 0) > 0
)
if proof_mode == "surface":
    ok = payload.get("surfaceReady") is True and payload.get("blocker", "") == ""
elif proof_mode == "association":
    ok = scan_ok and association.get("completed") is True
elif proof_mode == "ip":
    ok = scan_ok and ip.get("completed") is True
else:
    ok = scan_ok
print("true" if ok else "false")
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
    "$PROOF_MODE" \
    "$WIFI_HELPER_PROFILE" \
    "$WIFI_ASSETS_DIR" \
    "$WIFI_LINKER_CAPSULE_DIR" \
    "$assets_output_path" \
    "$capsule_output_path" \
    "$failure_stage" \
    "$assets_collected" \
    "$capsule_collected" \
    "$build_succeeded" \
    "$oneshot_attempted" \
    "$oneshot_status" \
    "$probe_summary_present" \
    "$scan_proof_ok" <<'PY'
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
    proof_mode,
    wifi_helper_profile,
    wifi_assets_dir,
    wifi_linker_capsule_dir,
    assets_output_path,
    capsule_output_path,
    failure_stage,
    assets_collected,
    capsule_collected,
    build_succeeded,
    oneshot_attempted,
    oneshot_status,
    probe_summary_present,
    scan_proof_ok,
) = sys.argv[1:29]

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
    "kind": "wifi_boot_probe_run",
    "ok": ok == "true",
    "proof_ok": scan_proof_ok == "true",
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
    "wifi_probe_json": probe_json_path,
    "device_output_path": device_output_path,
    "dmesg_path": dmesg_path,
    "proof_mode": proof_mode,
    "wifi_helper_profile": wifi_helper_profile,
    "wifi_assets_dir": wifi_assets_dir,
    "wifi_linker_capsule_dir": wifi_linker_capsule_dir,
    "assets_output_path": assets_output_path,
    "capsule_output_path": capsule_output_path,
    "failure_stage": failure_stage,
    "assets_collected": assets_collected == "true",
    "capsule_collected": capsule_collected == "true",
    "build_succeeded": build_succeeded == "true",
    "oneshot_attempted": oneshot_attempted == "true",
    "probe_summary_present": probe_summary_present == "true",
    "scan_proof_ok": scan_proof_ok == "true",
    "blocker_stage": probe.get("blockerStage", ""),
    "blocker": probe.get("blocker", ""),
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
  cleanup_wifi_credentials_best_effort
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
    --proof-mode)
      PROOF_MODE="${2:?missing value for --proof-mode}"
      shift 2
      ;;
    --wifi-helper-profile)
      WIFI_HELPER_PROFILE="${2:?missing value for --wifi-helper-profile}"
      shift 2
      ;;
    --wifi-credentials)
      WIFI_CREDENTIALS_FILE="${2:?missing value for --wifi-credentials}"
      shift 2
      ;;
    --wifi-dhcp-client)
      WIFI_DHCP_CLIENT_BINARY="${2:?missing value for --wifi-dhcp-client}"
      shift 2
      ;;
    --wifi-assets)
      WIFI_ASSETS_DIR="${2:?missing value for --wifi-assets}"
      WIFI_ASSETS_MODE="provided"
      shift 2
      ;;
    --wifi-linker-capsule)
      WIFI_LINKER_CAPSULE_DIR="${2:?missing value for --wifi-linker-capsule}"
      WIFI_LINKER_CAPSULE_MODE="provided"
      shift 2
      ;;
    --no-wifi-linker-capsule)
      WIFI_LINKER_CAPSULE_MODE="none"
      WIFI_LINKER_CAPSULE_DIR=""
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
      echo "pixel_boot_wifi_probe: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

validate_int adb-timeout "$ADB_TIMEOUT_SECS"
validate_int boot-timeout "$BOOT_TIMEOUT_SECS"
validate_int hold-secs "$HOLD_SECS"
validate_int watchdog-timeout "$WATCHDOG_TIMEOUT_SECS"
case "$PROOF_MODE" in
  surface|scan|association|ip) ;;
  *)
    echo "pixel_boot_wifi_probe: proof mode must be surface, scan, association, or ip: $PROOF_MODE" >&2
    exit 1
    ;;
esac
if [[ ("$PROOF_MODE" == "association" || "$PROOF_MODE" == "ip") && "$DRY_RUN" != "1" ]]; then
  if [[ -z "$WIFI_CREDENTIALS_FILE" || ! -r "$WIFI_CREDENTIALS_FILE" ]]; then
    echo "pixel_boot_wifi_probe: $PROOF_MODE proof requires --wifi-credentials FILE" >&2
    exit 1
  fi
fi
if [[ "$PROOF_MODE" == "ip" ]]; then
  WIFI_DHCP_CLIENT_BINARY="$(find_wifi_dhcp_client)"
  if [[ -z "$WIFI_DHCP_CLIENT_BINARY" ]] || ! validate_wifi_dhcp_client "$WIFI_DHCP_CLIENT_BINARY"; then
    echo "pixel_boot_wifi_probe: ip proof requires --wifi-dhcp-client with an executable static aarch64 busybox" >&2
    exit 1
  fi
fi
case "$WIFI_HELPER_PROFILE" in
  full|no-service-managers|no-pm|no-modem-svc|no-rfs-storage|no-pd-mapper|no-cnss|qrtr-only|qrtr-pd|qrtr-pd-tftp|qrtr-pd-rfs|qrtr-pd-rfs-cnss|qrtr-pd-rfs-modem|qrtr-pd-rfs-modem-cnss|qrtr-pd-rfs-modem-pm|qrtr-pd-rfs-modem-pm-cnss|aidl-sm-core|vnd-sm-core|vnd-sm-core-binder-node|all-sm-core|none) ;;
  *)
    echo "pixel_boot_wifi_probe: wifi helper profile is not recognized: $WIFI_HELPER_PROFILE" >&2
    exit 1
    ;;
esac

serial="$(resolve_serial_for_mode)"
pixel_prepare_dirs
prepare_output_dir

run_token="${PIXEL_BOOT_WIFI_RUN_TOKEN:-$(default_run_token)}"
wifi_credentials_device_path="/metadata/shadow-wifi-credentials/by-token/$run_token.env"
wifi_credentials_tmp_device_path="$wifi_credentials_device_path.tmp"
wifi_credentials_remote_tmp="/data/local/tmp/shadow-wifi-credentials-$run_token.env"
image_path="$OUTPUT_DIR/orange-gpu.img"
status_path="$OUTPUT_DIR/status.json"
build_output_path="$OUTPUT_DIR/build-output.txt"
oneshot_output_path="$OUTPUT_DIR/oneshot-output.txt"
oneshot_stderr_path="$OUTPUT_DIR/oneshot-stderr.txt"
oneshot_dir="$OUTPUT_DIR/oneshot-$serial"
recover_dir="$oneshot_dir/recover-traces"
probe_json_path="$OUTPUT_DIR/wifi-probe.json"
device_output_path="$OUTPUT_DIR/device-output.txt"
dmesg_path="$OUTPUT_DIR/dmesg.txt"
assets_output_path="$OUTPUT_DIR/wifi-assets-output.txt"
capsule_output_path="$OUTPUT_DIR/wifi-linker-capsule-output.txt"
if [[ "$WIFI_ASSETS_MODE" == "auto" ]]; then
  WIFI_ASSETS_DIR="$OUTPUT_DIR/wifi-assets"
fi
if [[ "$WIFI_LINKER_CAPSULE_MODE" == "auto" ]]; then
  WIFI_LINKER_CAPSULE_DIR="$OUTPUT_DIR/wifi-linker-capsule"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  dry_run_assets_command=disabled
  dry_run_capsule_command=disabled
  dry_run_build_command="$SCRIPT_DIR/pixel/pixel_boot_build_orange_gpu.sh --output \"$image_path\" --orange-gpu-mode wifi-linux-surface-probe --orange-gpu-metadata-stage-breadcrumb true --hold-secs \"$HOLD_SECS\" --orange-gpu-watchdog-timeout-secs \"$WATCHDOG_TIMEOUT_SECS\" --reboot-target bootloader --run-token \"$run_token\" --dev-mount tmpfs --mount-dev true --mount-proc true --mount-sys true --firmware-bootstrap ramdisk-lib-firmware --firmware-dir \"$WIFI_ASSETS_DIR/firmware\" --wifi-bootstrap sunfish-wlan0 --wifi-helper-profile \"$WIFI_HELPER_PROFILE\" --wifi-module-dir \"$WIFI_ASSETS_DIR/modules\""
  dry_run_build_command+=" --orange-gpu-metadata-prune-token-root true"
  if [[ "$PROOF_MODE" == "surface" ]]; then
    dry_run_build_command+=" --wifi-supplicant-probe false"
  fi
  if [[ "$PROOF_MODE" == "association" ]]; then
    dry_run_build_command+=" --wifi-association-probe true --wifi-credentials-path \"$wifi_credentials_device_path\""
  fi
  if [[ "$PROOF_MODE" == "ip" ]]; then
    dry_run_build_command+=" --wifi-ip-probe true --wifi-credentials-path \"$wifi_credentials_device_path\" --wifi-dhcp-client \"$WIFI_DHCP_CLIENT_BINARY\""
  fi
  if [[ "$WIFI_ASSETS_MODE" == "auto" ]]; then
    dry_run_assets_command="$SCRIPT_DIR/pixel/pixel_wifi_collect_boot_assets.sh --output \"$WIFI_ASSETS_DIR\""
  fi
  if [[ "$WIFI_LINKER_CAPSULE_MODE" != "none" ]]; then
    if [[ "$WIFI_LINKER_CAPSULE_MODE" == "auto" ]]; then
      dry_run_capsule_command="$SCRIPT_DIR/pixel/pixel_wifi_collect_capsule.sh --output \"$WIFI_LINKER_CAPSULE_DIR\""
    fi
    dry_run_build_command+=" --wifi-linker-capsule \"$WIFI_LINKER_CAPSULE_DIR\""
  fi
  cat <<EOF
pixel_boot_wifi_probe: dry-run
serial=$serial
output_dir=$OUTPUT_DIR
run_token=$run_token
image=$image_path
adb_timeout_secs=$ADB_TIMEOUT_SECS
boot_timeout_secs=$BOOT_TIMEOUT_SECS
hold_secs=$HOLD_SECS
watchdog_timeout_secs=$WATCHDOG_TIMEOUT_SECS
proof_mode=$PROOF_MODE
wifi_helper_profile=$WIFI_HELPER_PROFILE
wifi_credentials_path_configured=$([[ "$PROOF_MODE" == "association" || "$PROOF_MODE" == "ip" ]] && printf true || printf false)
wifi_dhcp_client=${WIFI_DHCP_CLIENT_BINARY:-}
wifi_assets_mode=$WIFI_ASSETS_MODE
wifi_assets_dir=$WIFI_ASSETS_DIR
wifi_linker_capsule_mode=$WIFI_LINKER_CAPSULE_MODE
wifi_linker_capsule_dir=$WIFI_LINKER_CAPSULE_DIR
assets_command=$dry_run_assets_command
capsule_command=$dry_run_capsule_command
build_command=$dry_run_build_command
run_command=$SCRIPT_DIR/pixel/pixel_boot_oneshot.sh --image "$image_path" --output "$oneshot_dir" --skip-collect --recover-traces-after --no-wait-boot-completed
EOF
  exit 0
fi

trap finish EXIT

if [[ "$WIFI_ASSETS_MODE" == "auto" ]]; then
  if ! PIXEL_SERIAL="$serial" "$SCRIPT_DIR/pixel/pixel_wifi_collect_boot_assets.sh" \
    --output "$WIFI_ASSETS_DIR" \
    --adb-timeout "$ADB_TIMEOUT_SECS" \
    >"$assets_output_path" 2>&1; then
    failure_stage="collect-wifi-assets"
    write_blocker_probe_json "failed to collect Wi-Fi module/firmware assets from rooted Android"
    exit 1
  fi
  assets_collected=true
elif [[ ! -d "$WIFI_ASSETS_DIR/modules" || ! -d "$WIFI_ASSETS_DIR/firmware" ]]; then
  failure_stage="wifi-assets"
  write_blocker_probe_json "Wi-Fi assets directory was not found or is missing modules/firmware"
  exit 1
fi

if [[ "$WIFI_LINKER_CAPSULE_MODE" == "auto" ]]; then
  if ! PIXEL_SERIAL="$serial" "$SCRIPT_DIR/pixel/pixel_wifi_collect_capsule.sh" \
    --output "$WIFI_LINKER_CAPSULE_DIR" \
    --adb-timeout "$ADB_TIMEOUT_SECS" \
    >"$capsule_output_path" 2>&1; then
    failure_stage="collect-wifi-linker-capsule"
    write_blocker_probe_json "failed to collect Wi-Fi linker capsule from rooted Android"
    exit 1
  fi
  capsule_collected=true
elif [[ "$WIFI_LINKER_CAPSULE_MODE" != "none" && ! -d "$WIFI_LINKER_CAPSULE_DIR" ]]; then
  failure_stage="wifi-linker-capsule"
  write_blocker_probe_json "Wi-Fi linker capsule directory was not found"
  exit 1
fi

build_args=(
  "$SCRIPT_DIR/pixel/pixel_boot_build_orange_gpu.sh"
  --output "$image_path"
  --orange-gpu-mode wifi-linux-surface-probe
  --orange-gpu-metadata-stage-breadcrumb true
  --orange-gpu-metadata-prune-token-root true
  --hold-secs "$HOLD_SECS"
  --orange-gpu-watchdog-timeout-secs "$WATCHDOG_TIMEOUT_SECS"
  --reboot-target bootloader
  --run-token "$run_token"
  --dev-mount tmpfs
  --mount-dev true
  --mount-proc true
  --mount-sys true
  --firmware-bootstrap ramdisk-lib-firmware
  --firmware-dir "$WIFI_ASSETS_DIR/firmware"
  --wifi-bootstrap sunfish-wlan0
  --wifi-helper-profile "$WIFI_HELPER_PROFILE"
  --wifi-module-dir "$WIFI_ASSETS_DIR/modules"
)
if [[ "$PROOF_MODE" == "surface" ]]; then
  build_args+=(--wifi-supplicant-probe false)
fi
if [[ "$PROOF_MODE" == "association" ]]; then
  build_args+=(
    --wifi-association-probe true
    --wifi-credentials-path "$wifi_credentials_device_path"
  )
fi
if [[ "$PROOF_MODE" == "ip" ]]; then
  build_args+=(
    --wifi-ip-probe true
    --wifi-credentials-path "$wifi_credentials_device_path"
    --wifi-dhcp-client "$WIFI_DHCP_CLIENT_BINARY"
  )
fi
if [[ "$WIFI_LINKER_CAPSULE_MODE" != "none" ]]; then
  build_args+=(--wifi-linker-capsule "$WIFI_LINKER_CAPSULE_DIR")
fi

if ! "${build_args[@]}" >"$build_output_path" 2>&1; then
  failure_stage="build"
  write_blocker_probe_json "failed to build Wi-Fi boot probe image"
  exit 1
fi
build_succeeded=true

if [[ "$PROOF_MODE" == "association" || "$PROOF_MODE" == "ip" ]]; then
  if ! stage_wifi_credentials; then
    failure_stage="stage-wifi-credentials"
    write_blocker_probe_json "failed to stage Wi-Fi credentials into metadata"
    exit 1
  fi
fi

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

if [[ "$probe_summary_present" == "true" ]]; then
  scan_proof_ok="$(evaluate_scan_proof)"
fi

if [[ "$scan_proof_ok" == "true" ]]; then
  printf 'Recovered Wi-Fi boot %s proof: %s\n' "$PROOF_MODE" "$probe_json_path"
  printf 'Run status: %s\n' "$status_path"
  exit 0
fi

printf 'Wi-Fi boot probe did not prove scan readiness; see %s\n' "$status_path" >&2
exit 1
