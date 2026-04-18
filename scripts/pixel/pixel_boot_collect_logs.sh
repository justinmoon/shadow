#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_DIR=""
DEVICE_LOG_ROOT="$(pixel_boot_device_log_root)"
WRAPPER_MARKER_ROOT="${PIXEL_INIT_WRAPPER_MARKER_ROOT:-/.shadow-init-wrapper}"
WAIT_READY_SECS="${PIXEL_BOOT_LOG_WAIT_READY_SECS:-120}"
METADATA_PATH="${PIXEL_BOOT_METADATA_PATH:-$(pixel_boot_last_action_json)}"

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_collect_logs.sh [--output DIR] [--device-log-root PATH] [--wait-ready SECONDS]
                                              [--metadata PATH] [--wrapper-marker-root PATH]

Pull private Shadow boot helper logs from a booted Pixel after an experimental stock-init boot.
EOF
}

device_log_dir_name() {
  basename "$DEVICE_LOG_ROOT"
}

wrapper_marker_dir_name() {
  basename "$WRAPPER_MARKER_ROOT"
}

device_boot_id() {
  local serial
  serial="$1"
  pixel_adb "$serial" shell 'cat /proc/sys/kernel/random/boot_id 2>/dev/null' 2>/dev/null | tr -d '\r\n' || true
}

device_slot_suffix() {
  local serial
  serial="$1"
  pixel_adb "$serial" shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r\n' || true
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

device_path_exists() {
  local serial device_path
  serial="$1"
  device_path="$2"
  pixel_adb "$serial" shell "[ -e '$device_path' ]" >/dev/null 2>&1
}

pull_device_dir_if_present() {
  local serial device_path host_root
  serial="$1"
  device_path="$2"
  host_root="$3"

  if ! device_path_exists "$serial" "$device_path"; then
    return 1
  fi

  pixel_adb "$serial" pull "$device_path" "$host_root" >/dev/null
}

capture_adb_shell_best_effort() {
  local serial output_path
  serial="$1"
  output_path="$2"
  shift 2

  if pixel_adb "$serial" shell "$@" >"$output_path" 2>/dev/null; then
    return 0
  fi

  : >"$output_path"
  return 1
}

collect_wrapper_markers_best_effort() {
  local serial output_root wrapper_dir marker_file
  serial="$1"
  output_root="$2"
  wrapper_dir="$output_root/$(wrapper_marker_dir_name)"

  mkdir -p "$wrapper_dir"
  pixel_adb "$serial" shell "ls -ld '$WRAPPER_MARKER_ROOT' 2>/dev/null || true" >"$wrapper_dir/ls.txt" || true
  pull_device_dir_if_present "$serial" "$WRAPPER_MARKER_ROOT" "$output_root" || true

  for marker_file in boot-id.txt events.log pid.txt status.txt; do
    pixel_adb "$serial" shell "cat '$WRAPPER_MARKER_ROOT/$marker_file' 2>/dev/null || true" >"$wrapper_dir/$marker_file" || true
  done
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
    --wrapper-marker-root)
      WRAPPER_MARKER_ROOT="${2:?missing value for --wrapper-marker-root}"
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

wait_ready_timed_out=false
if [[ "$WAIT_READY_SECS" != "0" ]]; then
  if ! pixel_wait_for_condition "$WAIT_READY_SECS" 1 device_log_ready "$serial" "$DEVICE_LOG_ROOT"; then
    cat <<EOF >&2
pixel_boot_collect_logs: timed out waiting for $DEVICE_LOG_ROOT/status.txt on $serial; continuing with best-effort collection

Try collecting again later, or inspect the device manually with:
  adb -s $serial shell ls -l '$DEVICE_LOG_ROOT'
EOF
    wait_ready_timed_out=true
  fi
fi

mkdir -p "$OUTPUT_DIR/device"
helper_dir_present=false
helper_dir_pulled=false
if device_path_exists "$serial" "$DEVICE_LOG_ROOT"; then
  helper_dir_present=true
  if pull_device_dir_if_present "$serial" "$DEVICE_LOG_ROOT" "$OUTPUT_DIR/device"; then
    helper_dir_pulled=true
  fi
fi
wrapper_marker_dir_present=false
if device_path_exists "$serial" "$WRAPPER_MARKER_ROOT"; then
  wrapper_marker_dir_present=true
fi
collect_wrapper_markers_best_effort "$serial" "$OUTPUT_DIR/device"
capture_adb_shell_best_effort "$serial" "$OUTPUT_DIR/getprop.txt" getprop || true
capture_adb_shell_best_effort "$serial" "$OUTPUT_DIR/logcat-shadow.txt" 'logcat -d -s shadow-init:I shadow-boot:I 2>/dev/null || true' || true
capture_adb_shell_best_effort "$serial" "$OUTPUT_DIR/logcat-kernel.txt" 'logcat -b kernel -d 2>/dev/null || true' || true
capture_adb_shell_best_effort "$serial" "$OUTPUT_DIR/ps.txt" 'ps -A -o USER,PID,PPID,NAME,ARGS 2>/dev/null || ps -A || true' || true

log_dir="$OUTPUT_DIR/device/$(device_log_dir_name)"
helper_status_present=false
if [[ -f "$log_dir/status.txt" ]]; then
  helper_status_present=true
fi
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
wrapper_dir="$OUTPUT_DIR/device/$(wrapper_marker_dir_name)"
wrapper_status=""
wrapper_boot_id=""
wrapper_matches_current_boot=false

if [[ -f "$wrapper_dir/status.txt" ]]; then
  wrapper_status="$(tr -d '\r\n' <"$wrapper_dir/status.txt")"
fi
if [[ -f "$wrapper_dir/boot-id.txt" ]]; then
  wrapper_boot_id="$(tr -d '\r\n' <"$wrapper_dir/boot-id.txt")"
fi

if [[ -n "$boot_id" && -n "$live_boot_id" && "$boot_id" == "$live_boot_id" ]]; then
  matched_current_boot=true
fi
if [[ -n "$pulled_slot_suffix" && "$pulled_slot_suffix" == "$live_slot_suffix" ]]; then
  matched_current_slot=true
fi
if [[ -n "$expected_slot_suffix" && "$pulled_slot_suffix" != "$expected_slot_suffix" ]]; then
  matched_expected_slot=false
fi
if [[ -n "$wrapper_boot_id" && -n "$live_boot_id" && "$wrapper_boot_id" == "$live_boot_id" ]]; then
  wrapper_matches_current_boot=true
fi

collection_succeeded=false
if [[ "$helper_dir_present" == "true" && "$helper_dir_pulled" == "true" && "$helper_status_present" == "true" && "$matched_current_boot" == "true" && "$matched_current_slot" == "true" && "$matched_expected_slot" == "true" ]]; then
  collection_succeeded=true
fi

pixel_write_status_json \
  "$OUTPUT_DIR/status.json" \
  kind=boot_log_collect \
  serial="$serial" \
  device_log_root="$DEVICE_LOG_ROOT" \
  helper_dir_present="$helper_dir_present" \
  helper_dir_pulled="$helper_dir_pulled" \
  helper_status_present="$helper_status_present" \
  wrapper_marker_root="$WRAPPER_MARKER_ROOT" \
  wrapper_marker_dir_present="$wrapper_marker_dir_present" \
  wrapper_status="$wrapper_status" \
  wrapper_boot_id="$wrapper_boot_id" \
  wrapper_matches_current_boot="$wrapper_matches_current_boot" \
  boot_id="$boot_id" \
  live_boot_id="$live_boot_id" \
  pulled_slot_suffix="$pulled_slot_suffix" \
  live_slot_suffix="$live_slot_suffix" \
  expected_slot_suffix="$expected_slot_suffix" \
  matched_current_boot="$matched_current_boot" \
  matched_current_slot="$matched_current_slot" \
  matched_expected_slot="$matched_expected_slot" \
  waited_for_ready="$(if [[ "$WAIT_READY_SECS" != "0" ]]; then printf true; else printf false; fi)" \
  wait_ready_timed_out="$wait_ready_timed_out" \
  collection_succeeded="$collection_succeeded"

if [[ "$collection_succeeded" != "true" ]]; then
  cat <<EOF >&2
pixel_boot_collect_logs: helper logs do not prove the current probe boot.

live_boot_id=$live_boot_id
pulled_boot_id=$boot_id
live_slot_suffix=$live_slot_suffix
pulled_slot_suffix=$pulled_slot_suffix
expected_slot_suffix=${expected_slot_suffix:-<none>}
helper_dir_present=$helper_dir_present
helper_status_present=$helper_status_present
wrapper_marker_dir_present=$wrapper_marker_dir_present
wrapper_status=${wrapper_status:-<missing>}
wrapper_boot_id=${wrapper_boot_id:-<missing>}
wrapper_matches_current_boot=$wrapper_matches_current_boot
status_path=$OUTPUT_DIR/status.json
EOF
  exit 1
fi

printf 'Collected boot logs: %s\n' "$OUTPUT_DIR"
printf 'Serial: %s\n' "$serial"
printf 'Device log root: %s\n' "$DEVICE_LOG_ROOT"
printf 'Boot ID: %s\n' "$boot_id"
if [[ -n "$wrapper_status" ]]; then
  printf 'Wrapper status: %s\n' "$wrapper_status"
fi
