#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

IMAGE_PATH="${PIXEL_BOOT_ONESHOT_IMAGE:-$(pixel_boot_log_probe_img)}"
OUTPUT_DIR=""
WAIT_READY_SECS="${PIXEL_BOOT_ONESHOT_WAIT_READY_SECS:-120}"
ADB_TIMEOUT_SECS="${PIXEL_BOOT_ONESHOT_ADB_TIMEOUT_SECS:-180}"
BOOT_TIMEOUT_SECS="${PIXEL_BOOT_ONESHOT_BOOT_TIMEOUT_SECS:-240}"
WAIT_BOOT_COMPLETED=1
PROOF_PROP_SPEC="${PIXEL_BOOT_PROOF_PROP:-}"
DRY_RUN=0
ORIGINAL_ARGS=("$@")

serial=""
metadata_path=""
status_path=""
collect_output_dir=""
image_sha256=""
slot_before=""
slot_after=""
shadow_probe_prop=""
adb_ready=false
boot_completed=false
collect_succeeded=false
boot_completed_required_failed=false
failure_stage=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_oneshot.sh [--image PATH] [--output DIR] [--wait-ready SECONDS]
                                          [--adb-timeout SECONDS] [--boot-timeout SECONDS]
                                          [--no-wait-boot-completed] [--proof-prop KEY=VALUE]
                                          [--dry-run]

One-shot boot a custom sunfish image with `fastboot boot`, wait for adb, and collect boot-lab evidence.

This private helper is intended to sit behind:
  sc -t <serial> debug boot-lab-oneshot
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
      OUTPUT_DIR="$(pixel_boot_oneshots_dir)/$(pixel_timestamp)"
      return 0
    fi
    OUTPUT_DIR="$(pixel_prepare_named_run_dir "$(pixel_boot_oneshots_dir)")"
    return 0
  fi

  if [[ -e "$OUTPUT_DIR" ]] && find "$OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    echo "pixel_boot_oneshot: output dir must be empty or absent: $OUTPUT_DIR" >&2
    exit 1
  fi

  if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p "$OUTPUT_DIR"
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
    kind=boot_oneshot \
    ok="$ok" \
    serial="$serial" \
    image="$IMAGE_PATH" \
    image_sha256="$image_sha256" \
    output_dir="$OUTPUT_DIR" \
    metadata_path="$metadata_path" \
    collect_output_dir="$collect_output_dir" \
    wait_ready_secs="$WAIT_READY_SECS" \
    adb_timeout_secs="$ADB_TIMEOUT_SECS" \
    boot_timeout_secs="$BOOT_TIMEOUT_SECS" \
    wait_boot_completed="$(bool_word "$WAIT_BOOT_COMPLETED")" \
    proof_prop="$PROOF_PROP_SPEC" \
    slot_before="$slot_before" \
    slot_after="$slot_after" \
    shadow_probe_prop="$shadow_probe_prop" \
    adb_ready="$adb_ready" \
    boot_completed="$boot_completed" \
    boot_completed_required_failed="$boot_completed_required_failed" \
    collect_succeeded="$collect_succeeded" \
    failure_stage="$failure_stage"
}

finish() {
  local exit_code=$?
  trap - EXIT
  write_status "$exit_code"
  exit "$exit_code"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      IMAGE_PATH="${2:?missing value for --image}"
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
    --no-wait-boot-completed)
      WAIT_BOOT_COMPLETED=0
      shift
      ;;
    --proof-prop)
      PROOF_PROP_SPEC="${2:?missing value for --proof-prop}"
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
      echo "pixel_boot_oneshot: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -f "$IMAGE_PATH" ]] || {
  echo "pixel_boot_oneshot: image not found: $IMAGE_PATH" >&2
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
pixel_boot_oneshot: dry-run
serial=$serial
image=$IMAGE_PATH
image_sha256=$image_sha256
output_dir=$OUTPUT_DIR
metadata_path=$metadata_path
collect_output_dir=$collect_output_dir
wait_ready_secs=$WAIT_READY_SECS
adb_timeout_secs=$ADB_TIMEOUT_SECS
boot_timeout_secs=$BOOT_TIMEOUT_SECS
wait_boot_completed=$(bool_word "$WAIT_BOOT_COMPLETED")
proof_prop=$PROOF_PROP_SPEC
EOF
  exit 0
fi

trap finish EXIT

slot_before="$(pixel_current_slot_letter_from_adb "$serial")"
pixel_write_status_json \
  "$metadata_path" \
  kind=boot_oneshot \
  serial="$serial" \
  image="$IMAGE_PATH" \
  image_sha256="$image_sha256" \
  slot_before="$slot_before" \
  wait_ready_secs="$WAIT_READY_SECS" \
  adb_timeout_secs="$ADB_TIMEOUT_SECS" \
  boot_timeout_secs="$BOOT_TIMEOUT_SECS" \
  proof_prop="$PROOF_PROP_SPEC" \
  wait_boot_completed="$(bool_word "$WAIT_BOOT_COMPLETED")"

printf 'One-shot booting %s on %s\n' "$IMAGE_PATH" "$serial"
printf 'Current slot before fastboot boot: %s\n' "$slot_before"
pixel_adb "$serial" reboot bootloader
pixel_wait_for_fastboot "$serial" 60
pixel_fastboot "$serial" boot "$IMAGE_PATH"

if ! pixel_wait_for_adb "$serial" "$ADB_TIMEOUT_SECS"; then
  failure_stage="wait-adb"
  exit 1
fi
adb_ready=true

slot_after="$(pixel_current_slot_letter_from_adb "$serial" 2>/dev/null || true)"
shadow_probe_prop="$(pixel_prop "$serial" ro.boot.shadow_probe 2>/dev/null || true)"
if [[ "$WAIT_BOOT_COMPLETED" == "1" ]]; then
  if pixel_wait_for_boot_completed "$serial" "$BOOT_TIMEOUT_SECS"; then
    boot_completed=true
  else
    boot_completed_required_failed=true
    failure_stage="wait-boot-completed"
  fi
fi

collect_args=(
  --output "$collect_output_dir"
  --wait-ready "$WAIT_READY_SECS"
)
if [[ -n "$PROOF_PROP_SPEC" ]]; then
  collect_args+=(--proof-prop "$PROOF_PROP_SPEC")
fi

if PIXEL_SERIAL="$serial" PIXEL_BOOT_METADATA_PATH="$metadata_path" \
  "$SCRIPT_DIR/pixel/pixel_boot_collect_logs.sh" \
    "${collect_args[@]}"; then
  collect_succeeded=true
else
  if [[ -z "$failure_stage" ]]; then
    failure_stage="collect"
  fi
  exit 1
fi

if [[ "$boot_completed_required_failed" == "true" ]]; then
  exit 1
fi

printf 'Collected one-shot boot evidence: %s\n' "$collect_output_dir"
printf 'Run status: %s\n' "$status_path"
