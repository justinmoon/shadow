#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

"$SCRIPT_DIR/pixel_root_prep.sh"

serial="$(pixel_resolve_serial)"
pixel_require_expected_fingerprint "$serial" "pixel-root-patch"

apk_path="$(pixel_root_magisk_apk)"
boot_img="$(pixel_root_stock_boot_img)"
assets_dir="$(pixel_root_magisk_patch_assets_dir)"
device_patch_dir="$(pixel_root_device_patch_dir)"
patched_remote="$(pixel_root_device_patched_boot_img)"
patched_local="$(pixel_root_patched_boot_img)"
patch_log="$(pixel_root_patch_log)"

rm -rf "$assets_dir"
mkdir -p "$assets_dir"

unzip -p "$apk_path" assets/boot_patch.sh >"$assets_dir/boot_patch.sh"
unzip -p "$apk_path" assets/util_functions.sh >"$assets_dir/util_functions.sh"
unzip -p "$apk_path" assets/stub.apk >"$assets_dir/stub.apk"
unzip -p "$apk_path" lib/arm64-v8a/libmagisk.so >"$assets_dir/magisk"
unzip -p "$apk_path" lib/arm64-v8a/libmagiskboot.so >"$assets_dir/magiskboot"
unzip -p "$apk_path" lib/arm64-v8a/libmagiskinit.so >"$assets_dir/magiskinit"
unzip -p "$apk_path" lib/arm64-v8a/libbusybox.so >"$assets_dir/busybox"
unzip -p "$apk_path" lib/arm64-v8a/libinit-ld.so >"$assets_dir/init-ld"
chmod 0755 "$assets_dir"/*

printf 'Preparing Magisk patch workspace on %s\n' "$serial"
pixel_adb "$serial" shell "rm -rf $device_patch_dir && mkdir -p $device_patch_dir" >/dev/null
pixel_adb "$serial" push "$assets_dir/." "$device_patch_dir/" >/dev/null
pixel_adb "$serial" push "$boot_img" "$device_patch_dir/boot.img" >/dev/null

set +e
patch_output="$(
  pixel_adb "$serial" shell \
    "cd $device_patch_dir && chmod 755 * && ./boot_patch.sh boot.img" \
    2>&1
)"
patch_status="$?"
set -e

printf '%s\n' "$patch_output" | tee "$patch_log"

if [[ "$patch_status" -ne 0 ]]; then
  echo "pixel-root-patch: Magisk patch command failed" >&2
  exit 1
fi

pixel_adb "$serial" shell "[ -f $patched_remote ]"
pixel_adb "$serial" pull "$patched_remote" "$patched_local" >/dev/null
printf '%s\n' "$(file "$patched_local")"
printf 'Patched boot image ready: %s\n' "$patched_local"
