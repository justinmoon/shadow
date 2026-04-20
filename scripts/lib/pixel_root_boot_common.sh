#!/usr/bin/env bash

pixel_root_ota_url() {
  printf '%s\n' "${PIXEL_ROOT_OTA_URL:-https://ota.googlezip.net/packages/ota-api/package/c4e85817eb7653336a8fe2de681618a9e004b1fb.zip}"
}

pixel_root_ota_zip() {
  printf '%s/%s\n' "$(pixel_root_dir)" "${PIXEL_ROOT_OTA_FILENAME:-sunfish-TQ3A.230805.001.S2-full-ota.zip}"
}

pixel_root_payload_bin() {
  printf '%s/payload.bin\n' "$(pixel_root_dir)"
}

pixel_root_payload_extract_dir() {
  printf '%s/payload-extracted\n' "$(pixel_root_dir)"
}

pixel_root_stock_boot_img() {
  printf '%s\n' "${PIXEL_ROOT_STOCK_BOOT_IMG:-$(pixel_root_dir)/boot.img}"
}

pixel_shared_stock_boot_img() {
  printf '%s\n' "${PIXEL_SHARED_STOCK_BOOT_IMG:-$(pixel_shared_root_dir)/boot.img}"
}

pixel_resolve_stock_boot_img() {
  local candidate
  for candidate in \
    "$(pixel_root_stock_boot_img)" \
    "$(pixel_shared_stock_boot_img)"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  cat <<EOF >&2
pixel: stock boot image not found in either:
  $(pixel_root_stock_boot_img)
  $(pixel_shared_stock_boot_img)

Run 'sc root-prep' first to cache the stock sunfish boot.img.
EOF
  return 1
}

pixel_publish_shared_stock_boot_img() {
  local source_path target_path target_dir temp_path
  source_path="${1:?pixel_publish_shared_stock_boot_img requires a source path}"
  target_path="$(pixel_shared_stock_boot_img)"
  target_dir="$(dirname "$target_path")"

  [[ -f "$source_path" ]] || {
    echo "pixel: shared stock boot source not found: $source_path" >&2
    return 1
  }

  mkdir -p "$target_dir"
  if [[ -f "$target_path" ]] && cmp -s "$source_path" "$target_path"; then
    return 0
  fi

  temp_path="$(mktemp "$target_dir/.boot.img.XXXXXX")"
  cp "$source_path" "$temp_path"
  mv "$temp_path" "$target_path"
}

pixel_root_magisk_apk() {
  printf '%s/Magisk.apk\n' "$(pixel_root_dir)"
}

pixel_root_magisk_info_json() {
  printf '%s/magisk-release.json\n' "$(pixel_root_dir)"
}

pixel_root_patched_boot_img() {
  printf '%s/magisk_patched.img\n' "$(pixel_root_dir)"
}

pixel_root_magisk_patch_assets_dir() {
  printf '%s/magisk-device-assets\n' "$(pixel_root_dir)"
}

pixel_root_patch_log() {
  printf '%s/magisk-patch.log\n' "$(pixel_root_dir)"
}

pixel_root_device_patch_dir() {
  printf '%s\n' "${PIXEL_ROOT_DEVICE_PATCH_DIR:-/data/local/tmp/shadow-magisk-patch}"
}

pixel_root_device_patched_boot_img() {
  printf '%s/new-boot.img\n' "$(pixel_root_device_patch_dir)"
}

pixel_root_device_boot_img() {
  printf '%s\n' "${PIXEL_ROOT_DEVICE_BOOT_IMG:-$(pixel_download_dir_device)/shadow-stock-boot.img}"
}

pixel_root_device_patched_glob() {
  printf '%s\n' "${PIXEL_ROOT_DEVICE_PATCHED_GLOB:-$(pixel_download_dir_device)/magisk_patched*.img}"
}

pixel_root_expected_fingerprint() {
  printf '%s\n' "${PIXEL_ROOT_EXPECTED_FINGERPRINT:-google/sunfish/sunfish:13/TQ3A.230805.001.S2/12655424:user/release-keys}"
}

pixel_require_expected_fingerprint() {
  local serial context expected actual
  serial="$1"
  context="$2"
  expected="$(pixel_root_expected_fingerprint)"
  actual="$(pixel_prop "$serial" ro.build.fingerprint)"

  if [[ "$actual" == "$expected" ]]; then
    return 0
  fi

  cat <<EOF >&2
$context: device fingerprint does not match the cached stock boot image.
expected: $expected
actual:   $actual

Run 'sc -t pixel ota-sideload' first, let Android boot, re-enable USB debugging, then retry.
EOF
  return 1
}

pixel_slot_suffix_to_letter() {
  case "$1" in
    _a)
      printf 'a\n'
      ;;
    _b)
      printf 'b\n'
      ;;
    *)
      echo "pixel: unknown slot suffix: $1" >&2
      return 1
      ;;
  esac
}

pixel_other_slot_letter() {
  case "$1" in
    a)
      printf 'b\n'
      ;;
    b)
      printf 'a\n'
      ;;
    *)
      echo "pixel: unknown slot letter: $1" >&2
      return 1
      ;;
  esac
}

pixel_current_slot_letter_from_adb() {
  local serial
  serial="$1"
  pixel_slot_suffix_to_letter "$(pixel_prop "$serial" ro.boot.slot_suffix)"
}

pixel_boot_partition_for_slot() {
  local slot_letter
  slot_letter="$(pixel_slot_suffix_to_letter "$1")"
  printf 'boot_%s\n' "$slot_letter"
}

pixel_boot_partition_for_slot_letter() {
  case "$1" in
    a|b)
      printf 'boot_%s\n' "$1"
      ;;
    *)
      echo "pixel: unknown slot letter: $1" >&2
      return 1
      ;;
  esac
}

pixel_fastboot_current_slot() {
  local serial current_slot
  serial="$1"
  current_slot="$(
    pixel_fastboot "$serial" getvar current-slot 2>&1 | awk -F': *' '/current-slot:/{print $2; exit}'
  )"
  current_slot="${current_slot//[$'\r\n\t ']}"
  [[ -n "$current_slot" ]] || {
    echo "pixel: failed to determine current fastboot slot for $serial" >&2
    return 1
  }
  printf '%s\n' "$current_slot"
}

pixel_boot_last_action_json() {
  printf '%s/last-action.json\n' "$(pixel_boot_dir)"
}
