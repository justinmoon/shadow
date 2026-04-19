#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"

OUTPUT_DIR=""
DRY_RUN=0
ORIGINAL_ARGS=("$@")
SHADOW_TAG_REGEX='shadow-hello-init|shadow-drm|shadow-owned-init-'
RECOVERY_ROOT_NAME="recover-traces"
ADB_TIMEOUT_SECS="${PIXEL_BOOT_RECOVER_TRACES_ADB_TIMEOUT_SECS:-120}"
BOOT_TIMEOUT_SECS="${PIXEL_BOOT_RECOVER_TRACES_BOOT_TIMEOUT_SECS:-240}"
WAIT_BOOT_COMPLETED=1
CHANNEL_STATUS_TSV=""
CHANNEL_DIR=""
MATCH_DIR=""
META_DIR=""
serial=""
live_boot_id=""
live_slot_suffix=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_recover_traces.sh [--output DIR] [--adb-timeout SECONDS]
                                                [--boot-timeout SECONDS]
                                                [--no-wait-boot-completed] [--dry-run]

Collect best-effort Android-side evidence after a boot-lab run has already returned
to stock Android. This private helper is intended to sit behind:
  sc -t <serial> debug boot-lab-recover-traces
EOF
}

recovery_runs_dir() {
  printf '%s/%s\n' "$(pixel_boot_dir)" "$RECOVERY_ROOT_NAME"
}

resolve_serial_for_mode() {
  if [[ -n "${PIXEL_SERIAL:-}" ]]; then
    printf '%s\n' "$PIXEL_SERIAL"
    return 0
  fi

  pixel_resolve_serial
}

prepare_output_dir() {
  if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$(pixel_prepare_named_run_dir "$(recovery_runs_dir)")"
    return 0
  fi

  if [[ -e "$OUTPUT_DIR" ]] && find "$OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    echo "pixel_boot_recover_traces: output dir must be empty or absent: $OUTPUT_DIR" >&2
    exit 1
  fi

  mkdir -p "$OUTPUT_DIR"
}

shell_best_effort() {
  local output_path stderr_path status_path
  local available matched match_count channel_status recorded_command
  local name="$1"
  local scope="$2"
  local command="$3"
  output_path="$CHANNEL_DIR/$name.txt"
  stderr_path="$CHANNEL_DIR/$name.stderr.txt"
  status_path="$MATCH_DIR/$name.txt"

  set +e
  pixel_adb "$serial" shell "$command" >"$output_path" 2>"$stderr_path"
  channel_status="$?"
  set -e

  if grep -aE "$SHADOW_TAG_REGEX" "$output_path" >"$status_path"; then
    match_count="$(wc -l <"$status_path" | tr -d '[:space:]')"
    matched=true
  else
    : >"$status_path"
    match_count=0
    matched=false
  fi

  available=false
  if [[ "$channel_status" -eq 0 ]]; then
    available=true
  fi

  recorded_command="${command//$'\n'/\\n}"
  recorded_command="${recorded_command//$'\t'/\\t}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" \
    "$scope" \
    "$recorded_command" \
    "channels/$name.txt" \
    "channels/$name.stderr.txt" \
    "$channel_status" \
    "$available" \
    "$matched" \
    "$match_count" \
    "matches/$name.txt" >>"$CHANNEL_STATUS_TSV"
}

capture_current_boot_state() {
  live_boot_id="$(
    pixel_adb "$serial" shell "cat /proc/sys/kernel/random/boot_id 2>/dev/null" 2>/dev/null | tr -d '\r\n'
  )"
  live_slot_suffix="$(pixel_prop "$serial" ro.boot.slot_suffix | tr -d '\r\n')"

  cat >"$META_DIR/live-boot-state.txt" <<EOF
serial=$serial
live_boot_id=$live_boot_id
live_slot_suffix=$live_slot_suffix
EOF
}

write_bootreason_summary() {
  python3 - "$CHANNEL_DIR/bootreason-props.txt" "$META_DIR/bootreason-props-summary.txt" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
keys = [
    "ro.boot.bootreason",
    "sys.boot.reason",
    "sys.boot.reason.last",
    "persist.sys.boot.reason.history",
    "ro.boot.bootreason_history",
    "ro.boot.bootreason_last",
]

values = {}
for raw_line in source.read_text(encoding="utf-8", errors="replace").splitlines():
    if "=" not in raw_line:
        continue
    key, value = raw_line.split("=", 1)
    values[key] = value

with target.open("w", encoding="utf-8") as fh:
    for key in keys:
        fh.write(f"{key}={values.get(key, '')}\n")
PY
}

write_all_matches() {
  python3 - "$CHANNEL_STATUS_TSV" "$OUTPUT_DIR/matches/all-shadow-tags.txt" <<'PY'
import csv
import sys
from pathlib import Path

status_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])

with status_path.open("r", encoding="utf-8") as fh:
    rows = list(csv.DictReader(fh, delimiter="\t"))

with output_path.open("w", encoding="utf-8") as fh:
    for row in rows:
        match_path = status_path.parent / row["matches_path"]
        text = match_path.read_text(encoding="utf-8", errors="replace")
        if not text.strip():
            continue
        fh.write(f"== {row['name']} ==\n")
        fh.write(text)
        if not text.endswith("\n"):
            fh.write("\n")
PY
}

write_status_json() {
  python3 - "$OUTPUT_DIR/status.json" "$CHANNEL_STATUS_TSV" "$live_boot_id" "$live_slot_suffix" "$serial" "$SHADOW_TAG_REGEX" "$WAIT_BOOT_COMPLETED" <<'PY'
import csv
import json
import sys
from pathlib import Path

status_output = Path(sys.argv[1])
channel_status_path = Path(sys.argv[2])
live_boot_id = sys.argv[3]
live_slot_suffix = sys.argv[4]
serial = sys.argv[5]
shadow_tag_regex = sys.argv[6]
wait_boot_completed = sys.argv[7] == "1"

rows = []
previous_boot_matches = 0
current_boot_matches = 0
previous_boot_attempts = 0
current_boot_attempts = 0
channels_with_matches = 0
bootreason_values = {}

with channel_status_path.open("r", encoding="utf-8") as fh:
    for row in csv.DictReader(fh, delimiter="\t"):
        output_path = channel_status_path.parent / row["output_path"]
        stderr_path = channel_status_path.parent / row["stderr_path"]
        matches_path = channel_status_path.parent / row["matches_path"]
        matched = row["matched"] == "true"
        available = row["available"] == "true"
        entry = {
            "scope": row["scope"],
            "command": row["command"],
            "attempted": True,
            "exit_code": int(row["exit_code"]),
            "available": available,
            "matched_shadow_tags": matched,
            "match_count": int(row["match_count"]),
            "output_path": row["output_path"],
            "stderr_path": row["stderr_path"],
            "matches_path": row["matches_path"],
            "output_bytes": output_path.stat().st_size if output_path.exists() else 0,
            "stderr_bytes": stderr_path.stat().st_size if stderr_path.exists() else 0,
            "matches_bytes": matches_path.stat().st_size if matches_path.exists() else 0,
        }
        rows.append((row["name"], entry))
        if row["scope"] == "previous-boot":
            previous_boot_attempts += 1
            if matched:
                previous_boot_matches += 1
        else:
            current_boot_attempts += 1
            if matched:
                current_boot_matches += 1
        if matched:
            channels_with_matches += 1

bootreason_path = channel_status_path.parent / "channels/bootreason-props.txt"
if bootreason_path.exists():
    for raw_line in bootreason_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        bootreason_values[key] = value

payload = {
    "kind": "boot_trace_recovery",
    "ok": True,
    "serial": serial,
    "output_dir": str(status_output.parent),
    "shadow_tag_regex": shadow_tag_regex,
    "live_boot_id": live_boot_id,
    "live_slot_suffix": live_slot_suffix,
    "wait_boot_completed": wait_boot_completed,
    "previous_boot_channel_attempts": previous_boot_attempts,
    "previous_boot_channels_with_matches": previous_boot_matches,
    "current_boot_channel_attempts": current_boot_attempts,
    "current_boot_channels_with_matches": current_boot_matches,
    "matched_any_shadow_tags": channels_with_matches > 0,
    "recovered_previous_boot_traces": previous_boot_matches > 0,
    "channels": {name: entry for name, entry in rows},
    "bootreason_props": bootreason_values,
}

with status_output.open("w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_DIR="${2:?missing value for --output}"
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
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "pixel_boot_recover_traces: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$DRY_RUN" == "1" ]]; then
  serial="${PIXEL_SERIAL:-pixel}"
  if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$(recovery_runs_dir)/$(pixel_timestamp)"
  fi
  printf 'serial=%s\n' "$serial"
  printf 'command=%s\n' "$0"
  printf 'output=%s\n' "$OUTPUT_DIR"
  printf 'adb_timeout_secs=%s\n' "$ADB_TIMEOUT_SECS"
  printf 'boot_timeout_secs=%s\n' "$BOOT_TIMEOUT_SECS"
  printf 'wait_boot_completed=%s\n' "$( [[ "$WAIT_BOOT_COMPLETED" == "1" ]] && printf true || printf false )"
  exit 0
fi

serial="$(resolve_serial_for_mode)"
pixel_require_host_lock "$serial" "$0" "${ORIGINAL_ARGS[@]}"
pixel_prepare_dirs
prepare_output_dir

pixel_wait_for_adb "$serial" "$ADB_TIMEOUT_SECS" >/dev/null
if [[ "$WAIT_BOOT_COMPLETED" == "1" ]]; then
  pixel_wait_for_boot_completed "$serial" "$BOOT_TIMEOUT_SECS" >/dev/null
fi

CHANNEL_DIR="$OUTPUT_DIR/channels"
MATCH_DIR="$OUTPUT_DIR/matches"
META_DIR="$OUTPUT_DIR/meta"
mkdir -p "$CHANNEL_DIR" "$MATCH_DIR" "$META_DIR"
CHANNEL_STATUS_TSV="$OUTPUT_DIR/channel-status.tsv"
printf 'name\tscope\tcommand\toutput_path\tstderr_path\texit_code\tavailable\tmatched\tmatch_count\tmatches_path\n' >"$CHANNEL_STATUS_TSV"
cat >"$META_DIR/shadow-tag-patterns.txt" <<EOF
shadow-hello-init
shadow-drm
shadow-owned-init-
EOF

capture_current_boot_state

shell_best_effort "logcat-last" "previous-boot" "logcat -L -d -v threadtime"
shell_best_effort "dropbox-system-boot" "previous-boot" "dumpsys dropbox --print SYSTEM_BOOT"
shell_best_effort "pmsg0" "previous-boot" "cat /dev/pmsg0"
shell_best_effort "bootreason-props" "current-boot" $'for key in ro.boot.bootreason sys.boot.reason sys.boot.reason.last persist.sys.boot.reason.history ro.boot.bootreason_history ro.boot.bootreason_last; do\n  printf "%s=%s\\n" "$key" "$(getprop "$key" | tr -d "\\r")"\ndone'
shell_best_effort "getprop" "current-boot" "getprop"
shell_best_effort "logcat-current" "current-boot" "logcat -d -v threadtime"
shell_best_effort "logcat-kernel-current" "current-boot" "logcat -b kernel -d -v threadtime"

write_bootreason_summary
write_all_matches
write_status_json

printf 'Recovered boot traces: %s\n' "$OUTPUT_DIR"
printf 'Serial: %s\n' "$serial"
printf 'Live boot id: %s\n' "${live_boot_id:-unknown}"
printf 'Live slot suffix: %s\n' "${live_slot_suffix:-unknown}"
