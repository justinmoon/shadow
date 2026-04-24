#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_DIR=""
DRY_RUN=0
ADB_TIMEOUT_SECS="${PIXEL_WIFI_LINKER_CAPSULE_ADB_TIMEOUT_SECS:-120}"

serial=""
readelf_cmd=""
declare -a queue=()
declare -A queued=()
declare -A pulled=()
declare -A missing=()
declare -A required=()
declare -A device_library_paths=()

search_roots=(
  /vendor/lib64
  /vendor/lib64/hw
  /system/lib64
  /system_ext/lib64
  /product/lib64
  /odm/lib64
  /apex/com.android.vndk.v33/lib64
  /apex/com.android.runtime/lib64/bionic
  /apex/com.android.runtime/lib64
)

# The collector starts broad so alternate research profiles can be built from
# one capsule. The required set below is the proven vnd-sm-core-binder-node
# runtime seam used by the default Wi-Fi scan probe.
initial_files=(
  /apex/com.android.runtime/bin/linker64
  /apex/com.android.runtime/lib64/bionic/libc.so
  /apex/com.android.runtime/lib64/bionic/libdl.so
  /apex/com.android.runtime/lib64/bionic/libdl_android.so
  /apex/com.android.runtime/lib64/bionic/libm.so
  /apex/com.android.vndk.v33/lib64/android.hardware.security.secureclock-V1-ndk.so
  /apex/com.android.vndk.v33/lib64/android.hardware.wifi.supplicant-V1-ndk.so
  /apex/com.android.vndk.v33/lib64/android.hidl.safe_union@1.0.so
  /apex/com.android.vndk.v33/lib64/android.hidl.token@1.0.so
  /apex/com.android.vndk.v33/lib64/libbase.so
  /apex/com.android.vndk.v33/lib64/libc++.so
  /apex/com.android.vndk.v33/lib64/libcrypto.so
  /apex/com.android.vndk.v33/lib64/libcutils.so
  /apex/com.android.vndk.v33/lib64/libnl.so
  /apex/com.android.vndk.v33/lib64/libssl.so
  /apex/com.android.vndk.v33/lib64/libutils.so
  /linkerconfig/ld.config.txt
  /product/etc/selinux/product_hwservice_contexts
  /product/etc/selinux/product_service_contexts
  /system/bin/hwservicemanager
  /system/bin/linker64
  /system/bin/servicemanager
  /system/bin/toybox
  /system/etc/selinux/plat_hwservice_contexts
  /system/etc/selinux/plat_service_contexts
  /system/lib64/android.hardware.security.keymint-V1-ndk.so
  /system/lib64/android.hardware.security.secureclock-V1-ndk.so
  /system/lib64/android.hidl.safe_union@1.0.so
  /system/lib64/android.hidl.token@1.0.so
  /system/lib64/android.system.keystore2-V1-ndk.so
  /system/lib64/android.system.wifi.keystore@1.0.so
  /system/lib64/libandroid_runtime_lazy.so
  /system/lib64/libbase.so
  /system/lib64/libbinder.so
  /system/lib64/libbinder_ndk.so
  /system/lib64/libc++.so
  /system/lib64/libcrypto.so
  /system/lib64/libcutils.so
  /system/lib64/libhidlbase.so
  /system/lib64/libjson.so
  /system/lib64/liblog.so
  /system/lib64/liblzma.so
  /system/lib64/libnetutils.so
  /system/lib64/libprocessgroup.so
  /system/lib64/libssl.so
  /system/lib64/libunwindstack.so
  /system/lib64/libutils.so
  /system/lib64/libvndksupport.so
  /system/lib64/libz.so
  /system_ext/etc/selinux/system_ext_hwservice_contexts
  /system_ext/etc/selinux/system_ext_service_contexts
  /vendor/bin/cnss-daemon
  /vendor/bin/hw/wpa_supplicant
  /vendor/bin/hwservicemanager
  /vendor/bin/irsc_util
  /vendor/bin/modem_svc
  /vendor/bin/pd-mapper
  /vendor/bin/pm-proxy
  /vendor/bin/pm-service
  /vendor/bin/qrtr-ns
  /vendor/bin/qseecomd
  /vendor/bin/rmt_storage
  /vendor/bin/servicemanager
  /vendor/bin/tftp_server
  /vendor/bin/vndservicemanager
  /vendor/etc/sec_config
  /vendor/etc/selinux/precompiled_sepolicy
  /vendor/etc/selinux/vendor_hwservice_contexts
  /vendor/etc/selinux/vendor_service_contexts
  /vendor/etc/selinux/vndservice_contexts
  /vendor/etc/wifi/p2p_supplicant_overlay.conf
  /vendor/etc/wifi/wifi_concurrency_cfg.txt
  /vendor/etc/wifi/wpa_supplicant.conf
  /vendor/etc/wifi/wpa_supplicant_overlay.conf
  /vendor/firmware/adspr.jsn
  /vendor/firmware/adsps.jsn
  /vendor/firmware/adspua.jsn
  /vendor/firmware/bdwlan-sunfish-EVT1.0.bin
  /vendor/firmware/bdwlan-sunfish.bin
  /vendor/firmware/cdspr.jsn
  /vendor/firmware/modemuw.jsn
  /vendor/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini
  /vendor/firmware/wlanmdsp.mbn
  /vendor/firmware_mnt/image/modemr.jsn
  /vendor/lib64/android.hardware.security.keymint-V1-ndk.so
  /vendor/lib64/android.system.keystore2-V1-ndk.so
  /vendor/lib64/android.system.wifi.keystore@1.0.so
  /vendor/lib64/hardware.google.bluetooth.bt_channel_avoidance@1.0.so
  /vendor/lib64/libQSEEComAPI.so
  /vendor/lib64/libcld80211.so
  /vendor/lib64/libdiag.so
  /vendor/lib64/libdsutils.so
  /vendor/lib64/libidl.so
  /vendor/lib64/libjson.so
  /vendor/lib64/libkeystore-engine-wifi-hidl.so
  /vendor/lib64/libkeystore-wifi-hidl.so
  /vendor/lib64/libmdmdetect.so
  /vendor/lib64/libnl.so
  /vendor/lib64/libperipheral_client.so
  /vendor/lib64/libqmi.so
  /vendor/lib64/libqmi_cci.so
  /vendor/lib64/libqmi_client_qmux.so
  /vendor/lib64/libqmi_common_so.so
  /vendor/lib64/libqmi_csi.so
  /vendor/lib64/libqmi_encdec.so
  /vendor/lib64/libqmi_modem_svc.so
  /vendor/lib64/libqmi_vs-google-1.so
  /vendor/lib64/libqmiservices.so
  /vendor/lib64/libqrtr.so
  /vendor/lib64/libqsocket.so
  /vendor/lib64/vendor.google.radioext@1.0.so
  /vendor/lib64/vendor.google.radioext@1.1.so
  /vendor/lib64/vendor.google.radioext@1.2.so
  /vendor/lib64/vendor.google.radioext@1.3.so
  /vendor/rfs/msm/mpss/readonly/vendor/firmware/bdwlan-sunfish-EVT1.0.bin
  /vendor/rfs/msm/mpss/readonly/vendor/firmware/bdwlan-sunfish.bin
  /vendor/rfs/msm/mpss/readonly/vendor/firmware/wlanmdsp.mbn
)

required_files=(
  /apex/com.android.runtime/bin/linker64
  /linkerconfig/ld.config.txt
  /system/bin/toybox
  /vendor/bin/cnss-daemon
  /vendor/bin/modem_svc
  /vendor/bin/pd-mapper
  /vendor/bin/pm-proxy
  /vendor/bin/pm-service
  /vendor/bin/qrtr-ns
  /vendor/bin/rmt_storage
  /vendor/bin/tftp_server
  /vendor/bin/vndservicemanager
  /vendor/bin/hw/wpa_supplicant
  /vendor/etc/wifi/wpa_supplicant.conf
)

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_wifi_collect_capsule.sh [--output DIR]
                                                   [--adb-timeout SECONDS]
                                                   [--dry-run]

Collect the rooted-Android vendor/system/APEX linker capsule used by the
boot-owned sunfish Wi-Fi probe. The output directory mirrors absolute device
paths so it can be staged into a boot ramdisk.
EOF
}

safe_path_component() {
  tr -c 'A-Za-z0-9._-' '_' <<<"$1" | sed 's/_$//'
}

resolve_serial_for_mode() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '%s\n' "${PIXEL_SERIAL:-dry-run}"
    return 0
  fi

  pixel_resolve_serial
}

find_readelf() {
  if command -v llvm-readelf >/dev/null 2>&1; then
    printf 'llvm-readelf\n'
    return 0
  fi
  if command -v readelf >/dev/null 2>&1; then
    printf 'readelf\n'
    return 0
  fi

  echo "pixel_wifi_collect_capsule: llvm-readelf or readelf is required" >&2
  exit 1
}

device_shell_quote() {
  local value
  value="${1:?device_shell_quote requires a value}"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

adb_shell_root() {
  local command_text
  command_text="${1:?adb_shell_root requires a command}"
  pixel_root_shell_timeout "$ADB_TIMEOUT_SECS" "$serial" "$command_text"
}

host_path_for_device_path() {
  local device_path
  device_path="${1:?host_path_for_device_path requires a device path}"
  printf '%s/%s\n' "$OUTPUT_DIR" "${device_path#/}"
}

queue_file() {
  local device_path
  device_path="$1"
  [[ -n "$device_path" ]] || return 0
  [[ "$device_path" == /* ]] || {
    echo "pixel_wifi_collect_capsule: refusing non-absolute device path: $device_path" >&2
    exit 1
  }
  if [[ -z "${queued[$device_path]:-}" ]]; then
    queued[$device_path]=1
    queue+=("$device_path")
  fi
}

pull_file() {
  local device_path host_path tmp_path
  device_path="$1"
  host_path="$(host_path_for_device_path "$device_path")"

  if [[ -n "${pulled[$device_path]:-}" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$host_path")"
  tmp_path="$host_path.tmp"
  rm -f "$tmp_path"
  if timeout "$ADB_TIMEOUT_SECS" adb -s "$serial" pull "$device_path" "$tmp_path" >/dev/null 2>&1; then
    mv "$tmp_path" "$host_path"
  elif adb_shell_root "cat $(device_shell_quote "$device_path")" >"$tmp_path"; then
    mv "$tmp_path" "$host_path"
  else
    rm -f "$tmp_path"
    missing[$device_path]=pull-failed
    return 1
  fi

  case "$device_path" in
    */bin/*|*/bin|*/linker64)
      chmod 0755 "$host_path" 2>/dev/null || true
      ;;
    *)
      chmod 0644 "$host_path" 2>/dev/null || true
      ;;
  esac
  pulled[$device_path]=1
}

read_needed_sonames() {
  local host_path
  host_path="$1"
  "$readelf_cmd" -dW "$host_path" 2>/dev/null |
    sed -n 's/^.*Shared library: \[\(.*\)\]$/\1/p'
}

find_device_library() {
  local soname
  soname="$1"

  if [[ -n "${device_library_paths[$soname]:-}" ]]; then
    printf '%s\n' "${device_library_paths[$soname]}"
    return 0
  fi

  return 1
}

index_device_libraries() {
  local device_path find_command root soname
  find_command=":"
  for root in "${search_roots[@]}"; do
    find_command+="; find $(device_shell_quote "$root") -maxdepth 1 -type f -print 2>/dev/null"
  done

  while IFS= read -r device_path; do
    device_path="${device_path//$'\r'/}"
    [[ "$device_path" == /* ]] || continue
    soname="${device_path##*/}"
    if [[ -z "${device_library_paths[$soname]:-}" ]]; then
      device_library_paths[$soname]="$device_path"
    fi
  done < <(adb_shell_root "$find_command")
}

write_manifest() {
  local manifest_path
  manifest_path="$OUTPUT_DIR/capsule-manifest.json"
  python3 - "$manifest_path" "$serial" "${!pulled[@]}" -- "${!missing[@]}" <<'PY'
import json
import sys

manifest_path, serial = sys.argv[1:3]
separator = sys.argv.index("--")
pulled = sorted(sys.argv[3:separator])
missing = sorted(sys.argv[separator + 1 :])
payload = {
    "kind": "wifi_linker_capsule",
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
      echo "pixel_wifi_collect_capsule: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! "$ADB_TIMEOUT_SECS" =~ ^[0-9]+$ ]]; then
  echo "pixel_wifi_collect_capsule: adb timeout must be an integer: $ADB_TIMEOUT_SECS" >&2
  exit 1
fi

serial="$(resolve_serial_for_mode)"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(pixel_dir)/wifi-linker-capsule/$(pixel_timestamp)-$(safe_path_component "$serial")"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  cat <<EOF
pixel_wifi_collect_capsule: dry-run
serial=$serial
output_dir=$OUTPUT_DIR
adb_timeout_secs=$ADB_TIMEOUT_SECS
initial_files=${initial_files[*]}
search_roots=${search_roots[*]}
EOF
  exit 0
fi

if [[ -e "$OUTPUT_DIR" ]] && find "$OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
  echo "pixel_wifi_collect_capsule: output dir must be empty or absent: $OUTPUT_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
readelf_cmd="$(find_readelf)"
for device_path in "${required_files[@]}"; do
  required[$device_path]=1
done
index_device_libraries

for device_path in "${initial_files[@]}"; do
  queue_file "$device_path"
done

while ((${#queue[@]})); do
  device_path="${queue[0]}"
  queue=("${queue[@]:1}")

  if ! pull_file "$device_path"; then
    continue
  fi

  host_path="$(host_path_for_device_path "$device_path")"
  while IFS= read -r soname; do
    [[ -n "$soname" ]] || continue
    if dependency_path="$(find_device_library "$soname")"; then
      queue_file "$dependency_path"
    else
      missing[$soname]=not-found
    fi
  done < <(read_needed_sonames "$host_path")
done

write_manifest
for device_path in "${required_files[@]}"; do
  if [[ -n "${missing[$device_path]:-}" ]]; then
    echo "pixel_wifi_collect_capsule: missing required file: $device_path (${missing[$device_path]})" >&2
    exit 1
  fi
done

printf 'Wi-Fi linker capsule: %s\n' "$OUTPUT_DIR"
