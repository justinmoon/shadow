#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

IMAGE_PATH="${PIXEL_BOOT_FLASH_IMAGE:-$(pixel_boot_custom_boot_img)}"
ADB_TIMEOUT_SECS="${PIXEL_BOOT_FLASH_ADB_TIMEOUT_SECS:-180}"
BOOT_TIMEOUT_SECS="${PIXEL_BOOT_FLASH_BOOT_TIMEOUT_SECS:-240}"
REQUESTED_SLOT="${PIXEL_BOOT_FLASH_SLOT:-inactive}"
EXPERIMENTAL_ACK=0
ALLOW_ACTIVE_SLOT=0
ACTIVATE_TARGET=0
REBOOT_AFTER_FLASH=1
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_flash.sh --experimental [--image PATH] [--slot inactive|active|a|b]
                                        [--activate-target] [--allow-active-slot] [--no-reboot] [--dry-run]

Stage or boot a custom stock-init sunfish boot image with safety rails around the working Magisk lane.

Defaults:
  --slot inactive     Flash the other slot, not the current running slot.
  no activation       Leave the current slot active unless --activate-target is passed.
  reboot              Reboot after flashing unless --no-reboot is passed.
EOF
}

resolve_target_slot_letter() {
  local requested_slot current_slot
  requested_slot="$1"
  current_slot="$2"

  case "$requested_slot" in
    inactive)
      pixel_other_slot_letter "$current_slot"
      ;;
    active)
      printf '%s\n' "$current_slot"
      ;;
    a|b)
      printf '%s\n' "$requested_slot"
      ;;
    *)
      echo "pixel_boot_flash: unsupported --slot $requested_slot; expected inactive, active, a, or b" >&2
      exit 1
      ;;
  esac
}

bool_word() {
  if [[ "$1" == "1" ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --experimental)
      EXPERIMENTAL_ACK=1
      shift
      ;;
    --image)
      IMAGE_PATH="${2:?missing value for --image}"
      shift 2
      ;;
    --slot)
      REQUESTED_SLOT="${2:?missing value for --slot}"
      shift 2
      ;;
    --activate-target)
      ACTIVATE_TARGET=1
      shift
      ;;
    --allow-active-slot)
      ALLOW_ACTIVE_SLOT=1
      shift
      ;;
    --no-reboot)
      REBOOT_AFTER_FLASH=0
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
      echo "pixel_boot_flash: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -f "$IMAGE_PATH" ]] || {
  echo "pixel_boot_flash: image not found: $IMAGE_PATH" >&2
  exit 1
}

if [[ "$EXPERIMENTAL_ACK" != "1" ]]; then
  cat <<'EOF' >&2
pixel_boot_flash: refusing to flash without explicit experimental acknowledgement.

Pass --experimental after reading the summary. The safe default is:
  scripts/pixel/pixel_boot_flash.sh --experimental --slot inactive
EOF
  exit 1
fi

serial="$(pixel_resolve_serial)"
pixel_require_expected_fingerprint "$serial" "pixel-boot-flash"
current_slot="$(pixel_current_slot_letter_from_adb "$serial")"
target_slot="$(resolve_target_slot_letter "$REQUESTED_SLOT" "$current_slot")"

if [[ "$target_slot" == "$current_slot" && "$ALLOW_ACTIVE_SLOT" != "1" ]]; then
  cat <<EOF >&2
pixel_boot_flash: target slot $target_slot is the current running slot.

That would clobber the working Magisk lane on this device.
Use --slot inactive for the safe path, or add --allow-active-slot if you really intend to overwrite the current slot.
EOF
  exit 1
fi

boot_partition="$(pixel_boot_partition_for_slot_letter "$target_slot")"
metadata_path="$(pixel_boot_last_action_json)"

if [[ "$DRY_RUN" == "1" ]]; then
  cat <<EOF
pixel_boot_flash: dry-run
serial=$serial
image=$IMAGE_PATH
current_slot=$current_slot
target_slot=$target_slot
target_partition=$boot_partition
activate_target=$(bool_word "$ACTIVATE_TARGET")
reboot=$(bool_word "$REBOOT_AFTER_FLASH")
current_magisk_lane_preserved=$(if [[ "$target_slot" != "$current_slot" && "$ACTIVATE_TARGET" != "1" ]]; then printf true; else printf false; fi)
metadata_path=$metadata_path
EOF
  exit 0
fi

printf 'Flashing %s to %s on %s\n' "$IMAGE_PATH" "$boot_partition" "$serial"
printf 'Current slot: %s\n' "$current_slot"
printf 'Target slot: %s\n' "$target_slot"
if [[ "$target_slot" != "$current_slot" && "$ACTIVATE_TARGET" != "1" ]]; then
  printf 'Safety rail: current Magisk lane stays on slot %s; the experimental image is only staged on slot %s.\n' "$current_slot" "$target_slot"
fi

pixel_adb "$serial" reboot bootloader
pixel_wait_for_fastboot "$serial" 60

bootloader_current_slot="$(pixel_fastboot_current_slot "$serial")"
if [[ "$bootloader_current_slot" != "$current_slot" ]]; then
  printf 'Bootloader reports current slot %s; recomputing target from requested slot %s\n' "$bootloader_current_slot" "$REQUESTED_SLOT"
  current_slot="$bootloader_current_slot"
  target_slot="$(resolve_target_slot_letter "$REQUESTED_SLOT" "$current_slot")"
  if [[ "$target_slot" == "$current_slot" && "$ALLOW_ACTIVE_SLOT" != "1" ]]; then
    echo "pixel_boot_flash: refusing to overwrite the bootloader-active slot after recomputing the target" >&2
    exit 1
  fi
  boot_partition="$(pixel_boot_partition_for_slot_letter "$target_slot")"
fi

pixel_fastboot "$serial" flash "$boot_partition" "$IMAGE_PATH"

if [[ "$ACTIVATE_TARGET" == "1" && "$target_slot" != "$current_slot" ]]; then
  printf 'Setting active slot to %s\n' "$target_slot"
  pixel_fastboot "$serial" set_active "$target_slot"
fi

pixel_write_status_json \
  "$metadata_path" \
  kind=boot_flash \
  image="$IMAGE_PATH" \
  current_slot="$current_slot" \
  target_slot="$target_slot" \
  activate_target="$(bool_word "$ACTIVATE_TARGET")" \
  reboot="$(bool_word "$REBOOT_AFTER_FLASH")" \
  current_magisk_lane_preserved="$(if [[ "$target_slot" != "$current_slot" && "$ACTIVATE_TARGET" != "1" ]]; then printf true; else printf false; fi)"

if [[ "$REBOOT_AFTER_FLASH" != "1" ]]; then
  printf 'Leaving %s in fastboot with slot %s staged.\n' "$serial" "$target_slot"
  printf 'Metadata: %s\n' "$metadata_path"
  exit 0
fi

pixel_fastboot "$serial" reboot
pixel_wait_for_adb "$serial" "$ADB_TIMEOUT_SECS"
pixel_wait_for_boot_completed "$serial" "$BOOT_TIMEOUT_SECS"

printf 'Boot image flash completed on %s\n' "$serial"
printf 'Metadata: %s\n' "$metadata_path"
cat <<EOF
Next steps:
  inspect the staged slot metadata in $metadata_path
  if you only staged the inactive slot, the working Magisk lane should still be on slot $current_slot
  restore an explicit slot later with:
    PIXEL_SERIAL=$serial scripts/pixel/pixel_boot_restore.sh --slot current
    PIXEL_SERIAL=$serial scripts/pixel/pixel_boot_restore.sh --slot inactive
EOF
