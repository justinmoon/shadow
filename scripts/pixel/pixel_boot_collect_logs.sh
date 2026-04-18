#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_DIR=""
DEVICE_LOG_ROOT="$(pixel_boot_device_log_root)"
WAIT_READY_SECS="${PIXEL_BOOT_LOG_WAIT_READY_SECS:-120}"
METADATA_PATH="${PIXEL_BOOT_METADATA_PATH:-$(pixel_boot_last_action_json)}"

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_collect_logs.sh [--output DIR] [--device-log-root PATH] [--wait-ready SECONDS]
                                              [--metadata PATH]

Pull private Shadow boot helper logs from a booted Pixel after an experimental stock-init boot.
EOF
}

device_log_dir_name() {
  basename "$DEVICE_LOG_ROOT"
}

device_boot_id() {
  local serial
  serial="$1"
  pixel_adb "$serial" shell 'cat /proc/sys/kernel/random/boot_id 2>/dev/null' | tr -d '\r\n'
}

device_slot_suffix() {
  local serial
  serial="$1"
  pixel_adb "$serial" shell getprop ro.boot.slot_suffix | tr -d '\r\n'
}

metadata_expected_slot_suffix() {
  local metadata_path
  metadata_path="$1"
  python3 - "$metadata_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.is_file():
    raise SystemExit(0)

with path.open("r", encoding="utf-8") as fh:
    payload = json.load(fh)

target = payload.get("target_slot")
if payload.get("kind") == "boot_flash" and payload.get("activate_target") is True and target in {"a", "b"}:
    print(f"_{target}")
PY
}

device_log_ready() {
  local serial device_log_root
  serial="$1"
  device_log_root="$2"
  pixel_adb "$serial" shell "
    live_boot_id=\$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r\n')
    live_slot=\$(getprop ro.boot.slot_suffix | tr -d '\r\n')
    [ -n \"\$live_boot_id\" ] &&
    [ -f '$device_log_root/status.txt' ] &&
    [ -f '$device_log_root/boot-id.txt' ] &&
    [ -f '$device_log_root/slot-suffix.txt' ] &&
    [ \"\$(cat '$device_log_root/boot-id.txt' 2>/dev/null | tr -d '\r\n')\" = \"\$live_boot_id\" ] &&
    [ \"\$(cat '$device_log_root/slot-suffix.txt' 2>/dev/null | tr -d '\r\n')\" = \"\$live_slot\" ]
  "
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_DIR="${2:?missing value for --output}"
      shift 2
      ;;
    --device-log-root)
      DEVICE_LOG_ROOT="${2:?missing value for --device-log-root}"
      shift 2
      ;;
    --wait-ready)
      WAIT_READY_SECS="${2:?missing value for --wait-ready}"
      shift 2
      ;;
    --metadata)
      METADATA_PATH="${2:?missing value for --metadata}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "pixel_boot_collect_logs: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

serial="$(pixel_resolve_serial)"
pixel_prepare_dirs
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(pixel_prepare_named_run_dir "$(pixel_boot_logs_dir)")"
elif [[ -e "$OUTPUT_DIR" ]] && find "$OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
  echo "pixel_boot_collect_logs: output dir must be empty or absent: $OUTPUT_DIR" >&2
  exit 1
else
  mkdir -p "$OUTPUT_DIR"
fi

if [[ "$WAIT_READY_SECS" != "0" ]]; then
  if ! pixel_wait_for_condition "$WAIT_READY_SECS" 1 device_log_ready "$serial" "$DEVICE_LOG_ROOT"; then
    cat <<EOF >&2
pixel_boot_collect_logs: timed out waiting for $DEVICE_LOG_ROOT/status.txt on $serial

Try collecting again later, or inspect the device manually with:
  adb -s $serial shell ls -l '$DEVICE_LOG_ROOT'
EOF
    exit 1
  fi
fi

mkdir -p "$OUTPUT_DIR/device"
pixel_adb "$serial" pull "$DEVICE_LOG_ROOT" "$OUTPUT_DIR/device" >/dev/null
pixel_adb "$serial" shell getprop >"$OUTPUT_DIR/getprop.txt"
pixel_adb "$serial" shell 'logcat -d -s shadow-init:I shadow-boot:I 2>/dev/null || true' >"$OUTPUT_DIR/logcat-shadow.txt"
pixel_adb "$serial" shell 'logcat -b kernel -d 2>/dev/null || true' >"$OUTPUT_DIR/logcat-kernel.txt"
pixel_adb "$serial" shell 'ps -A -o USER,PID,PPID,NAME,ARGS 2>/dev/null || ps -A || true' >"$OUTPUT_DIR/ps.txt"

log_dir="$OUTPUT_DIR/device/$(device_log_dir_name)"
boot_id=""
if [[ -f "$log_dir/boot-id.txt" ]]; then
  boot_id="$(tr -d '\r\n' <"$log_dir/boot-id.txt")"
fi
pulled_slot_suffix=""
if [[ -f "$log_dir/slot-suffix.txt" ]]; then
  pulled_slot_suffix="$(tr -d '\r\n' <"$log_dir/slot-suffix.txt")"
fi
live_boot_id="$(device_boot_id "$serial")"
live_slot_suffix="$(device_slot_suffix "$serial")"
expected_slot_suffix="$(metadata_expected_slot_suffix "$METADATA_PATH")"
matched_current_boot=false
matched_current_slot=false
matched_expected_slot=true

if [[ -n "$boot_id" && -n "$live_boot_id" && "$boot_id" == "$live_boot_id" ]]; then
  matched_current_boot=true
fi
if [[ -n "$pulled_slot_suffix" && "$pulled_slot_suffix" == "$live_slot_suffix" ]]; then
  matched_current_slot=true
fi
if [[ -n "$expected_slot_suffix" && "$pulled_slot_suffix" != "$expected_slot_suffix" ]]; then
  matched_expected_slot=false
fi

pixel_write_status_json \
  "$OUTPUT_DIR/status.json" \
  kind=boot_log_collect \
  serial="$serial" \
  device_log_root="$DEVICE_LOG_ROOT" \
  boot_id="$boot_id" \
  live_boot_id="$live_boot_id" \
  pulled_slot_suffix="$pulled_slot_suffix" \
  live_slot_suffix="$live_slot_suffix" \
  expected_slot_suffix="$expected_slot_suffix" \
  matched_current_boot="$matched_current_boot" \
  matched_current_slot="$matched_current_slot" \
  matched_expected_slot="$matched_expected_slot" \
  waited_for_ready="$(if [[ "$WAIT_READY_SECS" != "0" ]]; then printf true; else printf false; fi)"

if [[ "$matched_current_boot" != "true" || "$matched_current_slot" != "true" || "$matched_expected_slot" != "true" ]]; then
  cat <<EOF >&2
pixel_boot_collect_logs: pulled logs do not match the current probe boot.

live_boot_id=$live_boot_id
pulled_boot_id=$boot_id
live_slot_suffix=$live_slot_suffix
pulled_slot_suffix=$pulled_slot_suffix
expected_slot_suffix=${expected_slot_suffix:-<none>}
status_path=$OUTPUT_DIR/status.json
EOF
  exit 1
fi

printf 'Collected boot logs: %s\n' "$OUTPUT_DIR"
printf 'Serial: %s\n' "$serial"
printf 'Device log root: %s\n' "$DEVICE_LOG_ROOT"
printf 'Boot ID: %s\n' "$boot_id"
