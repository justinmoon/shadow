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
ROOT_AVAILABLE=0
ROOT_ID=""
EXPECTED_RUN_TOKEN="${PIXEL_HELLO_INIT_RUN_TOKEN:-}"
EXPECTED_RUN_TOKEN_SOURCE=""
SOURCE_IMAGE_PATH=""
SOURCE_IMAGE_METADATA_PATH=""
IMAGE_METADATA_SUFFIX=".hello-init.json"

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

hello_init_metadata_path() {
  local image_path
  image_path="${1:?hello_init_metadata_path requires an image path}"
  printf '%s%s\n' "$image_path" "$IMAGE_METADATA_SUFFIX"
}

discover_source_image_path() {
  local parent_status
  parent_status="$OUTPUT_DIR/../status.json"

  if [[ ! -f "$parent_status" ]]; then
    return 0
  fi

  SOURCE_IMAGE_PATH="$(
    python3 - "$parent_status" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

image = payload.get("image", "")
print(image if isinstance(image, str) else "")
PY
  )"
}

load_run_token_from_metadata() {
  local metadata_path
  metadata_path="${1:?load_run_token_from_metadata requires a metadata path}"

  if [[ ! -f "$metadata_path" ]]; then
    return 0
  fi

  python3 - "$metadata_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

token = payload.get("run_token", "")
print(token if isinstance(token, str) else "")
PY
}

discover_expected_run_token() {
  local metadata_token=""

  discover_source_image_path
  if [[ -n "$SOURCE_IMAGE_PATH" ]]; then
    SOURCE_IMAGE_METADATA_PATH="$(hello_init_metadata_path "$SOURCE_IMAGE_PATH")"
    metadata_token="$(load_run_token_from_metadata "$SOURCE_IMAGE_METADATA_PATH")"
  fi

  if [[ -n "$EXPECTED_RUN_TOKEN" ]]; then
    EXPECTED_RUN_TOKEN_SOURCE="env:PIXEL_HELLO_INIT_RUN_TOKEN"
    return 0
  fi

  if [[ -n "$metadata_token" ]]; then
    EXPECTED_RUN_TOKEN="$metadata_token"
    EXPECTED_RUN_TOKEN_SOURCE="image-metadata"
    return 0
  fi

  EXPECTED_RUN_TOKEN_SOURCE="unavailable"
}

write_expected_run_token_summary() {
  cat >"$META_DIR/expected-run-token.txt" <<EOF
expected_run_token=$EXPECTED_RUN_TOKEN
expected_run_token_present=$( [[ -n "$EXPECTED_RUN_TOKEN" ]] && printf true || printf false )
expected_run_token_source=$EXPECTED_RUN_TOKEN_SOURCE
source_image_path=$SOURCE_IMAGE_PATH
source_image_metadata_path=$SOURCE_IMAGE_METADATA_PATH
EOF
}

detect_root_state() {
  local root_id

  root_id="$(pixel_root_id "$serial" 2>/dev/null || true)"
  if [[ -n "$root_id" ]]; then
    ROOT_AVAILABLE=1
    ROOT_ID="$root_id"
    return 0
  fi

  ROOT_AVAILABLE=0
  ROOT_ID=""
}

write_root_state_summary() {
  cat >"$META_DIR/root-state.txt" <<EOF
root_available=$( [[ "$ROOT_AVAILABLE" == "1" ]] && printf true || printf false )
root_id=$ROOT_ID
EOF
}

run_device_command() {
  local access_mode="$1"
  local command="$2"
  local output_path="$3"
  local stderr_path="$4"
  local exit_code actual_access_mode

  case "$access_mode" in
    adb)
      set +e
      pixel_adb "$serial" shell "$command" >"$output_path" 2>"$stderr_path"
      exit_code="$?"
      set -e
      actual_access_mode="adb"
      ;;
    root)
      if [[ "$ROOT_AVAILABLE" != "1" ]]; then
        : >"$output_path"
        printf 'root unavailable for privileged collection\n' >"$stderr_path"
        exit_code=125
        actual_access_mode="root-unavailable"
      else
        set +e
        pixel_root_shell "$serial" "$command" >"$output_path" 2>"$stderr_path"
        exit_code="$?"
        set -e
        actual_access_mode="root"
      fi
      ;;
    *)
      echo "pixel_boot_recover_traces: unsupported access mode: $access_mode" >&2
      exit 1
      ;;
  esac

  printf '%s\t%s\n' "$exit_code" "$actual_access_mode"
}

shell_best_effort() {
  local output_path stderr_path status_path run_token_status_path
  local available matched matched_run_token correlated
  local match_count run_token_match_count channel_status recorded_command correlation_state
  local actual_access_mode run_result
  local name="$1"
  local scope="$2"
  local requested_access_mode="$3"
  local command="$4"
  output_path="$CHANNEL_DIR/$name.txt"
  stderr_path="$CHANNEL_DIR/$name.stderr.txt"
  status_path="$MATCH_DIR/$name.shadow-tags.txt"
  run_token_status_path="$MATCH_DIR/$name.run-token.txt"

  run_result="$(run_device_command "$requested_access_mode" "$command" "$output_path" "$stderr_path")"
  channel_status="${run_result%%$'\t'*}"
  actual_access_mode="${run_result#*$'\t'}"

  if grep -aE "$SHADOW_TAG_REGEX" "$output_path" >"$status_path"; then
    match_count="$(wc -l <"$status_path" | tr -d '[:space:]')"
    matched=true
  else
    : >"$status_path"
    match_count=0
    matched=false
  fi

  if [[ -n "$EXPECTED_RUN_TOKEN" ]] && grep -aF "$EXPECTED_RUN_TOKEN" "$output_path" >"$run_token_status_path"; then
    run_token_match_count="$(wc -l <"$run_token_status_path" | tr -d '[:space:]')"
    matched_run_token=true
  else
    : >"$run_token_status_path"
    run_token_match_count=0
    matched_run_token=false
  fi

  correlated=false
  if [[ "$matched" == "true" && "$matched_run_token" == "true" ]]; then
    correlated=true
    correlation_state="correlated"
  elif [[ "$matched_run_token" == "true" ]]; then
    correlation_state="token-only"
  elif [[ "$matched" == "true" ]]; then
    correlation_state="shadow-hint-only"
  else
    correlation_state="none"
  fi

  available=false
  if [[ "$channel_status" -eq 0 ]]; then
    available=true
  fi

  recorded_command="${command//$'\n'/\\n}"
  recorded_command="${recorded_command//$'\t'/\\t}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" \
    "$scope" \
    "$recorded_command" \
    "$requested_access_mode" \
    "$actual_access_mode" \
    "channels/$name.txt" \
    "channels/$name.stderr.txt" \
    "$channel_status" \
    "$available" \
    "$matched" \
    "$match_count" \
    "$matched_run_token" \
    "$run_token_match_count" \
    "$correlated" \
    "$correlation_state" \
    "matches/$name.shadow-tags.txt" \
    "matches/$name.run-token.txt" >>"$CHANNEL_STATUS_TSV"
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
        fh.write(
            f"== {row['name']} scope={row['scope']} correlation_state={row['correlation_state']} access={row['actual_access_mode']} ==\n"
        )
        fh.write(text)
        if not text.endswith("\n"):
            fh.write("\n")
PY
}

write_all_run_token_matches() {
  python3 - "$CHANNEL_STATUS_TSV" "$OUTPUT_DIR/matches/all-run-token-matches.txt" <<'PY'
import csv
import sys
from pathlib import Path

status_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])

with status_path.open("r", encoding="utf-8") as fh:
    rows = list(csv.DictReader(fh, delimiter="\t"))

with output_path.open("w", encoding="utf-8") as fh:
    for row in rows:
        match_path = status_path.parent / row["run_token_matches_path"]
        text = match_path.read_text(encoding="utf-8", errors="replace")
        if not text.strip():
            continue
        fh.write(
            f"== {row['name']} scope={row['scope']} correlation_state={row['correlation_state']} access={row['actual_access_mode']} ==\n"
        )
        fh.write(text)
        if not text.endswith("\n"):
            fh.write("\n")
PY
}

write_status_json() {
  python3 - \
    "$OUTPUT_DIR/status.json" \
    "$CHANNEL_STATUS_TSV" \
    "$live_boot_id" \
    "$live_slot_suffix" \
    "$serial" \
    "$SHADOW_TAG_REGEX" \
    "$WAIT_BOOT_COMPLETED" \
    "$EXPECTED_RUN_TOKEN" \
    "$EXPECTED_RUN_TOKEN_SOURCE" \
    "$SOURCE_IMAGE_PATH" \
    "$SOURCE_IMAGE_METADATA_PATH" \
    "$ROOT_AVAILABLE" \
    "$ROOT_ID" <<'PY'
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
expected_run_token = sys.argv[8]
expected_run_token_source = sys.argv[9]
source_image_path = sys.argv[10]
source_image_metadata_path = sys.argv[11]
root_available = sys.argv[12] == "1"
root_id = sys.argv[13]

rows = []
previous_boot_matches = 0
current_boot_matches = 0
previous_boot_attempts = 0
current_boot_attempts = 0
previous_boot_hint_matches = 0
current_boot_hint_matches = 0
matched_any_shadow_tags = False
matched_any_correlated_shadow_tags = False
matched_any_expected_run_token = False
matched_any_uncorrelated_shadow_tags = False
bootreason_values = {}

with channel_status_path.open("r", encoding="utf-8") as fh:
    for row in csv.DictReader(fh, delimiter="\t"):
        output_path = channel_status_path.parent / row["output_path"]
        stderr_path = channel_status_path.parent / row["stderr_path"]
        matches_path = channel_status_path.parent / row["matches_path"]
        run_token_matches_path = channel_status_path.parent / row["run_token_matches_path"]
        matched_shadow_tags = row["matched_shadow_tags"] == "true"
        matched_expected_run_token = row["matched_expected_run_token"] == "true"
        correlated = row["correlated"] == "true"
        available = row["available"] == "true"
        entry = {
            "scope": row["scope"],
            "command": row["command"],
            "attempted": True,
            "requested_access_mode": row["requested_access_mode"],
            "actual_access_mode": row["actual_access_mode"],
            "exit_code": int(row["exit_code"]),
            "available": available,
            "matched_shadow_tags": matched_shadow_tags,
            "match_count": int(row["shadow_match_count"]),
            "shadow_match_count": int(row["shadow_match_count"]),
            "matched_expected_run_token": matched_expected_run_token,
            "run_token_match_count": int(row["run_token_match_count"]),
            "correlated": correlated,
            "correlation_state": row["correlation_state"],
            "output_path": row["output_path"],
            "stderr_path": row["stderr_path"],
            "matches_path": row["matches_path"],
            "run_token_matches_path": row["run_token_matches_path"],
            "output_bytes": output_path.stat().st_size if output_path.exists() else 0,
            "stderr_bytes": stderr_path.stat().st_size if stderr_path.exists() else 0,
            "matches_bytes": matches_path.stat().st_size if matches_path.exists() else 0,
            "run_token_matches_bytes": (
                run_token_matches_path.stat().st_size if run_token_matches_path.exists() else 0
            ),
        }
        rows.append((row["name"], entry))
        if matched_shadow_tags:
            matched_any_shadow_tags = True
        if correlated:
            matched_any_correlated_shadow_tags = True
        if matched_expected_run_token:
            matched_any_expected_run_token = True
        if matched_shadow_tags and not correlated:
            matched_any_uncorrelated_shadow_tags = True
        if row["scope"] == "previous-boot":
            previous_boot_attempts += 1
            if correlated:
                previous_boot_matches += 1
            elif matched_shadow_tags:
                previous_boot_hint_matches += 1
        elif row["scope"] == "current-boot":
            current_boot_attempts += 1
            if correlated:
                current_boot_matches += 1
            elif matched_shadow_tags:
                current_boot_hint_matches += 1

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
    "expected_run_token": expected_run_token,
    "expected_run_token_source": expected_run_token_source,
    "expected_run_token_present": bool(expected_run_token),
    "source_image_path": source_image_path,
    "source_image_metadata_path": source_image_metadata_path,
    "live_boot_id": live_boot_id,
    "live_slot_suffix": live_slot_suffix,
    "root_available": root_available,
    "root_id": root_id,
    "wait_boot_completed": wait_boot_completed,
    "previous_boot_channel_attempts": previous_boot_attempts,
    "previous_boot_channels_with_matches": previous_boot_matches,
    "current_boot_channel_attempts": current_boot_attempts,
    "current_boot_channels_with_matches": current_boot_matches,
    "previous_boot_channels_with_shadow_hints": previous_boot_hint_matches,
    "current_boot_channels_with_shadow_hints": current_boot_hint_matches,
    "uncorrelated_previous_boot_channel_attempts": previous_boot_attempts,
    "uncorrelated_previous_boot_channels_with_matches": previous_boot_hint_matches,
    "matched_any_shadow_tags": matched_any_shadow_tags,
    "matched_any_correlated_shadow_tags": matched_any_correlated_shadow_tags,
    "matched_any_expected_run_token": matched_any_expected_run_token,
    "matched_any_uncorrelated_shadow_tags": matched_any_uncorrelated_shadow_tags,
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
discover_expected_run_token
printf 'name\tscope\tcommand\trequested_access_mode\tactual_access_mode\toutput_path\tstderr_path\texit_code\tavailable\tmatched_shadow_tags\tshadow_match_count\tmatched_expected_run_token\trun_token_match_count\tcorrelated\tcorrelation_state\tmatches_path\trun_token_matches_path\n' >"$CHANNEL_STATUS_TSV"
cat >"$META_DIR/shadow-tag-patterns.txt" <<EOF
shadow-hello-init
shadow-drm
shadow-owned-init-
EOF

capture_current_boot_state
detect_root_state
write_expected_run_token_summary
write_root_state_summary

shell_best_effort "logcat-last" "previous-boot" "adb" "logcat -L -d -v threadtime"
shell_best_effort "dropbox-system-boot" "previous-boot" "adb" "dumpsys dropbox --print SYSTEM_BOOT"
shell_best_effort "dropbox-system-last-kmsg" "previous-boot" "adb" "dumpsys dropbox --print SYSTEM_LAST_KMSG"
shell_best_effort "pmsg0" "previous-boot" "root" "cat /dev/pmsg0"
shell_best_effort "pstore" "previous-boot" "root" $'if [ ! -d /sys/fs/pstore ]; then\n  echo "missing /sys/fs/pstore" >&2\n  exit 1\nfi\nfound=0\nfor path in /sys/fs/pstore/*; do\n  [ -e "$path" ] || continue\n  found=1\n  printf "== %s ==\\n" "$path"\n  cat "$path"\n  printf "\\n"\ndone\nif [ "$found" -ne 1 ]; then\n  printf "no pstore entries\\n"\nfi'
shell_best_effort "bootreason-props" "current-boot" "adb" $'for key in ro.boot.bootreason sys.boot.reason sys.boot.reason.last persist.sys.boot.reason.history ro.boot.bootreason_history ro.boot.bootreason_last; do\n  printf "%s=%s\\n" "$key" "$(getprop "$key" | tr -d "\\r")"\ndone'
shell_best_effort "getprop" "current-boot" "adb" "getprop"
shell_best_effort "logcat-current" "current-boot" "adb" "logcat -d -v threadtime"
shell_best_effort "logcat-kernel-current" "current-boot" "adb" "logcat -b kernel -d -v threadtime"

write_bootreason_summary
write_all_matches
write_all_run_token_matches
write_status_json

printf 'Recovered boot traces: %s\n' "$OUTPUT_DIR"
printf 'Serial: %s\n' "$serial"
printf 'Live boot id: %s\n' "${live_boot_id:-unknown}"
printf 'Live slot suffix: %s\n' "${live_slot_suffix:-unknown}"
