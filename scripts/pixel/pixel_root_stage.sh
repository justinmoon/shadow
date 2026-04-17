#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

"$SCRIPT_DIR/pixel/pixel_root_prep.sh"

serial="$(pixel_resolve_serial)"
boot_img="$(pixel_root_stock_boot_img)"
magisk_apk="$(pixel_root_magisk_apk)"
device_boot_img="$(pixel_root_device_boot_img)"
pixel_require_expected_fingerprint "$serial" "pixel-root-stage"

printf 'Installing Magisk APK on %s\n' "$serial"
pixel_adb "$serial" install -r "$magisk_apk" >/dev/null

pixel_adb "$serial" shell "mkdir -p $(dirname "$device_boot_img")" >/dev/null 2>&1 || true

printf 'Pushing stock boot image to %s\n' "$device_boot_img"
pixel_adb "$serial" push "$boot_img" "$device_boot_img" >/dev/null

pixel_adb "$serial" shell monkey -p com.topjohnwu.magisk 1 >/dev/null 2>&1 || true

cat <<EOF
Magisk has been installed and the exact stock boot image is on the phone:
  $device_boot_img

On the phone in the Magisk app:
1. Tap Install.
2. Tap Select and Patch a File.
3. Choose Downloads -> $(basename "$device_boot_img").
4. Wait for Magisk to finish patching.

Then run:
  sc -t pixel root-flash
EOF
