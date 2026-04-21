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
AUTO_FASTBOOT_REBOOT="${PIXEL_BOOT_RECOVER_TRACES_AUTO_FASTBOOT_REBOOT:-1}"
CHANNEL_STATUS_TSV=""
CHANNEL_DIR=""
MATCH_DIR=""
META_DIR=""
status_path=""
serial=""
live_boot_id=""
live_slot_suffix=""
ROOT_AVAILABLE=0
ROOT_ID=""
EXPECTED_RUN_TOKEN="${PIXEL_HELLO_INIT_RUN_TOKEN:-}"
EXPECTED_RUN_TOKEN_SOURCE=""
SOURCE_IMAGE_PATH_OVERRIDE="${PIXEL_HELLO_INIT_SOURCE_IMAGE_PATH:-}"
SOURCE_IMAGE_PATH=""
SOURCE_IMAGE_METADATA_PATH=""
IMAGE_METADATA_SUFFIX=".hello-init.json"
EXPECTED_METADATA_STAGE_BREADCRUMB=false
EXPECTED_METADATA_STAGE_PATH=""
EXPECTED_METADATA_PROBE_STAGE_PATH=""
EXPECTED_METADATA_PROBE_FINGERPRINT_PATH=""
RECOVERED_METADATA_STAGE_PRESENT=false
RECOVERED_METADATA_STAGE_VALUE=""
RECOVERED_METADATA_STAGE_ACTUAL_ACCESS_MODE="unattempted"
RECOVERED_METADATA_STAGE_EXIT_CODE=""
RECOVERED_METADATA_STAGE_OUTPUT_PATH=""
RECOVERED_METADATA_STAGE_STDERR_PATH=""
RECOVERED_METADATA_PROBE_STAGE_PRESENT=false
RECOVERED_METADATA_PROBE_STAGE_VALUE=""
RECOVERED_METADATA_PROBE_STAGE_ACTUAL_ACCESS_MODE="unattempted"
RECOVERED_METADATA_PROBE_STAGE_EXIT_CODE=""
RECOVERED_METADATA_PROBE_STAGE_OUTPUT_PATH=""
RECOVERED_METADATA_PROBE_STAGE_STDERR_PATH=""
RECOVERED_METADATA_PROBE_FINGERPRINT_PRESENT=false
RECOVERED_METADATA_PROBE_FINGERPRINT_ACTUAL_ACCESS_MODE="unattempted"
RECOVERED_METADATA_PROBE_FINGERPRINT_EXIT_CODE=""
RECOVERED_METADATA_PROBE_FINGERPRINT_OUTPUT_PATH=""
RECOVERED_METADATA_PROBE_FINGERPRINT_STDERR_PATH=""
failure_stage=""
transport_timeline_path="${PIXEL_BOOT_TRANSPORT_TIMELINE_PATH:-}"
transport_timeline_elapsed_offset_secs="${PIXEL_BOOT_TRANSPORT_TIMELINE_ELAPSED_OFFSET_SECS:-0}"
transport_timeline_last_recorded_state_seed="${PIXEL_BOOT_TRANSPORT_TIMELINE_LAST_RECORDED_STATE:-}"
transport_left_fastboot_seed="${PIXEL_BOOT_TRANSPORT_TIMELINE_LEFT_FASTBOOT:-false}"
transport_initial_state=""
transport_first_none_elapsed_secs=""
transport_first_fastboot_elapsed_secs=""
transport_first_adb_elapsed_secs=""
transport_last_state=""
transport_last_state_elapsed_secs=""
fastboot_auto_reboot_attempted=false
fastboot_auto_reboot_succeeded=false
fastboot_auto_reboot_elapsed_secs=""
fastboot_auto_reboot_reason=""

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

bool_word() {
  if [[ "$1" == "1" || "$1" == "true" ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

flag_enabled() {
  [[ "$(bool_word "$1")" == "true" ]]
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

write_failure_status_json() {
  [[ -n "$status_path" ]] || return 0

  python3 - \
    "$status_path" \
    "$serial" \
    "$OUTPUT_DIR" \
    "$ADB_TIMEOUT_SECS" \
    "$BOOT_TIMEOUT_SECS" \
    "$(bool_word "$WAIT_BOOT_COMPLETED")" \
    "$failure_stage" \
    "$transport_timeline_path" \
    "$transport_initial_state" \
    "$transport_first_none_elapsed_secs" \
    "$transport_first_fastboot_elapsed_secs" \
    "$transport_first_adb_elapsed_secs" \
    "$transport_last_state" \
    "$transport_last_state_elapsed_secs" \
    "$(bool_word "$fastboot_auto_reboot_attempted")" \
    "$(bool_word "$fastboot_auto_reboot_succeeded")" \
    "$fastboot_auto_reboot_elapsed_secs" \
    "$fastboot_auto_reboot_reason" \
    "$EXPECTED_RUN_TOKEN" \
    "$EXPECTED_RUN_TOKEN_SOURCE" \
    "$SOURCE_IMAGE_PATH" \
    "$SOURCE_IMAGE_METADATA_PATH" \
    "$EXPECTED_METADATA_STAGE_BREADCRUMB" \
    "$EXPECTED_METADATA_STAGE_PATH" \
    "$EXPECTED_METADATA_PROBE_STAGE_PATH" \
    "$RECOVERED_METADATA_STAGE_PRESENT" \
    "$RECOVERED_METADATA_STAGE_VALUE" \
    "$RECOVERED_METADATA_STAGE_ACTUAL_ACCESS_MODE" \
    "$RECOVERED_METADATA_STAGE_EXIT_CODE" <<'PY'
import json
import sys
from pathlib import Path

(
    status_output,
    serial,
    output_dir,
    adb_timeout_secs,
    boot_timeout_secs,
    wait_boot_completed,
    failure_stage,
    transport_timeline_path,
    transport_initial_state,
    transport_first_none_elapsed_secs,
    transport_first_fastboot_elapsed_secs,
    transport_first_adb_elapsed_secs,
    transport_last_state,
    transport_last_state_elapsed_secs,
    fastboot_auto_reboot_attempted,
    fastboot_auto_reboot_succeeded,
    fastboot_auto_reboot_elapsed_secs,
    fastboot_auto_reboot_reason,
    expected_run_token,
    expected_run_token_source,
    source_image_path,
    source_image_metadata_path,
    expected_metadata_stage_breadcrumb,
    expected_metadata_stage_path,
    expected_metadata_probe_stage_path,
    recovered_metadata_stage_present,
    recovered_metadata_stage_value,
    recovered_metadata_stage_actual_access_mode,
    recovered_metadata_stage_exit_code,
) = sys.argv[1:30]

expected_durable_logging = {"kmsg": None, "pmsg": None}
if source_image_metadata_path:
    metadata_path = Path(source_image_metadata_path)
    if metadata_path.exists():
        try:
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            metadata = {}
        for source_key, target_key in (("log_kmsg", "kmsg"), ("log_pmsg", "pmsg")):
            value = metadata.get(source_key)
            if isinstance(value, bool):
                expected_durable_logging[target_key] = value

payload = {
    "kind": "boot_trace_recovery",
    "ok": False,
    "proof_ok": False,
    "matched_correlated_trace": False,
    "serial": serial,
    "output_dir": output_dir,
    "adb_timeout_secs": int(adb_timeout_secs),
    "boot_timeout_secs": int(boot_timeout_secs),
    "wait_boot_completed": wait_boot_completed == "true",
    "failure_stage": failure_stage,
    "transport_timeline_path": transport_timeline_path,
    "transport_initial_state": transport_initial_state,
    "transport_first_none_elapsed_secs": transport_first_none_elapsed_secs,
    "transport_first_fastboot_elapsed_secs": transport_first_fastboot_elapsed_secs,
    "transport_first_adb_elapsed_secs": transport_first_adb_elapsed_secs,
    "transport_last_state": transport_last_state,
    "transport_last_state_elapsed_secs": transport_last_state_elapsed_secs,
    "fastboot_auto_reboot_attempted": fastboot_auto_reboot_attempted == "true",
    "fastboot_auto_reboot_succeeded": fastboot_auto_reboot_succeeded == "true",
    "fastboot_auto_reboot_elapsed_secs": fastboot_auto_reboot_elapsed_secs,
    "fastboot_auto_reboot_reason": fastboot_auto_reboot_reason,
    "expected_run_token": expected_run_token,
    "expected_run_token_source": expected_run_token_source,
    "expected_run_token_present": bool(expected_run_token),
    "expected_durable_logging": expected_durable_logging,
    "expected_durable_logging_summary": ",".join(
        f"{key}={str(value).lower()}" for key, value in expected_durable_logging.items()
    ),
    "source_image_path": source_image_path,
    "source_image_metadata_path": source_image_metadata_path,
    "expected_metadata_stage_breadcrumb": expected_metadata_stage_breadcrumb == "true",
    "expected_metadata_stage_path": expected_metadata_stage_path,
    "expected_metadata_probe_stage_path": expected_metadata_probe_stage_path,
    "metadata_stage_present": recovered_metadata_stage_present == "true",
    "metadata_stage_value": recovered_metadata_stage_value,
    "metadata_stage_actual_access_mode": recovered_metadata_stage_actual_access_mode,
    "metadata_stage_exit_code": (
        int(recovered_metadata_stage_exit_code)
        if recovered_metadata_stage_exit_code not in ("", None)
        else None
    ),
}

with open(status_output, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

finish() {
  local exit_code=$?
  trap - EXIT
  if [[ "$exit_code" -ne 0 ]]; then
    write_failure_status_json
  fi
  exit "$exit_code"
}

hello_init_metadata_path() {
  local image_path
  image_path="${1:?hello_init_metadata_path requires an image path}"
  printf '%s%s\n' "$image_path" "$IMAGE_METADATA_SUFFIX"
}

discover_source_image_path() {
  local parent_status

  if [[ -n "$SOURCE_IMAGE_PATH_OVERRIDE" ]]; then
    SOURCE_IMAGE_PATH="$SOURCE_IMAGE_PATH_OVERRIDE"
    return 0
  fi

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

load_recovery_metadata_values() {
  local metadata_path
  metadata_path="${1:?load_recovery_metadata_values requires a metadata path}"

  if [[ ! -f "$metadata_path" ]]; then
    return 0
  fi

  python3 - "$metadata_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

token = payload.get("run_token", "")
enabled = payload.get("orange_gpu_metadata_stage_breadcrumb", False)
stage_path = payload.get("metadata_stage_path", "")
probe_stage_path = payload.get("metadata_probe_stage_path", "")
probe_fingerprint_path = payload.get("metadata_probe_fingerprint_path", "")

print(token if isinstance(token, str) else "")
print("true" if enabled is True else "false")
print(stage_path if isinstance(stage_path, str) else "")
print(probe_stage_path if isinstance(probe_stage_path, str) else "")
print(probe_fingerprint_path if isinstance(probe_fingerprint_path, str) else "")
PY
}

discover_expected_run_token() {
  local metadata_values=()
  local metadata_token=""
  local metadata_stage_enabled=""
  local metadata_stage_path=""
  local metadata_probe_stage_path=""
  local metadata_probe_fingerprint_path=""

  discover_source_image_path
  if [[ -n "$SOURCE_IMAGE_PATH" ]]; then
    SOURCE_IMAGE_METADATA_PATH="$(hello_init_metadata_path "$SOURCE_IMAGE_PATH")"
    mapfile -t metadata_values < <(load_recovery_metadata_values "$SOURCE_IMAGE_METADATA_PATH")
    metadata_token="${metadata_values[0]:-}"
    metadata_stage_enabled="${metadata_values[1]:-false}"
    metadata_stage_path="${metadata_values[2]:-}"
    metadata_probe_stage_path="${metadata_values[3]:-}"
    metadata_probe_fingerprint_path="${metadata_values[4]:-}"
    EXPECTED_METADATA_STAGE_BREADCRUMB="$metadata_stage_enabled"
    EXPECTED_METADATA_STAGE_PATH="$metadata_stage_path"
    EXPECTED_METADATA_PROBE_STAGE_PATH="$metadata_probe_stage_path"
    EXPECTED_METADATA_PROBE_FINGERPRINT_PATH="$metadata_probe_fingerprint_path"
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
expected_metadata_stage_breadcrumb=$EXPECTED_METADATA_STAGE_BREADCRUMB
expected_metadata_stage_path=$EXPECTED_METADATA_STAGE_PATH
expected_metadata_probe_stage_path=$EXPECTED_METADATA_PROBE_STAGE_PATH
expected_metadata_probe_fingerprint_path=$EXPECTED_METADATA_PROBE_FINGERPRINT_PATH
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

recover_metadata_stage_file() {
  local command run_result output_path stderr_path exit_code actual_access_mode

  output_path="$CHANNEL_DIR/metadata-stage.txt"
  stderr_path="$CHANNEL_DIR/metadata-stage.stderr.txt"
  RECOVERED_METADATA_STAGE_OUTPUT_PATH="channels/metadata-stage.txt"
  RECOVERED_METADATA_STAGE_STDERR_PATH="channels/metadata-stage.stderr.txt"

  : >"$output_path"
  : >"$stderr_path"

  if [[ "$EXPECTED_METADATA_STAGE_BREADCRUMB" != "true" || -z "$EXPECTED_METADATA_STAGE_PATH" ]]; then
    RECOVERED_METADATA_STAGE_PRESENT=false
    RECOVERED_METADATA_STAGE_VALUE=""
    RECOVERED_METADATA_STAGE_ACTUAL_ACCESS_MODE="unattempted"
    RECOVERED_METADATA_STAGE_EXIT_CODE=""
    cat >"$META_DIR/metadata-stage.txt" <<EOF
expected_metadata_stage_breadcrumb=$EXPECTED_METADATA_STAGE_BREADCRUMB
expected_metadata_stage_path=$EXPECTED_METADATA_STAGE_PATH
metadata_stage_present=false
metadata_stage_value=
metadata_stage_actual_access_mode=$RECOVERED_METADATA_STAGE_ACTUAL_ACCESS_MODE
metadata_stage_exit_code=
EOF
    return 0
  fi

  command="if [ -f $EXPECTED_METADATA_STAGE_PATH ]; then cat $EXPECTED_METADATA_STAGE_PATH; else exit 3; fi"
  run_result="$(run_device_command "root" "$command" "$output_path" "$stderr_path")"
  exit_code="${run_result%%$'\t'*}"
  actual_access_mode="${run_result#*$'\t'}"
  RECOVERED_METADATA_STAGE_ACTUAL_ACCESS_MODE="$actual_access_mode"
  RECOVERED_METADATA_STAGE_EXIT_CODE="$exit_code"

  if [[ "$exit_code" == "0" ]]; then
    RECOVERED_METADATA_STAGE_PRESENT=true
    RECOVERED_METADATA_STAGE_VALUE="$(
      python3 - "$output_path" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").strip())
PY
    )"
  else
    RECOVERED_METADATA_STAGE_PRESENT=false
    RECOVERED_METADATA_STAGE_VALUE=""
  fi

  cat >"$META_DIR/metadata-stage.txt" <<EOF
expected_metadata_stage_breadcrumb=$EXPECTED_METADATA_STAGE_BREADCRUMB
expected_metadata_stage_path=$EXPECTED_METADATA_STAGE_PATH
metadata_stage_present=$RECOVERED_METADATA_STAGE_PRESENT
metadata_stage_value=$RECOVERED_METADATA_STAGE_VALUE
metadata_stage_actual_access_mode=$RECOVERED_METADATA_STAGE_ACTUAL_ACCESS_MODE
metadata_stage_exit_code=$RECOVERED_METADATA_STAGE_EXIT_CODE
EOF
}

recover_metadata_probe_stage_file() {
  local command run_result output_path stderr_path exit_code actual_access_mode

  output_path="$CHANNEL_DIR/metadata-probe-stage.txt"
  stderr_path="$CHANNEL_DIR/metadata-probe-stage.stderr.txt"
  RECOVERED_METADATA_PROBE_STAGE_OUTPUT_PATH="channels/metadata-probe-stage.txt"
  RECOVERED_METADATA_PROBE_STAGE_STDERR_PATH="channels/metadata-probe-stage.stderr.txt"

  : >"$output_path"
  : >"$stderr_path"

  if [[ "$EXPECTED_METADATA_STAGE_BREADCRUMB" != "true" || -z "$EXPECTED_METADATA_PROBE_STAGE_PATH" ]]; then
    RECOVERED_METADATA_PROBE_STAGE_PRESENT=false
    RECOVERED_METADATA_PROBE_STAGE_VALUE=""
    RECOVERED_METADATA_PROBE_STAGE_ACTUAL_ACCESS_MODE="unattempted"
    RECOVERED_METADATA_PROBE_STAGE_EXIT_CODE=""
    cat >"$META_DIR/metadata-probe-stage.txt" <<EOF
expected_metadata_stage_breadcrumb=$EXPECTED_METADATA_STAGE_BREADCRUMB
expected_metadata_probe_stage_path=$EXPECTED_METADATA_PROBE_STAGE_PATH
metadata_probe_stage_present=false
metadata_probe_stage_value=
metadata_probe_stage_actual_access_mode=$RECOVERED_METADATA_PROBE_STAGE_ACTUAL_ACCESS_MODE
metadata_probe_stage_exit_code=
EOF
    return 0
  fi

  command="if [ -f $EXPECTED_METADATA_PROBE_STAGE_PATH ]; then cat $EXPECTED_METADATA_PROBE_STAGE_PATH; else exit 3; fi"
  run_result="$(run_device_command "root" "$command" "$output_path" "$stderr_path")"
  exit_code="${run_result%%$'\t'*}"
  actual_access_mode="${run_result#*$'\t'}"
  RECOVERED_METADATA_PROBE_STAGE_ACTUAL_ACCESS_MODE="$actual_access_mode"
  RECOVERED_METADATA_PROBE_STAGE_EXIT_CODE="$exit_code"

  if [[ "$exit_code" == "0" ]]; then
    RECOVERED_METADATA_PROBE_STAGE_PRESENT=true
    RECOVERED_METADATA_PROBE_STAGE_VALUE="$(
      python3 - "$output_path" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").strip())
PY
    )"
  else
    RECOVERED_METADATA_PROBE_STAGE_PRESENT=false
    RECOVERED_METADATA_PROBE_STAGE_VALUE=""
  fi

  cat >"$META_DIR/metadata-probe-stage.txt" <<EOF
expected_metadata_stage_breadcrumb=$EXPECTED_METADATA_STAGE_BREADCRUMB
expected_metadata_probe_stage_path=$EXPECTED_METADATA_PROBE_STAGE_PATH
metadata_probe_stage_present=$RECOVERED_METADATA_PROBE_STAGE_PRESENT
metadata_probe_stage_value=$RECOVERED_METADATA_PROBE_STAGE_VALUE
metadata_probe_stage_actual_access_mode=$RECOVERED_METADATA_PROBE_STAGE_ACTUAL_ACCESS_MODE
metadata_probe_stage_exit_code=$RECOVERED_METADATA_PROBE_STAGE_EXIT_CODE
EOF
}

recover_metadata_probe_fingerprint_file() {
  local command run_result output_path stderr_path exit_code actual_access_mode

  output_path="$CHANNEL_DIR/metadata-probe-fingerprint.txt"
  stderr_path="$CHANNEL_DIR/metadata-probe-fingerprint.stderr.txt"
  RECOVERED_METADATA_PROBE_FINGERPRINT_OUTPUT_PATH="channels/metadata-probe-fingerprint.txt"
  RECOVERED_METADATA_PROBE_FINGERPRINT_STDERR_PATH="channels/metadata-probe-fingerprint.stderr.txt"

  : >"$output_path"
  : >"$stderr_path"

  if [[ "$EXPECTED_METADATA_STAGE_BREADCRUMB" != "true" || -z "$EXPECTED_METADATA_PROBE_FINGERPRINT_PATH" ]]; then
    RECOVERED_METADATA_PROBE_FINGERPRINT_PRESENT=false
    RECOVERED_METADATA_PROBE_FINGERPRINT_ACTUAL_ACCESS_MODE="unattempted"
    RECOVERED_METADATA_PROBE_FINGERPRINT_EXIT_CODE=""
    cat >"$META_DIR/metadata-probe-fingerprint.txt" <<EOF
expected_metadata_stage_breadcrumb=$EXPECTED_METADATA_STAGE_BREADCRUMB
expected_metadata_probe_fingerprint_path=$EXPECTED_METADATA_PROBE_FINGERPRINT_PATH
metadata_probe_fingerprint_present=false
metadata_probe_fingerprint_actual_access_mode=$RECOVERED_METADATA_PROBE_FINGERPRINT_ACTUAL_ACCESS_MODE
metadata_probe_fingerprint_exit_code=
EOF
    return 0
  fi

  command="if [ -f $EXPECTED_METADATA_PROBE_FINGERPRINT_PATH ]; then cat $EXPECTED_METADATA_PROBE_FINGERPRINT_PATH; else exit 3; fi"
  run_result="$(run_device_command "root" "$command" "$output_path" "$stderr_path")"
  exit_code="${run_result%%$'\t'*}"
  actual_access_mode="${run_result#*$'\t'}"
  RECOVERED_METADATA_PROBE_FINGERPRINT_ACTUAL_ACCESS_MODE="$actual_access_mode"
  RECOVERED_METADATA_PROBE_FINGERPRINT_EXIT_CODE="$exit_code"

  if [[ "$exit_code" == "0" ]]; then
    RECOVERED_METADATA_PROBE_FINGERPRINT_PRESENT=true
  else
    RECOVERED_METADATA_PROBE_FINGERPRINT_PRESENT=false
  fi

  cat >"$META_DIR/metadata-probe-fingerprint.txt" <<EOF
expected_metadata_stage_breadcrumb=$EXPECTED_METADATA_STAGE_BREADCRUMB
expected_metadata_probe_fingerprint_path=$EXPECTED_METADATA_PROBE_FINGERPRINT_PATH
metadata_probe_fingerprint_present=$RECOVERED_METADATA_PROBE_FINGERPRINT_PRESENT
metadata_probe_fingerprint_actual_access_mode=$RECOVERED_METADATA_PROBE_FINGERPRINT_ACTUAL_ACCESS_MODE
metadata_probe_fingerprint_exit_code=$RECOVERED_METADATA_PROBE_FINGERPRINT_EXIT_CODE
EOF
}

capture_transport_timeline_status() {
  transport_initial_state="${PIXEL_ADB_TRANSPORT_INITIAL_STATE:-}"
  transport_first_none_elapsed_secs="${PIXEL_ADB_TRANSPORT_FIRST_NONE_ELAPSED_SECS:-}"
  transport_first_fastboot_elapsed_secs="${PIXEL_ADB_TRANSPORT_FIRST_FASTBOOT_ELAPSED_SECS:-}"
  transport_first_adb_elapsed_secs="${PIXEL_ADB_TRANSPORT_FIRST_ADB_ELAPSED_SECS:-}"
  transport_last_state="${PIXEL_ADB_TRANSPORT_LAST_STATE:-}"
  transport_last_state_elapsed_secs="${PIXEL_ADB_TRANSPORT_LAST_STATE_ELAPSED_SECS:-}"
}

maybe_auto_reboot_fastboot_return() {
  local elapsed_secs
  elapsed_secs="${1:?maybe_auto_reboot_fastboot_return requires elapsed seconds}"

  if ! flag_enabled "$AUTO_FASTBOOT_REBOOT"; then
    return 1
  fi

  if [[ "$fastboot_auto_reboot_attempted" == "true" ]]; then
    return 1
  fi

  if [[ "${PIXEL_ADB_TRANSPORT_LAST_STATE:-}" != "fastboot" ]]; then
    return 1
  fi

  if [[ -z "${PIXEL_ADB_TRANSPORT_FIRST_NONE_ELAPSED_SECS:-}" && "$transport_left_fastboot_seed" != "true" ]]; then
    return 1
  fi

  fastboot_auto_reboot_attempted=true
  fastboot_auto_reboot_elapsed_secs="$elapsed_secs"
  fastboot_auto_reboot_reason="returned-fastboot-after-leave"

  if pixel_fastboot "$serial" reboot; then
    fastboot_auto_reboot_succeeded=true
    printf 'Auto-rebooted %s from fastboot return after %ss\n' "$serial" "$elapsed_secs"
    return 0
  fi

  echo "pixel_boot_recover_traces: failed to auto-reboot $serial after fastboot return" >&2
  return 1
}

wait_for_adb_with_transport_timeline_and_auto_fastboot_reboot() {
  local serial timeout timeline_path elapsed_offset_secs started_at elapsed_secs current_state
  serial="${1:?wait_for_adb_with_transport_timeline_and_auto_fastboot_reboot requires a serial}"
  timeout="${2:-120}"
  timeline_path="${3:-}"
  elapsed_offset_secs="${4:-0}"

  pixel_reset_adb_transport_timeline_status
  PIXEL_ADB_TRANSPORT_TIMELINE_LAST_RECORDED_STATE="$transport_timeline_last_recorded_state_seed"
  started_at=$SECONDS
  elapsed_secs="$elapsed_offset_secs"

  for _ in $(seq 1 "$timeout"); do
    current_state="$(pixel_transport_state "$serial")"
    elapsed_secs=$((elapsed_offset_secs + SECONDS - started_at))
    pixel_note_adb_transport_timeline_state "$elapsed_secs" "$current_state" "$timeline_path"
    if [[ "$current_state" == "adb" ]]; then
      pixel_note_adb_transport_timeline_stop_event "$elapsed_secs" "$current_state" "recover-traces-adb-ready" "$timeline_path"
      return 0
    fi
    if [[ "$current_state" == "fastboot" ]]; then
      maybe_auto_reboot_fastboot_return "$elapsed_secs" || true
    fi
    sleep 1
  done

  pixel_note_adb_transport_timeline_stop_event \
    "$elapsed_secs" \
    "${PIXEL_ADB_TRANSPORT_LAST_STATE:-unknown}" \
    "recover-traces-wait-adb-timeout" \
    "$timeline_path"
  echo "pixel: timed out waiting for adb device $serial" >&2
  return 1
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
    "$ROOT_ID" \
    "$transport_timeline_path" \
    "$transport_initial_state" \
    "$transport_first_none_elapsed_secs" \
    "$transport_first_fastboot_elapsed_secs" \
    "$transport_first_adb_elapsed_secs" \
    "$transport_last_state" \
    "$transport_last_state_elapsed_secs" \
    "$(bool_word "$fastboot_auto_reboot_attempted")" \
    "$(bool_word "$fastboot_auto_reboot_succeeded")" \
    "$fastboot_auto_reboot_elapsed_secs" \
    "$fastboot_auto_reboot_reason" \
    "$EXPECTED_METADATA_STAGE_BREADCRUMB" \
    "$EXPECTED_METADATA_STAGE_PATH" \
    "$EXPECTED_METADATA_PROBE_STAGE_PATH" \
    "$EXPECTED_METADATA_PROBE_FINGERPRINT_PATH" \
    "$RECOVERED_METADATA_STAGE_PRESENT" \
    "$RECOVERED_METADATA_STAGE_VALUE" \
    "$RECOVERED_METADATA_STAGE_ACTUAL_ACCESS_MODE" \
    "$RECOVERED_METADATA_STAGE_EXIT_CODE" \
    "$RECOVERED_METADATA_STAGE_OUTPUT_PATH" \
    "$RECOVERED_METADATA_STAGE_STDERR_PATH" \
    "$RECOVERED_METADATA_PROBE_STAGE_PRESENT" \
    "$RECOVERED_METADATA_PROBE_STAGE_VALUE" \
    "$RECOVERED_METADATA_PROBE_STAGE_ACTUAL_ACCESS_MODE" \
    "$RECOVERED_METADATA_PROBE_STAGE_EXIT_CODE" \
    "$RECOVERED_METADATA_PROBE_STAGE_OUTPUT_PATH" \
    "$RECOVERED_METADATA_PROBE_STAGE_STDERR_PATH" \
    "$RECOVERED_METADATA_PROBE_FINGERPRINT_PRESENT" \
    "$RECOVERED_METADATA_PROBE_FINGERPRINT_ACTUAL_ACCESS_MODE" \
    "$RECOVERED_METADATA_PROBE_FINGERPRINT_EXIT_CODE" \
    "$RECOVERED_METADATA_PROBE_FINGERPRINT_OUTPUT_PATH" \
    "$RECOVERED_METADATA_PROBE_FINGERPRINT_STDERR_PATH" <<'PY'
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
transport_timeline_path = sys.argv[14]
transport_initial_state = sys.argv[15]
transport_first_none_elapsed_secs = sys.argv[16]
transport_first_fastboot_elapsed_secs = sys.argv[17]
transport_first_adb_elapsed_secs = sys.argv[18]
transport_last_state = sys.argv[19]
transport_last_state_elapsed_secs = sys.argv[20]
fastboot_auto_reboot_attempted = sys.argv[21] == "true"
fastboot_auto_reboot_succeeded = sys.argv[22] == "true"
fastboot_auto_reboot_elapsed_secs = sys.argv[23]
fastboot_auto_reboot_reason = sys.argv[24]
expected_metadata_stage_breadcrumb = sys.argv[25] == "true"
expected_metadata_stage_path = sys.argv[26]
expected_metadata_probe_stage_path = sys.argv[27]
expected_metadata_probe_fingerprint_path = sys.argv[28]
recovered_metadata_stage_present = sys.argv[29] == "true"
recovered_metadata_stage_value = sys.argv[30]
recovered_metadata_stage_actual_access_mode = sys.argv[31]
recovered_metadata_stage_exit_code = sys.argv[32]
recovered_metadata_stage_output_path = sys.argv[33]
recovered_metadata_stage_stderr_path = sys.argv[34]
recovered_metadata_probe_stage_present = sys.argv[35] == "true"
recovered_metadata_probe_stage_value = sys.argv[36]
recovered_metadata_probe_stage_actual_access_mode = sys.argv[37]
recovered_metadata_probe_stage_exit_code = sys.argv[38]
recovered_metadata_probe_stage_output_path = sys.argv[39]
recovered_metadata_probe_stage_stderr_path = sys.argv[40]
recovered_metadata_probe_fingerprint_present = sys.argv[41] == "true"
recovered_metadata_probe_fingerprint_actual_access_mode = sys.argv[42]
recovered_metadata_probe_fingerprint_exit_code = sys.argv[43]
recovered_metadata_probe_fingerprint_output_path = sys.argv[44]
recovered_metadata_probe_fingerprint_stderr_path = sys.argv[45]
expected_durable_logging = {"kmsg": None, "pmsg": None}

if source_image_metadata_path:
    metadata_path = Path(source_image_metadata_path)
    if metadata_path.exists():
        try:
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            metadata = {}
        for source_key, target_key in (("log_kmsg", "kmsg"), ("log_pmsg", "pmsg")):
            value = metadata.get(source_key)
            if isinstance(value, bool):
                expected_durable_logging[target_key] = value

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
absence_reasons = set()

with channel_status_path.open("r", encoding="utf-8") as fh:
    for row in csv.DictReader(fh, delimiter="\t"):
        output_path = channel_status_path.parent / row["output_path"]
        stderr_path = channel_status_path.parent / row["stderr_path"]
        matches_path = channel_status_path.parent / row["matches_path"]
        run_token_matches_path = channel_status_path.parent / row["run_token_matches_path"]
        output_text = output_path.read_text(encoding="utf-8", errors="replace") if output_path.exists() else ""
        stderr_text = stderr_path.read_text(encoding="utf-8", errors="replace") if stderr_path.exists() else ""
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

        channel_name = row["name"]
        if channel_name == "pmsg0":
            if "Invalid argument" in stderr_text:
                absence_reasons.add("pmsg_invalid_argument")
            elif row["actual_access_mode"] == "root-unavailable":
                absence_reasons.add("pmsg_root_unavailable")
        elif channel_name == "pstore":
            if "no pstore entries" in output_text:
                absence_reasons.add("pstore_empty")
            elif row["actual_access_mode"] == "root-unavailable":
                absence_reasons.add("pstore_root_unavailable")
        elif channel_name == "dropbox-system-last-kmsg":
            if "(No entries found.)" in output_text:
                absence_reasons.add("dropbox_last_kmsg_empty")
        elif channel_name == "logcat-last":
            if "Logcat read failure: No such file or directory" in stderr_text:
                absence_reasons.add("logcat_last_unavailable")

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
    "proof_ok": matched_any_correlated_shadow_tags,
    "matched_correlated_trace": matched_any_correlated_shadow_tags,
    "serial": serial,
    "output_dir": str(status_output.parent),
    "shadow_tag_regex": shadow_tag_regex,
    "expected_run_token": expected_run_token,
    "expected_run_token_source": expected_run_token_source,
    "expected_run_token_present": bool(expected_run_token),
    "expected_durable_logging": expected_durable_logging,
    "expected_durable_logging_summary": ",".join(
        f"{key}={str(value).lower()}" for key, value in expected_durable_logging.items()
    ),
    "source_image_path": source_image_path,
    "source_image_metadata_path": source_image_metadata_path,
    "expected_metadata_stage_breadcrumb": expected_metadata_stage_breadcrumb,
    "expected_metadata_stage_path": expected_metadata_stage_path,
    "expected_metadata_probe_stage_path": expected_metadata_probe_stage_path,
    "expected_metadata_probe_fingerprint_path": expected_metadata_probe_fingerprint_path,
    "metadata_stage_present": recovered_metadata_stage_present,
    "metadata_stage_value": recovered_metadata_stage_value,
    "metadata_stage_actual_access_mode": recovered_metadata_stage_actual_access_mode,
    "metadata_stage_exit_code": (
        int(recovered_metadata_stage_exit_code)
        if recovered_metadata_stage_exit_code not in ("", None)
        else None
    ),
    "metadata_stage_output_path": recovered_metadata_stage_output_path,
    "metadata_stage_stderr_path": recovered_metadata_stage_stderr_path,
    "metadata_probe_stage_present": recovered_metadata_probe_stage_present,
    "metadata_probe_stage_value": recovered_metadata_probe_stage_value,
    "metadata_probe_stage_actual_access_mode": recovered_metadata_probe_stage_actual_access_mode,
    "metadata_probe_stage_exit_code": (
        int(recovered_metadata_probe_stage_exit_code)
        if recovered_metadata_probe_stage_exit_code not in ("", None)
        else None
    ),
    "metadata_probe_stage_output_path": recovered_metadata_probe_stage_output_path,
    "metadata_probe_stage_stderr_path": recovered_metadata_probe_stage_stderr_path,
    "metadata_probe_fingerprint_present": recovered_metadata_probe_fingerprint_present,
    "metadata_probe_fingerprint_actual_access_mode": recovered_metadata_probe_fingerprint_actual_access_mode,
    "metadata_probe_fingerprint_exit_code": (
        int(recovered_metadata_probe_fingerprint_exit_code)
        if recovered_metadata_probe_fingerprint_exit_code not in ("", None)
        else None
    ),
    "metadata_probe_fingerprint_output_path": recovered_metadata_probe_fingerprint_output_path,
    "metadata_probe_fingerprint_stderr_path": recovered_metadata_probe_fingerprint_stderr_path,
    "live_boot_id": live_boot_id,
    "live_slot_suffix": live_slot_suffix,
    "root_available": root_available,
    "root_id": root_id,
    "wait_boot_completed": wait_boot_completed,
    "transport_timeline_path": transport_timeline_path,
    "transport_initial_state": transport_initial_state,
    "transport_first_none_elapsed_secs": transport_first_none_elapsed_secs,
    "transport_first_fastboot_elapsed_secs": transport_first_fastboot_elapsed_secs,
    "transport_first_adb_elapsed_secs": transport_first_adb_elapsed_secs,
    "transport_last_state": transport_last_state,
    "transport_last_state_elapsed_secs": transport_last_state_elapsed_secs,
    "fastboot_auto_reboot_attempted": fastboot_auto_reboot_attempted,
    "fastboot_auto_reboot_succeeded": fastboot_auto_reboot_succeeded,
    "fastboot_auto_reboot_elapsed_secs": fastboot_auto_reboot_elapsed_secs,
    "fastboot_auto_reboot_reason": fastboot_auto_reboot_reason,
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
    "absence_reasons": sorted(absence_reasons),
    "absence_reason_summary": ",".join(sorted(absence_reasons)),
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
status_path="$OUTPUT_DIR/status.json"
discover_expected_run_token
trap finish EXIT

if ! wait_for_adb_with_transport_timeline_and_auto_fastboot_reboot \
  "$serial" \
  "$ADB_TIMEOUT_SECS" \
  "$transport_timeline_path" \
  "$transport_timeline_elapsed_offset_secs"; then
  capture_transport_timeline_status
  failure_stage="wait-adb"
  exit 1
fi
capture_transport_timeline_status
if [[ "$WAIT_BOOT_COMPLETED" == "1" ]]; then
  if ! pixel_wait_for_boot_completed "$serial" "$BOOT_TIMEOUT_SECS" >/dev/null; then
    failure_stage="wait-boot-completed"
    exit 1
  fi
fi

CHANNEL_DIR="$OUTPUT_DIR/channels"
MATCH_DIR="$OUTPUT_DIR/matches"
META_DIR="$OUTPUT_DIR/meta"
mkdir -p "$CHANNEL_DIR" "$MATCH_DIR" "$META_DIR"
CHANNEL_STATUS_TSV="$OUTPUT_DIR/channel-status.tsv"
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
recover_metadata_stage_file
recover_metadata_probe_stage_file
recover_metadata_probe_fingerprint_file

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
trap - EXIT
