#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

IMAGE_PATH="${PIXEL_BOOT_FLASH_RUN_IMAGE:-$(pixel_boot_log_probe_img)}"
REQUESTED_SLOT="${PIXEL_BOOT_FLASH_RUN_SLOT:-inactive}"
OUTPUT_DIR=""
WAIT_READY_SECS="${PIXEL_BOOT_FLASH_RUN_WAIT_READY_SECS:-120}"
ADB_TIMEOUT_SECS="${PIXEL_BOOT_FLASH_RUN_ADB_TIMEOUT_SECS:-180}"
BOOT_TIMEOUT_SECS="${PIXEL_BOOT_FLASH_RUN_BOOT_TIMEOUT_SECS:-240}"
ALLOW_ACTIVE_SLOT=0
RECOVER_AFTER=0
DRY_RUN=0
ORIGINAL_ARGS=("$@")

serial=""
metadata_path=""
status_path=""
collect_output_dir=""
image_sha256=""
slot_before=""
flash_succeeded=false
collect_succeeded=false
recover_attempted=false
recover_succeeded=false
metadata_present=false
adb_visible_after_failure=false
fastboot_visible_after_failure=false
failure_stage=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_flash_run.sh [--image PATH] [--slot inactive|active|a|b]
                                            [--output DIR] [--wait-ready SECONDS]
                                            [--adb-timeout SECONDS] [--boot-timeout SECONDS]
                                            [--allow-active-slot] [--recover-after] [--dry-run]

Run the flashed-slot boot validation loop: guarded flash with activation, wait for Android,
collect boot-lab evidence, and optionally recover the known-good slot afterward.

This private helper is intended to sit behind:
  sc -t <serial> debug boot-lab-flash-run
EOF
}

bool_word() {
  if [[ "$1" == "1" || "$1" == "true" ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

resolve_serial_for_mode() {
  if [[ "$DRY_RUN" == "1" && -n "${PIXEL_SERIAL:-}" ]]; then
    printf '%s\n' "$PIXEL_SERIAL"
    return 0
  fi

  pixel_resolve_serial
}

prepare_output_dir() {
  if [[ -z "$OUTPUT_DIR" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      OUTPUT_DIR="$(pixel_boot_flash_runs_dir)/$(pixel_timestamp)"
      return 0
    fi
    OUTPUT_DIR="$(pixel_prepare_named_run_dir "$(pixel_boot_flash_runs_dir)")"
    return 0
  fi

  if [[ -e "$OUTPUT_DIR" ]] && find "$OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    echo "pixel_boot_flash_run: output dir must be empty or absent: $OUTPUT_DIR" >&2
    exit 1
  fi

  if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p "$OUTPUT_DIR"
  fi
}

update_failure_visibility() {
  if [[ -n "$serial" ]] && pixel_connected_serials | grep -Fxq "$serial"; then
    adb_visible_after_failure=true
  fi
  if [[ -n "$serial" ]] && pixel_connected_fastboot_serials | grep -Fxq "$serial"; then
    fastboot_visible_after_failure=true
  fi
}

write_status() {
  local exit_code ok
  exit_code="$1"
  ok=false
  if [[ "$exit_code" -eq 0 ]]; then
    ok=true
  fi

  [[ -n "$status_path" ]] || return 0

  pixel_write_status_json \
    "$status_path" \
    kind=boot_flash_run \
    ok="$ok" \
    serial="$serial" \
    image="$IMAGE_PATH" \
    image_sha256="$image_sha256" \
    output_dir="$OUTPUT_DIR" \
    metadata_path="$metadata_path" \
    collect_output_dir="$collect_output_dir" \
    requested_slot="$REQUESTED_SLOT" \
    wait_ready_secs="$WAIT_READY_SECS" \
    adb_timeout_secs="$ADB_TIMEOUT_SECS" \
    boot_timeout_secs="$BOOT_TIMEOUT_SECS" \
    allow_active_slot="$ALLOW_ACTIVE_SLOT" \
    recover_after="$RECOVER_AFTER" \
    slot_before="$slot_before" \
    flash_succeeded="$flash_succeeded" \
    collect_succeeded="$collect_succeeded" \
    recover_attempted="$recover_attempted" \
    recover_succeeded="$recover_succeeded" \
    metadata_present="$metadata_present" \
    adb_visible_after_failure="$adb_visible_after_failure" \
    fastboot_visible_after_failure="$fastboot_visible_after_failure" \
    failure_stage="$failure_stage"
}

finish() {
  local exit_code
  exit_code="$?"
  trap - EXIT
  write_status "$exit_code"
  exit "$exit_code"
}

maybe_recover() {
  if [[ "$RECOVER_AFTER" != "1" ]]; then
    return 0
  fi
  if [[ ! -f "$metadata_path" ]]; then
    return 0
  fi

  metadata_present=true
  recover_attempted=true
  if PIXEL_SERIAL="$serial" PIXEL_BOOT_METADATA_PATH="$metadata_path" \
    PIXEL_BOOT_RECOVER_ADB_TIMEOUT_SECS="$ADB_TIMEOUT_SECS" \
    PIXEL_BOOT_RECOVER_BOOT_TIMEOUT_SECS="$BOOT_TIMEOUT_SECS" \
    "$SCRIPT_DIR/pixel/pixel_boot_recover.sh"; then
    recover_succeeded=true
    return 0
  fi

  failure_stage="${failure_stage:-recover}"
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      IMAGE_PATH="${2:?missing value for --image}"
      shift 2
      ;;
    --slot)
      REQUESTED_SLOT="${2:?missing value for --slot}"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="${2:?missing value for --output}"
      shift 2
      ;;
    --wait-ready)
      WAIT_READY_SECS="${2:?missing value for --wait-ready}"
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
    --allow-active-slot)
      ALLOW_ACTIVE_SLOT=1
      shift
      ;;
    --recover-after)
      RECOVER_AFTER=1
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
      echo "pixel_boot_flash_run: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -f "$IMAGE_PATH" ]] || {
  echo "pixel_boot_flash_run: image not found: $IMAGE_PATH" >&2
  exit 1
}

serial="$(resolve_serial_for_mode)"
pixel_require_host_lock "$serial" "$0" "${ORIGINAL_ARGS[@]}"
pixel_prepare_dirs
prepare_output_dir

metadata_path="$OUTPUT_DIR/boot-action.json"
status_path="$OUTPUT_DIR/status.json"
collect_output_dir="$OUTPUT_DIR/collect"
image_sha256="$(shasum -a 256 "$IMAGE_PATH" | awk '{print $1}')"

if [[ "$DRY_RUN" == "1" ]]; then
  cat <<EOF
pixel_boot_flash_run: dry-run
serial=$serial
image=$IMAGE_PATH
image_sha256=$image_sha256
requested_slot=$REQUESTED_SLOT
output_dir=$OUTPUT_DIR
metadata_path=$metadata_path
collect_output_dir=$collect_output_dir
wait_ready_secs=$WAIT_READY_SECS
adb_timeout_secs=$ADB_TIMEOUT_SECS
boot_timeout_secs=$BOOT_TIMEOUT_SECS
allow_active_slot=$(bool_word "$ALLOW_ACTIVE_SLOT")
recover_after=$(bool_word "$RECOVER_AFTER")
activate_target=true
EOF
  exit 0
fi

trap finish EXIT

slot_before="$(pixel_current_slot_letter_from_adb "$serial")"
pixel_write_status_json \
  "$metadata_path" \
  kind=boot_flash_run \
  serial="$serial" \
  image="$IMAGE_PATH" \
  image_sha256="$image_sha256" \
  requested_slot="$REQUESTED_SLOT" \
  slot_before="$slot_before" \
  wait_ready_secs="$WAIT_READY_SECS" \
  adb_timeout_secs="$ADB_TIMEOUT_SECS" \
  boot_timeout_secs="$BOOT_TIMEOUT_SECS" \
  allow_active_slot="$(bool_word "$ALLOW_ACTIVE_SLOT")" \
  recover_after="$(bool_word "$RECOVER_AFTER")"

printf 'Flash-running %s on %s\n' "$IMAGE_PATH" "$serial"
printf 'Current slot before flash: %s\n' "$slot_before"
flash_args=(
  --experimental
  --slot "$REQUESTED_SLOT"
  --activate-target
  --image "$IMAGE_PATH"
)
if [[ "$ALLOW_ACTIVE_SLOT" == "1" ]]; then
  flash_args+=(--allow-active-slot)
fi
if PIXEL_SERIAL="$serial" PIXEL_BOOT_METADATA_PATH="$metadata_path" \
  PIXEL_BOOT_FLASH_ADB_TIMEOUT_SECS="$ADB_TIMEOUT_SECS" \
  PIXEL_BOOT_FLASH_BOOT_TIMEOUT_SECS="$BOOT_TIMEOUT_SECS" \
  "$SCRIPT_DIR/pixel/pixel_boot_flash.sh" \
    "${flash_args[@]}"; then
  flash_succeeded=true
  metadata_present=true
else
  failure_stage="flash"
  if [[ -f "$metadata_path" ]]; then
    metadata_present=true
  fi
  update_failure_visibility
  maybe_recover || true
  exit 1
fi

if PIXEL_SERIAL="$serial" PIXEL_BOOT_METADATA_PATH="$metadata_path" \
  "$SCRIPT_DIR/pixel/pixel_boot_collect_logs.sh" \
    --output "$collect_output_dir" \
    --wait-ready "$WAIT_READY_SECS"; then
  collect_succeeded=true
else
  failure_stage="collect"
  if [[ -f "$metadata_path" ]]; then
    metadata_present=true
  fi
  update_failure_visibility
  maybe_recover || true
  exit 1
fi

if ! maybe_recover; then
  failure_stage="recover"
  exit 1
fi

printf 'Collected flashed boot evidence: %s\n' "$collect_output_dir"
printf 'Run status: %s\n' "$status_path"
