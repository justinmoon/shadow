#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_DIR=""
DRY_RUN=0
ADB_TIMEOUT_SECS="${PIXEL_WIFI_BOOT_ASSETS_ADB_TIMEOUT_SECS:-120}"

serial=""
declare -A pulled=()
declare -A missing=()

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_wifi_collect_boot_assets.sh [--output DIR]
                                                       [--adb-timeout SECONDS]
                                                       [--dry-run]

Collect the rooted-Android Wi-Fi module and firmware assets needed by the
boot-owned sunfish wlan0 probe. The output directory contains `modules/` and
`firmware/` subtrees suitable for pixel_boot_build_orange_gpu.sh
`--wifi-module-dir` and `--firmware-dir`.
EOF
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

device_shell_quote() {
  local value
  value="${1:?device_shell_quote requires a value}"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

adb_shell_root() {
  local command_text
  command_text="${1:?adb_shell_root requires a command}"
  timeout "$ADB_TIMEOUT_SECS" adb -s "$serial" shell \
    "/debug_ramdisk/su 0 sh -c $(device_shell_quote "$command_text")" </dev/null
}

pull_file_to() {
  local device_path host_path tmp_path
  device_path="${1:?pull_file_to requires a device path}"
  host_path="${2:?pull_file_to requires a host path}"

  mkdir -p "$(dirname "$host_path")"
  tmp_path="$host_path.tmp"
  rm -f "$tmp_path"
  if timeout "$ADB_TIMEOUT_SECS" adb -s "$serial" pull "$device_path" "$tmp_path" >/dev/null 2>&1; then
    mv "$tmp_path" "$host_path"
  elif timeout "$ADB_TIMEOUT_SECS" adb -s "$serial" shell \
      "/debug_ramdisk/su 0 sh -c $(device_shell_quote "cat $(device_shell_quote "$device_path")")" \
      >"$tmp_path" </dev/null; then
    mv "$tmp_path" "$host_path"
  else
    rm -f "$tmp_path"
    missing[$device_path]=pull-failed
    return 1
  fi

  chmod 0644 "$host_path" 2>/dev/null || true
  pulled[$device_path]=1
}

pull_required() {
  local device_path relative_path
  device_path="${1:?pull_required requires a device path}"
  relative_path="${2:?pull_required requires a relative path}"
  if ! pull_file_to "$device_path" "$OUTPUT_DIR/$relative_path"; then
    echo "pixel_wifi_collect_boot_assets: failed to pull required file: $device_path" >&2
    return 1
  fi
}

pull_optional() {
  local device_path relative_path
  device_path="${1:?pull_optional requires a device path}"
  relative_path="${2:?pull_optional requires a relative path}"
  pull_file_to "$device_path" "$OUTPUT_DIR/$relative_path" >/dev/null 2>&1 || true
}

find_wlan_module() {
  adb_shell_root '
for path in /vendor/lib/modules/wlan.ko /vendor_dlkm/lib/modules/wlan.ko; do
  if [ -f "$path" ]; then
    echo "$path"
    exit 0
  fi
done
find /vendor /vendor_dlkm -name wlan.ko -type f 2>/dev/null | head -n 1
' | tr -d '\r' | sed -n '1p'
}

write_manifest() {
  local manifest_path
  manifest_path="$OUTPUT_DIR/wifi-assets-manifest.json"
  python3 - "$manifest_path" "$serial" "${!pulled[@]}" -- "${!missing[@]}" <<'PY'
import json
import sys

manifest_path, serial = sys.argv[1:3]
separator = sys.argv.index("--")
pulled = sorted(sys.argv[3:separator])
missing = sorted(sys.argv[separator + 1 :])
payload = {
    "kind": "wifi_boot_assets",
    "serial": serial,
    "pulled": pulled,
    "missing": missing,
}
with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
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
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "pixel_wifi_collect_boot_assets: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! "$ADB_TIMEOUT_SECS" =~ ^[0-9]+$ ]]; then
  echo "pixel_wifi_collect_boot_assets: adb timeout must be an integer: $ADB_TIMEOUT_SECS" >&2
  exit 1
fi

serial="$(resolve_serial_for_mode)"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(pixel_dir)/wifi-boot-assets/$(pixel_timestamp)-$(safe_path_component "$serial")"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  cat <<EOF
pixel_wifi_collect_boot_assets: dry-run
serial=$serial
output_dir=$OUTPUT_DIR
adb_timeout_secs=$ADB_TIMEOUT_SECS
EOF
  exit 0
fi

if [[ -e "$OUTPUT_DIR" ]] && find "$OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
  echo "pixel_wifi_collect_boot_assets: output dir must be empty or absent: $OUTPUT_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

wlan_module="$(find_wlan_module)"
if [[ -z "$wlan_module" ]]; then
  echo "pixel_wifi_collect_boot_assets: unable to locate wlan.ko on $serial" >&2
  exit 1
fi

pull_required "$wlan_module" "modules/wlan.ko"
pull_required "/vendor/firmware/bdwlan-sunfish-EVT1.0.bin" "firmware/bdwlan-sunfish-EVT1.0.bin"
pull_required "/vendor/firmware/bdwlan-sunfish.bin" "firmware/bdwlan-sunfish.bin"
pull_required "/vendor/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini" "firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini"
pull_required "/vendor/firmware/wlanmdsp.mbn" "firmware/wlanmdsp.mbn"

for file in /vendor/firmware/ipa_fws.b00 \
  /vendor/firmware/ipa_fws.b01 \
  /vendor/firmware/ipa_fws.b02 \
  /vendor/firmware/ipa_fws.b03 \
  /vendor/firmware/ipa_fws.b04 \
  /vendor/firmware/ipa_fws.elf \
  /vendor/firmware/ipa_fws.mdt; do
  pull_optional "$file" "firmware/${file##*/}"
done

write_manifest
printf 'Wi-Fi boot assets: %s\n' "$OUTPUT_DIR"
