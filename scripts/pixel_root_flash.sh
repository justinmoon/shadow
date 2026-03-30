#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
patched_glob="$(pixel_root_device_patched_glob)"
patched_local="$(pixel_root_patched_boot_img)"
slot_suffix="$(pixel_prop "$serial" ro.boot.slot_suffix)"
boot_partition="$(pixel_boot_partition_for_slot "$slot_suffix")"

pixel_require_expected_fingerprint "$serial" "pixel-root-flash"

if [[ ! -f "$patched_local" ]]; then
  patched_remote="$(
    pixel_adb "$serial" shell "ls -t $patched_glob 2>/dev/null | head -n 1" | tr -d '\r'
  )"

  if [[ -z "$patched_remote" ]]; then
    echo "pixel-root-flash: no patched boot image is available locally or on the device" >&2
    echo "Run 'just pixel-root-patch' for the automated path, or 'just pixel-root-stage' for the manual Magisk-app fallback." >&2
    exit 1
  fi

  printf 'Pulling patched image %s -> %s\n' "$patched_remote" "$patched_local"
  pixel_adb "$serial" pull "$patched_remote" "$patched_local" >/dev/null
fi

printf '%s\n' "$(file "$patched_local")"

printf 'Rebooting to bootloader\n'
pixel_adb "$serial" reboot bootloader
pixel_wait_for_fastboot "$serial" 60

printf 'Flashing patched boot image to %s\n' "$boot_partition"
pixel_fastboot "$serial" flash "$boot_partition" "$patched_local"

printf 'Rebooting Android\n'
pixel_fastboot "$serial" reboot
pixel_wait_for_adb "$serial" 180
pixel_wait_for_boot_completed "$serial" 240

if [[ -f "$(pixel_root_magisk_apk)" ]]; then
  printf 'Installing Magisk app\n'
  pixel_adb "$serial" install -r "$(pixel_root_magisk_apk)" >/dev/null 2>&1 || true
fi

printf 'Android is back. Checking root state.\n'
"$SCRIPT_DIR/pixel_root_check.sh"
