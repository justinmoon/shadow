#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

METADATA_PATH="${PIXEL_BOOT_METADATA_PATH:-$(pixel_boot_last_action_json)}"
RESTORE_IMAGE="${PIXEL_BOOT_RESTORE_IMAGE:-$(pixel_root_stock_boot_img)}"
ADB_TIMEOUT_SECS="${PIXEL_BOOT_RECOVER_ADB_TIMEOUT_SECS:-180}"
BOOT_TIMEOUT_SECS="${PIXEL_BOOT_RECOVER_BOOT_TIMEOUT_SECS:-240}"
RESTORE_TARGET_SLOT=1
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_recover.sh [--metadata PATH] [--image PATH]
                                           [--no-restore-target-slot] [--dry-run]

Recover from an activated experimental boot by switching back to the known-good slot
recorded in last-action.json, and optionally restore the experimental slot to stock boot.
EOF
}

read_boot_flash_metadata() {
  local metadata_path
  metadata_path="$1"
  python3 - "$metadata_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.is_file():
    raise SystemExit("pixel_boot_recover: metadata not found")

with path.open("r", encoding="utf-8") as fh:
    payload = json.load(fh)

if payload.get("kind") != "boot_flash":
    raise SystemExit("pixel_boot_recover: metadata is not a boot_flash action")

known_good = payload.get("known_good_slot") or payload.get("current_slot")
target = payload.get("target_slot")
activate_target = payload.get("activate_target")

if known_good not in {"a", "b"}:
    raise SystemExit("pixel_boot_recover: metadata missing known_good_slot")
if target not in {"a", "b"}:
    raise SystemExit("pixel_boot_recover: metadata missing target_slot")

print(known_good)
print(target)
print("true" if activate_target is True else "false")
PY
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
    --metadata)
      METADATA_PATH="${2:?missing value for --metadata}"
      shift 2
      ;;
    --image)
      RESTORE_IMAGE="${2:?missing value for --image}"
      shift 2
      ;;
    --no-restore-target-slot)
      RESTORE_TARGET_SLOT=0
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
      echo "pixel_boot_recover: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

mapfile -t metadata_fields < <(read_boot_flash_metadata "$METADATA_PATH")
known_good_slot="${metadata_fields[0]}"
target_slot="${metadata_fields[1]}"
activate_target="${metadata_fields[2]}"

if [[ "$known_good_slot" == "$target_slot" ]]; then
  cat <<EOF >&2
pixel_boot_recover: metadata says known_good_slot=$known_good_slot and target_slot=$target_slot.

Automatic recovery is only supported for inactive-slot experimental flashes.
EOF
  exit 1
fi

if [[ "$RESTORE_TARGET_SLOT" == "1" && ! -f "$RESTORE_IMAGE" ]]; then
  cat <<EOF >&2
pixel_boot_recover: restore image not found: $RESTORE_IMAGE

Run 'sc root-prep' first to cache the stock sunfish boot.img, or pass --image PATH.
EOF
  exit 1
fi

transport=fastboot
if serial="$(pixel_resolve_serial 2>/dev/null)"; then
  transport=adb
else
  serial="$(pixel_resolve_fastboot_serial)"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  cat <<EOF
pixel_boot_recover: dry-run
serial=$serial
transport=$transport
metadata_path=$METADATA_PATH
known_good_slot=$known_good_slot
target_slot=$target_slot
activate_target=$activate_target
restore_target_slot=$(bool_word "$RESTORE_TARGET_SLOT")
restore_image=$RESTORE_IMAGE
EOF
  exit 0
fi

if [[ "$transport" == "adb" ]]; then
  pixel_adb "$serial" reboot bootloader
  pixel_wait_for_fastboot "$serial" 60
fi

if [[ "$RESTORE_TARGET_SLOT" == "1" ]]; then
  target_partition="$(pixel_boot_partition_for_slot_letter "$target_slot")"
  printf 'Restoring %s to %s on %s\n' "$RESTORE_IMAGE" "$target_partition" "$serial"
  pixel_fastboot "$serial" flash "$target_partition" "$RESTORE_IMAGE"
fi

printf 'Setting active slot to %s on %s\n' "$known_good_slot" "$serial"
pixel_fastboot "$serial" set_active "$known_good_slot"

pixel_write_status_json \
  "$(pixel_boot_last_action_json)" \
  kind=boot_recover \
  serial="$serial" \
  known_good_slot="$known_good_slot" \
  target_slot="$target_slot" \
  restored_target_slot="$(bool_word "$RESTORE_TARGET_SLOT")" \
  restore_image="$RESTORE_IMAGE"

pixel_fastboot "$serial" reboot
pixel_wait_for_adb "$serial" "$ADB_TIMEOUT_SECS"
pixel_wait_for_boot_completed "$serial" "$BOOT_TIMEOUT_SECS"

printf 'Recovered to known-good slot %s on %s\n' "$known_good_slot" "$serial"
printf 'Metadata: %s\n' "$(pixel_boot_last_action_json)"
