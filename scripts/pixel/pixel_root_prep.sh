#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs

ota_url="$(pixel_root_ota_url)"
ota_zip="$(pixel_root_ota_zip)"
payload_bin="$(pixel_root_payload_bin)"
extract_dir="$(pixel_root_payload_extract_dir)"
boot_img="$(pixel_root_stock_boot_img)"
magisk_apk="$(pixel_root_magisk_apk)"
magisk_info="$(pixel_root_magisk_info_json)"

mkdir -p "$(pixel_root_dir)" "$extract_dir"

if [[ ! -f "$ota_zip" ]]; then
  printf 'Downloading official Pixel 4a full OTA -> %s\n' "$ota_zip"
  pixel_download_file "$ota_url" "$ota_zip"
else
  printf 'Using cached OTA %s\n' "$ota_zip"
fi

if [[ ! -f "$payload_bin" ]]; then
  printf 'Extracting payload.bin -> %s\n' "$payload_bin"
  unzip -p "$ota_zip" payload.bin >"$payload_bin"
else
  printf 'Using cached payload %s\n' "$payload_bin"
fi

if [[ ! -f "$boot_img" ]]; then
  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  printf 'Extracting boot.img from payload.bin\n'
  payload-dumper-go -o "$extract_dir" -p boot "$payload_bin"
  cp "$extract_dir/boot.img" "$boot_img"
else
  printf 'Using cached boot image %s\n' "$boot_img"
fi

printf '%s\n' "$(file "$boot_img")"

printf 'Fetching latest Magisk release metadata\n'
curl -L --fail -s https://api.github.com/repos/topjohnwu/Magisk/releases/latest >"$magisk_info.tmp"
mv "$magisk_info.tmp" "$magisk_info"

magisk_url="$(
  python3 -c 'import json,sys; obj=json.load(open(sys.argv[1], "r", encoding="utf-8")); print(next(a["browser_download_url"] for a in obj["assets"] if a["name"].startswith("Magisk-v") and a["name"].endswith(".apk")))' \
    "$magisk_info"
)"

if [[ ! -f "$magisk_apk" ]]; then
  printf 'Downloading Magisk APK -> %s\n' "$magisk_apk"
  pixel_download_file "$magisk_url" "$magisk_apk"
else
  printf 'Using cached Magisk APK %s\n' "$magisk_apk"
fi

printf 'Prepared OTA: %s\n' "$ota_zip"
printf 'Prepared boot image: %s\n' "$boot_img"
printf 'Prepared Magisk APK: %s\n' "$magisk_apk"
