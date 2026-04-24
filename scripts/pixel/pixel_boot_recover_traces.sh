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
ROOT_TIMEOUT_SECS="${PIXEL_BOOT_RECOVER_TRACES_ROOT_TIMEOUT_SECS:-20}"
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
EXPECTED_METADATA_PROBE_REPORT_PATH=""
EXPECTED_METADATA_PROBE_TIMEOUT_CLASS_PATH=""
EXPECTED_METADATA_PROBE_SUMMARY_PATH=""
EXPECTED_METADATA_COMPOSITOR_FRAME_PATH=""
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
RECOVERED_METADATA_PROBE_REPORT_PRESENT=false
RECOVERED_METADATA_PROBE_REPORT_ACTUAL_ACCESS_MODE="unattempted"
RECOVERED_METADATA_PROBE_REPORT_EXIT_CODE=""
RECOVERED_METADATA_PROBE_REPORT_OUTPUT_PATH=""
RECOVERED_METADATA_PROBE_REPORT_STDERR_PATH=""
RECOVERED_METADATA_PROBE_REPORT_OBSERVED_STAGE=""
RECOVERED_METADATA_PROBE_REPORT_TIMED_OUT=""
RECOVERED_METADATA_PROBE_REPORT_WCHAN=""
RECOVERED_METADATA_PROBE_REPORT_CHILD_COMPLETED=""
RECOVERED_METADATA_PROBE_REPORT_CHILD_EXIT_STATUS=""
RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_PRESENT=false
RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_ACTUAL_ACCESS_MODE="unattempted"
RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_EXIT_CODE=""
RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_OUTPUT_PATH=""
RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_STDERR_PATH=""
RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_CHECKPOINT=""
RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_BUCKET=""
RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_MATCHED_NEEDLE=""
RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_WCHAN=""
RECOVERED_METADATA_PROBE_SUMMARY_PRESENT=false
RECOVERED_METADATA_PROBE_SUMMARY_ACTUAL_ACCESS_MODE="unattempted"
RECOVERED_METADATA_PROBE_SUMMARY_EXIT_CODE=""
RECOVERED_METADATA_PROBE_SUMMARY_OUTPUT_PATH=""
RECOVERED_METADATA_PROBE_SUMMARY_STDERR_PATH=""
RECOVERED_METADATA_COMPOSITOR_FRAME_PRESENT=false
RECOVERED_METADATA_COMPOSITOR_FRAME_ACTUAL_ACCESS_MODE="unattempted"
RECOVERED_METADATA_COMPOSITOR_FRAME_EXIT_CODE=""
RECOVERED_METADATA_COMPOSITOR_FRAME_OUTPUT_PATH=""
RECOVERED_METADATA_COMPOSITOR_FRAME_STDERR_PATH=""
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
    "$EXPECTED_METADATA_PROBE_TIMEOUT_CLASS_PATH" \
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
    expected_metadata_probe_timeout_class_path,
    recovered_metadata_stage_present,
    recovered_metadata_stage_value,
    recovered_metadata_stage_actual_access_mode,
    recovered_metadata_stage_exit_code,
) = sys.argv[1:31]

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
    "expected_metadata_probe_timeout_class_path": expected_metadata_probe_timeout_class_path,
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
probe_report_path = payload.get("metadata_probe_report_path", "")
probe_timeout_class_path = payload.get("metadata_probe_timeout_class_path", "")
probe_summary_path = payload.get("metadata_probe_summary_path", "")
compositor_frame_path = payload.get("metadata_compositor_frame_path", "")

print(token if isinstance(token, str) else "")
print("true" if enabled is True else "false")
print(stage_path if isinstance(stage_path, str) else "")
print(probe_stage_path if isinstance(probe_stage_path, str) else "")
print(probe_fingerprint_path if isinstance(probe_fingerprint_path, str) else "")
print(probe_report_path if isinstance(probe_report_path, str) else "")
print(probe_timeout_class_path if isinstance(probe_timeout_class_path, str) else "")
print(probe_summary_path if isinstance(probe_summary_path, str) else "")
print(compositor_frame_path if isinstance(compositor_frame_path, str) else "")
PY
}

discover_expected_run_token() {
  local metadata_values=()
  local metadata_token=""
  local metadata_stage_enabled=""
  local metadata_stage_path=""
  local metadata_probe_stage_path=""
  local metadata_probe_fingerprint_path=""
  local metadata_probe_report_path=""
  local metadata_probe_timeout_class_path=""
  local metadata_probe_summary_path=""
  local metadata_compositor_frame_path=""

  discover_source_image_path
  if [[ -n "$SOURCE_IMAGE_PATH" ]]; then
    SOURCE_IMAGE_METADATA_PATH="$(hello_init_metadata_path "$SOURCE_IMAGE_PATH")"
    while IFS= read -r metadata_value; do
      metadata_values+=("$metadata_value")
    done < <(load_recovery_metadata_values "$SOURCE_IMAGE_METADATA_PATH")
    metadata_token="${metadata_values[0]:-}"
    metadata_stage_enabled="${metadata_values[1]:-false}"
    metadata_stage_path="${metadata_values[2]:-}"
    metadata_probe_stage_path="${metadata_values[3]:-}"
    metadata_probe_fingerprint_path="${metadata_values[4]:-}"
    metadata_probe_report_path="${metadata_values[5]:-}"
    metadata_probe_timeout_class_path="${metadata_values[6]:-}"
    metadata_probe_summary_path="${metadata_values[7]:-}"
    metadata_compositor_frame_path="${metadata_values[8]:-}"
    EXPECTED_METADATA_STAGE_BREADCRUMB="$metadata_stage_enabled"
    EXPECTED_METADATA_STAGE_PATH="$metadata_stage_path"
    EXPECTED_METADATA_PROBE_STAGE_PATH="$metadata_probe_stage_path"
    EXPECTED_METADATA_PROBE_FINGERPRINT_PATH="$metadata_probe_fingerprint_path"
    EXPECTED_METADATA_PROBE_REPORT_PATH="$metadata_probe_report_path"
    EXPECTED_METADATA_PROBE_TIMEOUT_CLASS_PATH="$metadata_probe_timeout_class_path"
    EXPECTED_METADATA_PROBE_SUMMARY_PATH="$metadata_probe_summary_path"
    EXPECTED_METADATA_COMPOSITOR_FRAME_PATH="$metadata_compositor_frame_path"
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
expected_metadata_probe_report_path=$EXPECTED_METADATA_PROBE_REPORT_PATH
expected_metadata_probe_timeout_class_path=$EXPECTED_METADATA_PROBE_TIMEOUT_CLASS_PATH
expected_metadata_probe_summary_path=$EXPECTED_METADATA_PROBE_SUMMARY_PATH
expected_metadata_compositor_frame_path=$EXPECTED_METADATA_COMPOSITOR_FRAME_PATH
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

recover_metadata_probe_report_file() {
  local command run_result output_path stderr_path exit_code actual_access_mode
  local parsed_report=()

  output_path="$CHANNEL_DIR/metadata-probe-report.txt"
  stderr_path="$CHANNEL_DIR/metadata-probe-report.stderr.txt"
  RECOVERED_METADATA_PROBE_REPORT_OUTPUT_PATH="channels/metadata-probe-report.txt"
  RECOVERED_METADATA_PROBE_REPORT_STDERR_PATH="channels/metadata-probe-report.stderr.txt"

  : >"$output_path"
  : >"$stderr_path"

  if [[ "$EXPECTED_METADATA_STAGE_BREADCRUMB" != "true" || -z "$EXPECTED_METADATA_PROBE_REPORT_PATH" ]]; then
    RECOVERED_METADATA_PROBE_REPORT_PRESENT=false
    RECOVERED_METADATA_PROBE_REPORT_ACTUAL_ACCESS_MODE="unattempted"
    RECOVERED_METADATA_PROBE_REPORT_EXIT_CODE=""
    RECOVERED_METADATA_PROBE_REPORT_OBSERVED_STAGE=""
    RECOVERED_METADATA_PROBE_REPORT_TIMED_OUT=""
    RECOVERED_METADATA_PROBE_REPORT_WCHAN=""
    RECOVERED_METADATA_PROBE_REPORT_CHILD_COMPLETED=""
    RECOVERED_METADATA_PROBE_REPORT_CHILD_EXIT_STATUS=""
    cat >"$META_DIR/metadata-probe-report.txt" <<EOF
expected_metadata_stage_breadcrumb=$EXPECTED_METADATA_STAGE_BREADCRUMB
expected_metadata_probe_report_path=$EXPECTED_METADATA_PROBE_REPORT_PATH
metadata_probe_report_present=false
metadata_probe_report_actual_access_mode=$RECOVERED_METADATA_PROBE_REPORT_ACTUAL_ACCESS_MODE
metadata_probe_report_exit_code=
metadata_probe_report_observed_stage=
metadata_probe_report_timed_out=
metadata_probe_report_wchan=
metadata_probe_report_child_completed=
metadata_probe_report_child_exit_status=
EOF
    return 0
  fi

  command="if [ -f $EXPECTED_METADATA_PROBE_REPORT_PATH ]; then cat $EXPECTED_METADATA_PROBE_REPORT_PATH; else exit 3; fi"
  run_result="$(run_device_command "root" "$command" "$output_path" "$stderr_path")"
  exit_code="${run_result%%$'\t'*}"
  actual_access_mode="${run_result#*$'\t'}"
  RECOVERED_METADATA_PROBE_REPORT_ACTUAL_ACCESS_MODE="$actual_access_mode"
  RECOVERED_METADATA_PROBE_REPORT_EXIT_CODE="$exit_code"

  if [[ "$exit_code" == "0" ]]; then
    RECOVERED_METADATA_PROBE_REPORT_PRESENT=true
    while IFS= read -r parsed_line; do
      parsed_report+=("$parsed_line")
    done < <(python3 - "$output_path" <<'PY'
from pathlib import Path
import sys

payload = {}
for raw_line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines():
    if "=" not in raw_line:
        continue
    key, value = raw_line.split("=", 1)
    payload[key] = value

for key in ("observed_probe_stage", "child_timed_out", "wchan", "child_completed", "exit_status"):
    print(payload.get(key, ""))
PY
)
    RECOVERED_METADATA_PROBE_REPORT_OBSERVED_STAGE="${parsed_report[0]:-}"
    RECOVERED_METADATA_PROBE_REPORT_TIMED_OUT="${parsed_report[1]:-}"
    RECOVERED_METADATA_PROBE_REPORT_WCHAN="${parsed_report[2]:-}"
    RECOVERED_METADATA_PROBE_REPORT_CHILD_COMPLETED="${parsed_report[3]:-}"
    RECOVERED_METADATA_PROBE_REPORT_CHILD_EXIT_STATUS="${parsed_report[4]:-}"
  else
    RECOVERED_METADATA_PROBE_REPORT_PRESENT=false
    RECOVERED_METADATA_PROBE_REPORT_OBSERVED_STAGE=""
    RECOVERED_METADATA_PROBE_REPORT_TIMED_OUT=""
    RECOVERED_METADATA_PROBE_REPORT_WCHAN=""
    RECOVERED_METADATA_PROBE_REPORT_CHILD_COMPLETED=""
    RECOVERED_METADATA_PROBE_REPORT_CHILD_EXIT_STATUS=""
  fi

  cat >"$META_DIR/metadata-probe-report.txt" <<EOF
expected_metadata_stage_breadcrumb=$EXPECTED_METADATA_STAGE_BREADCRUMB
expected_metadata_probe_report_path=$EXPECTED_METADATA_PROBE_REPORT_PATH
metadata_probe_report_present=$RECOVERED_METADATA_PROBE_REPORT_PRESENT
metadata_probe_report_actual_access_mode=$RECOVERED_METADATA_PROBE_REPORT_ACTUAL_ACCESS_MODE
metadata_probe_report_exit_code=$RECOVERED_METADATA_PROBE_REPORT_EXIT_CODE
metadata_probe_report_observed_stage=$RECOVERED_METADATA_PROBE_REPORT_OBSERVED_STAGE
metadata_probe_report_timed_out=$RECOVERED_METADATA_PROBE_REPORT_TIMED_OUT
metadata_probe_report_wchan=$RECOVERED_METADATA_PROBE_REPORT_WCHAN
metadata_probe_report_child_completed=$RECOVERED_METADATA_PROBE_REPORT_CHILD_COMPLETED
metadata_probe_report_child_exit_status=$RECOVERED_METADATA_PROBE_REPORT_CHILD_EXIT_STATUS
EOF
}

recover_metadata_probe_summary_file() {
  local command run_result output_path stderr_path exit_code actual_access_mode

  output_path="$CHANNEL_DIR/metadata-probe-summary.json"
  stderr_path="$CHANNEL_DIR/metadata-probe-summary.stderr.txt"
  RECOVERED_METADATA_PROBE_SUMMARY_OUTPUT_PATH="channels/metadata-probe-summary.json"
  RECOVERED_METADATA_PROBE_SUMMARY_STDERR_PATH="channels/metadata-probe-summary.stderr.txt"

  : >"$output_path"
  : >"$stderr_path"

  if [[ "$EXPECTED_METADATA_STAGE_BREADCRUMB" != "true" || -z "$EXPECTED_METADATA_PROBE_SUMMARY_PATH" ]]; then
    RECOVERED_METADATA_PROBE_SUMMARY_PRESENT=false
    RECOVERED_METADATA_PROBE_SUMMARY_ACTUAL_ACCESS_MODE="unattempted"
    RECOVERED_METADATA_PROBE_SUMMARY_EXIT_CODE=""
    cat >"$META_DIR/metadata-probe-summary.txt" <<EOF
expected_metadata_stage_breadcrumb=$EXPECTED_METADATA_STAGE_BREADCRUMB
expected_metadata_probe_summary_path=$EXPECTED_METADATA_PROBE_SUMMARY_PATH
metadata_probe_summary_present=false
metadata_probe_summary_actual_access_mode=$RECOVERED_METADATA_PROBE_SUMMARY_ACTUAL_ACCESS_MODE
metadata_probe_summary_exit_code=
EOF
    return 0
  fi

  command="if [ -f $EXPECTED_METADATA_PROBE_SUMMARY_PATH ]; then cat $EXPECTED_METADATA_PROBE_SUMMARY_PATH; else exit 3; fi"
  run_result="$(run_device_command "root" "$command" "$output_path" "$stderr_path")"
  exit_code="${run_result%%$'\t'*}"
  actual_access_mode="${run_result#*$'\t'}"
  RECOVERED_METADATA_PROBE_SUMMARY_ACTUAL_ACCESS_MODE="$actual_access_mode"
  RECOVERED_METADATA_PROBE_SUMMARY_EXIT_CODE="$exit_code"

  if [[ "$exit_code" == "0" ]]; then
    RECOVERED_METADATA_PROBE_SUMMARY_PRESENT=true
  else
    RECOVERED_METADATA_PROBE_SUMMARY_PRESENT=false
  fi

  cat >"$META_DIR/metadata-probe-summary.txt" <<EOF
expected_metadata_stage_breadcrumb=$EXPECTED_METADATA_STAGE_BREADCRUMB
expected_metadata_probe_summary_path=$EXPECTED_METADATA_PROBE_SUMMARY_PATH
metadata_probe_summary_present=$RECOVERED_METADATA_PROBE_SUMMARY_PRESENT
metadata_probe_summary_actual_access_mode=$RECOVERED_METADATA_PROBE_SUMMARY_ACTUAL_ACCESS_MODE
metadata_probe_summary_exit_code=$RECOVERED_METADATA_PROBE_SUMMARY_EXIT_CODE
EOF
}

recover_metadata_compositor_frame_file() {
  local command run_result output_path stderr_path exit_code actual_access_mode

  output_path="$CHANNEL_DIR/metadata-compositor-frame.ppm"
  stderr_path="$CHANNEL_DIR/metadata-compositor-frame.stderr.txt"
  RECOVERED_METADATA_COMPOSITOR_FRAME_OUTPUT_PATH="channels/metadata-compositor-frame.ppm"
  RECOVERED_METADATA_COMPOSITOR_FRAME_STDERR_PATH="channels/metadata-compositor-frame.stderr.txt"

  : >"$output_path"
  : >"$stderr_path"

  if [[ "$EXPECTED_METADATA_STAGE_BREADCRUMB" != "true" || -z "$EXPECTED_METADATA_COMPOSITOR_FRAME_PATH" ]]; then
    RECOVERED_METADATA_COMPOSITOR_FRAME_PRESENT=false
    RECOVERED_METADATA_COMPOSITOR_FRAME_ACTUAL_ACCESS_MODE="unattempted"
    RECOVERED_METADATA_COMPOSITOR_FRAME_EXIT_CODE=""
    cat >"$META_DIR/metadata-compositor-frame.txt" <<EOF
expected_metadata_stage_breadcrumb=$EXPECTED_METADATA_STAGE_BREADCRUMB
expected_metadata_compositor_frame_path=$EXPECTED_METADATA_COMPOSITOR_FRAME_PATH
metadata_compositor_frame_present=false
metadata_compositor_frame_actual_access_mode=$RECOVERED_METADATA_COMPOSITOR_FRAME_ACTUAL_ACCESS_MODE
metadata_compositor_frame_exit_code=
EOF
    return 0
  fi

  command="if [ -f $EXPECTED_METADATA_COMPOSITOR_FRAME_PATH ]; then cat $EXPECTED_METADATA_COMPOSITOR_FRAME_PATH; else exit 3; fi"
  run_result="$(run_device_command "root" "$command" "$output_path" "$stderr_path")"
  exit_code="${run_result%%$'\t'*}"
  actual_access_mode="${run_result#*$'\t'}"
  RECOVERED_METADATA_COMPOSITOR_FRAME_ACTUAL_ACCESS_MODE="$actual_access_mode"
  RECOVERED_METADATA_COMPOSITOR_FRAME_EXIT_CODE="$exit_code"

  if [[ "$exit_code" == "0" ]]; then
    RECOVERED_METADATA_COMPOSITOR_FRAME_PRESENT=true
  else
    RECOVERED_METADATA_COMPOSITOR_FRAME_PRESENT=false
  fi

  cat >"$META_DIR/metadata-compositor-frame.txt" <<EOF
expected_metadata_stage_breadcrumb=$EXPECTED_METADATA_STAGE_BREADCRUMB
expected_metadata_compositor_frame_path=$EXPECTED_METADATA_COMPOSITOR_FRAME_PATH
metadata_compositor_frame_present=$RECOVERED_METADATA_COMPOSITOR_FRAME_PRESENT
metadata_compositor_frame_actual_access_mode=$RECOVERED_METADATA_COMPOSITOR_FRAME_ACTUAL_ACCESS_MODE
metadata_compositor_frame_exit_code=$RECOVERED_METADATA_COMPOSITOR_FRAME_EXIT_CODE
EOF
}

recover_metadata_probe_timeout_class_file() {
  local command run_result output_path stderr_path exit_code actual_access_mode
  local parsed_report=()

  output_path="$CHANNEL_DIR/metadata-probe-timeout-class.txt"
  stderr_path="$CHANNEL_DIR/metadata-probe-timeout-class.stderr.txt"
  RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_OUTPUT_PATH="channels/metadata-probe-timeout-class.txt"
  RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_STDERR_PATH="channels/metadata-probe-timeout-class.stderr.txt"

  : >"$output_path"
  : >"$stderr_path"

  if [[ "$EXPECTED_METADATA_STAGE_BREADCRUMB" != "true" || -z "$EXPECTED_METADATA_PROBE_TIMEOUT_CLASS_PATH" ]]; then
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_PRESENT=false
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_ACTUAL_ACCESS_MODE="unattempted"
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_EXIT_CODE=""
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_CHECKPOINT=""
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_BUCKET=""
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_MATCHED_NEEDLE=""
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_WCHAN=""
    cat >"$META_DIR/metadata-probe-timeout-class.txt" <<EOF
expected_metadata_stage_breadcrumb=$EXPECTED_METADATA_STAGE_BREADCRUMB
expected_metadata_probe_timeout_class_path=$EXPECTED_METADATA_PROBE_TIMEOUT_CLASS_PATH
metadata_probe_timeout_class_present=false
metadata_probe_timeout_class_actual_access_mode=$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_ACTUAL_ACCESS_MODE
metadata_probe_timeout_class_exit_code=
metadata_probe_timeout_class_checkpoint=
metadata_probe_timeout_class_bucket=
metadata_probe_timeout_class_matched_needle=
metadata_probe_timeout_class_wchan=
EOF
    return 0
  fi

  command="if [ -f $EXPECTED_METADATA_PROBE_TIMEOUT_CLASS_PATH ]; then cat $EXPECTED_METADATA_PROBE_TIMEOUT_CLASS_PATH; else exit 3; fi"
  run_result="$(run_device_command "root" "$command" "$output_path" "$stderr_path")"
  exit_code="${run_result%%$'\t'*}"
  actual_access_mode="${run_result#*$'\t'}"
  RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_ACTUAL_ACCESS_MODE="$actual_access_mode"
  RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_EXIT_CODE="$exit_code"

  if [[ "$exit_code" == "0" ]]; then
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_PRESENT=true
    mapfile -t parsed_report < <(python3 - "$output_path" <<'PY'
from pathlib import Path
import sys

payload = {}
for raw_line in Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines():
    if "=" not in raw_line:
        continue
    key, value = raw_line.split("=", 1)
    payload[key] = value

for key in (
    "classification_checkpoint",
    "classification_bucket",
    "classification_matched_needle",
    "wchan",
):
    print(payload.get(key, ""))
PY
    )
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_CHECKPOINT="${parsed_report[0]:-}"
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_BUCKET="${parsed_report[1]:-}"
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_MATCHED_NEEDLE="${parsed_report[2]:-}"
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_WCHAN="${parsed_report[3]:-}"
  else
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_PRESENT=false
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_CHECKPOINT=""
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_BUCKET=""
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_MATCHED_NEEDLE=""
    RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_WCHAN=""
  fi

  cat >"$META_DIR/metadata-probe-timeout-class.txt" <<EOF
expected_metadata_stage_breadcrumb=$EXPECTED_METADATA_STAGE_BREADCRUMB
expected_metadata_probe_timeout_class_path=$EXPECTED_METADATA_PROBE_TIMEOUT_CLASS_PATH
metadata_probe_timeout_class_present=$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_PRESENT
metadata_probe_timeout_class_actual_access_mode=$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_ACTUAL_ACCESS_MODE
metadata_probe_timeout_class_exit_code=$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_EXIT_CODE
metadata_probe_timeout_class_checkpoint=$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_CHECKPOINT
metadata_probe_timeout_class_bucket=$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_BUCKET
metadata_probe_timeout_class_matched_needle=$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_MATCHED_NEEDLE
metadata_probe_timeout_class_wchan=$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_WCHAN
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
        pixel_root_shell_timeout "$ROOT_TIMEOUT_SECS" "$serial" "$command" >"$output_path" 2>"$stderr_path"
        exit_code="$?"
        set -e
        if [[ "$exit_code" -eq 124 ]]; then
          actual_access_mode="root-timeout"
        else
          actual_access_mode="root"
        fi
      fi
      ;;
    *)
      echo "pixel_boot_recover_traces: unsupported access mode: $access_mode" >&2
      exit 1
      ;;
  esac

  printf '%s\t%s\n' "$exit_code" "$actual_access_mode"
}

record_channel_result() {
  local output_path stderr_path status_path run_token_status_path
  local available matched matched_run_token correlated
  local match_count run_token_match_count channel_status recorded_command correlation_state
  local name="$1"
  local scope="$2"
  local requested_access_mode="$3"
  local command="$4"
  local actual_access_mode="$5"
  local channel_status="$6"
  local source_kind="${7:-}"
  output_path="$CHANNEL_DIR/$name.txt"
  stderr_path="$CHANNEL_DIR/$name.stderr.txt"
  status_path="$MATCH_DIR/$name.shadow-tags.txt"
  run_token_status_path="$MATCH_DIR/$name.run-token.txt"

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

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" \
    "$scope" \
    "$recorded_command" \
    "$requested_access_mode" \
    "$actual_access_mode" \
    "$source_kind" \
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

shell_best_effort() {
  local name="$1"
  local scope="$2"
  local requested_access_mode="$3"
  local command="$4"
  local source_kind="${5:-}"
  local output_path stderr_path run_result channel_status actual_access_mode

  output_path="$CHANNEL_DIR/$name.txt"
  stderr_path="$CHANNEL_DIR/$name.stderr.txt"
  run_result="$(run_device_command "$requested_access_mode" "$command" "$output_path" "$stderr_path")"
  channel_status="${run_result%%$'\t'*}"
  actual_access_mode="${run_result#*$'\t'}"
  record_channel_result \
    "$name" \
    "$scope" \
    "$requested_access_mode" \
    "$command" \
    "$actual_access_mode" \
    "$channel_status" \
    "$source_kind"
}

capture_kernel_log_best_effort() {
  local name="$1"
  local scope="$2"
  local root_command="$3"
  local adb_command="$4"
  local output_path stderr_path root_output_path root_stderr_path
  local run_result channel_status actual_access_mode

  output_path="$CHANNEL_DIR/$name.txt"
  stderr_path="$CHANNEL_DIR/$name.stderr.txt"
  root_output_path="$CHANNEL_DIR/$name.root-attempt.txt"
  root_stderr_path="$CHANNEL_DIR/$name.root-attempt.stderr.txt"

  run_result="$(run_device_command "root" "$root_command" "$root_output_path" "$root_stderr_path")"
  channel_status="${run_result%%$'\t'*}"
  actual_access_mode="${run_result#*$'\t'}"

  if [[ "$channel_status" -eq 0 ]]; then
    mv "$root_output_path" "$output_path"
    mv "$root_stderr_path" "$stderr_path"
    record_channel_result \
      "$name" \
      "$scope" \
      "root-preferred" \
      "$root_command" \
      "$actual_access_mode" \
      "$channel_status" \
      "root-dmesg"
    return 0
  fi

  rm -f "$root_output_path" "$root_stderr_path"
  run_result="$(run_device_command "adb" "$adb_command" "$output_path" "$stderr_path")"
  channel_status="${run_result%%$'\t'*}"
  actual_access_mode="${run_result#*$'\t'}"
  record_channel_result \
    "$name" \
    "$scope" \
    "root-preferred" \
    "$adb_command" \
    "$actual_access_mode" \
    "$channel_status" \
    "adb-logcat-kernel"
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
    "$EXPECTED_METADATA_PROBE_REPORT_PATH" \
    "$EXPECTED_METADATA_PROBE_TIMEOUT_CLASS_PATH" \
    "$EXPECTED_METADATA_PROBE_SUMMARY_PATH" \
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
    "$RECOVERED_METADATA_PROBE_FINGERPRINT_STDERR_PATH" \
    "$RECOVERED_METADATA_PROBE_REPORT_PRESENT" \
    "$RECOVERED_METADATA_PROBE_REPORT_ACTUAL_ACCESS_MODE" \
    "$RECOVERED_METADATA_PROBE_REPORT_EXIT_CODE" \
    "$RECOVERED_METADATA_PROBE_REPORT_OUTPUT_PATH" \
    "$RECOVERED_METADATA_PROBE_REPORT_STDERR_PATH" \
    "$RECOVERED_METADATA_PROBE_REPORT_OBSERVED_STAGE" \
    "$RECOVERED_METADATA_PROBE_REPORT_TIMED_OUT" \
    "$RECOVERED_METADATA_PROBE_REPORT_WCHAN" \
    "$RECOVERED_METADATA_PROBE_REPORT_CHILD_COMPLETED" \
    "$RECOVERED_METADATA_PROBE_REPORT_CHILD_EXIT_STATUS" \
    "$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_PRESENT" \
    "$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_ACTUAL_ACCESS_MODE" \
    "$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_EXIT_CODE" \
    "$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_OUTPUT_PATH" \
    "$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_STDERR_PATH" \
    "$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_CHECKPOINT" \
    "$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_BUCKET" \
    "$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_MATCHED_NEEDLE" \
    "$RECOVERED_METADATA_PROBE_TIMEOUT_CLASS_WCHAN" \
    "$RECOVERED_METADATA_PROBE_SUMMARY_PRESENT" \
    "$RECOVERED_METADATA_PROBE_SUMMARY_ACTUAL_ACCESS_MODE" \
    "$RECOVERED_METADATA_PROBE_SUMMARY_EXIT_CODE" \
    "$RECOVERED_METADATA_PROBE_SUMMARY_OUTPUT_PATH" \
    "$RECOVERED_METADATA_PROBE_SUMMARY_STDERR_PATH" \
    "$RECOVERED_METADATA_COMPOSITOR_FRAME_PRESENT" \
    "$RECOVERED_METADATA_COMPOSITOR_FRAME_ACTUAL_ACCESS_MODE" \
    "$RECOVERED_METADATA_COMPOSITOR_FRAME_EXIT_CODE" \
    "$RECOVERED_METADATA_COMPOSITOR_FRAME_OUTPUT_PATH" \
    "$RECOVERED_METADATA_COMPOSITOR_FRAME_STDERR_PATH" <<'PY'
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
expected_metadata_probe_report_path = sys.argv[29]
expected_metadata_probe_timeout_class_path = sys.argv[30]
expected_metadata_probe_summary_path = sys.argv[31]
recovered_metadata_stage_present = sys.argv[32] == "true"
recovered_metadata_stage_value = sys.argv[33]
recovered_metadata_stage_actual_access_mode = sys.argv[34]
recovered_metadata_stage_exit_code = sys.argv[35]
recovered_metadata_stage_output_path = sys.argv[36]
recovered_metadata_stage_stderr_path = sys.argv[37]
recovered_metadata_probe_stage_present = sys.argv[38] == "true"
recovered_metadata_probe_stage_value = sys.argv[39]
recovered_metadata_probe_stage_actual_access_mode = sys.argv[40]
recovered_metadata_probe_stage_exit_code = sys.argv[41]
recovered_metadata_probe_stage_output_path = sys.argv[42]
recovered_metadata_probe_stage_stderr_path = sys.argv[43]
recovered_metadata_probe_fingerprint_present = sys.argv[44] == "true"
recovered_metadata_probe_fingerprint_actual_access_mode = sys.argv[45]
recovered_metadata_probe_fingerprint_exit_code = sys.argv[46]
recovered_metadata_probe_fingerprint_output_path = sys.argv[47]
recovered_metadata_probe_fingerprint_stderr_path = sys.argv[48]
recovered_metadata_probe_report_present = sys.argv[49] == "true"
recovered_metadata_probe_report_actual_access_mode = sys.argv[50]
recovered_metadata_probe_report_exit_code = sys.argv[51]
recovered_metadata_probe_report_output_path = sys.argv[52]
recovered_metadata_probe_report_stderr_path = sys.argv[53]
recovered_metadata_probe_report_observed_stage = sys.argv[54]
recovered_metadata_probe_report_timed_out = sys.argv[55]
recovered_metadata_probe_report_wchan = sys.argv[56]
recovered_metadata_probe_report_child_completed = sys.argv[57]
recovered_metadata_probe_report_child_exit_status = sys.argv[58]
recovered_metadata_probe_timeout_class_present = sys.argv[59] == "true"
recovered_metadata_probe_timeout_class_actual_access_mode = sys.argv[60]
recovered_metadata_probe_timeout_class_exit_code = sys.argv[61]
recovered_metadata_probe_timeout_class_output_path = sys.argv[62]
recovered_metadata_probe_timeout_class_stderr_path = sys.argv[63]
recovered_metadata_probe_timeout_class_checkpoint = sys.argv[64]
recovered_metadata_probe_timeout_class_bucket = sys.argv[65]
recovered_metadata_probe_timeout_class_matched_needle = sys.argv[66]
recovered_metadata_probe_timeout_class_wchan = sys.argv[67]
recovered_metadata_probe_summary_present = sys.argv[68] == "true"
recovered_metadata_probe_summary_actual_access_mode = sys.argv[69]
recovered_metadata_probe_summary_exit_code = sys.argv[70]
recovered_metadata_probe_summary_output_path = sys.argv[71]
recovered_metadata_probe_summary_stderr_path = sys.argv[72]
recovered_metadata_compositor_frame_present = sys.argv[73] == "true"
recovered_metadata_compositor_frame_actual_access_mode = sys.argv[74]
recovered_metadata_compositor_frame_exit_code = sys.argv[75]
recovered_metadata_compositor_frame_output_path = sys.argv[76]
recovered_metadata_compositor_frame_stderr_path = sys.argv[77]
expected_durable_logging = {"kmsg": None, "pmsg": None}
expected_orange_gpu_mode = ""
expected_orange_gpu_scene = ""
expected_orange_gpu_firmware_helper = None
expected_shell_session_start_app_id = ""
expected_app_direct_present_app_id = "rust-demo"
expected_app_direct_present_client_kind = ""
expected_app_direct_present_runtime_bundle_env = ""
expected_app_direct_present_runtime_bundle_path = ""
expected_app_direct_present_typescript_renderer = ""
expected_app_direct_present_manual_touch = False
expected_metadata_compositor_frame_path = ""
expected_payload_probe_strategy = ""
expected_payload_probe_source = ""
expected_payload_probe_root = ""
expected_payload_probe_manifest_path = ""
expected_payload_probe_fallback_path = ""
recovered_probe_summary = {}
recovered_probe_summary_parse_error = None
recovered_compositor_frame_parse_error = None
compositor_frame_width = None
compositor_frame_height = None
compositor_frame_pixel_bytes = None
compositor_frame_distinct_color_count = None
compositor_frame_distinct_color_samples = []
compositor_frame_distinct_color_set = set()
compositor_frame_checksum_sha256 = None

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
        orange_gpu_mode_value = metadata.get("orange_gpu_mode")
        if isinstance(orange_gpu_mode_value, str):
            expected_orange_gpu_mode = orange_gpu_mode_value
        orange_gpu_scene_value = metadata.get("orange_gpu_scene")
        if isinstance(orange_gpu_scene_value, str):
            expected_orange_gpu_scene = orange_gpu_scene_value
        orange_gpu_firmware_helper_value = metadata.get("orange_gpu_firmware_helper")
        if isinstance(orange_gpu_firmware_helper_value, bool):
            expected_orange_gpu_firmware_helper = orange_gpu_firmware_helper_value
        shell_session_start_app_id_value = metadata.get("shell_session_start_app_id")
        if isinstance(shell_session_start_app_id_value, str):
            expected_shell_session_start_app_id = shell_session_start_app_id_value
        app_direct_present_app_id_value = metadata.get("app_direct_present_app_id")
        if isinstance(app_direct_present_app_id_value, str) and app_direct_present_app_id_value:
            expected_app_direct_present_app_id = app_direct_present_app_id_value
        app_direct_present_client_kind_value = metadata.get("app_direct_present_client_kind")
        if isinstance(app_direct_present_client_kind_value, str):
            expected_app_direct_present_client_kind = app_direct_present_client_kind_value
        app_direct_present_runtime_bundle_env_value = metadata.get(
            "app_direct_present_runtime_bundle_env"
        )
        if isinstance(app_direct_present_runtime_bundle_env_value, str):
            expected_app_direct_present_runtime_bundle_env = (
                app_direct_present_runtime_bundle_env_value
            )
        app_direct_present_runtime_bundle_path_value = metadata.get(
            "app_direct_present_runtime_bundle_path"
        )
        if isinstance(app_direct_present_runtime_bundle_path_value, str):
            expected_app_direct_present_runtime_bundle_path = (
                app_direct_present_runtime_bundle_path_value
            )
        app_direct_present_typescript_renderer_value = metadata.get(
            "app_direct_present_typescript_renderer"
        )
        if isinstance(app_direct_present_typescript_renderer_value, str):
            expected_app_direct_present_typescript_renderer = (
                app_direct_present_typescript_renderer_value
            )
        app_direct_present_manual_touch_value = metadata.get("app_direct_present_manual_touch")
        if isinstance(app_direct_present_manual_touch_value, bool):
            expected_app_direct_present_manual_touch = app_direct_present_manual_touch_value
        compositor_frame_path_value = metadata.get("metadata_compositor_frame_path")
        if isinstance(compositor_frame_path_value, str):
            expected_metadata_compositor_frame_path = compositor_frame_path_value
        payload_probe_strategy_value = metadata.get("payload_probe_strategy")
        if isinstance(payload_probe_strategy_value, str):
            expected_payload_probe_strategy = payload_probe_strategy_value
        payload_probe_source_value = metadata.get("payload_probe_source")
        if isinstance(payload_probe_source_value, str):
            expected_payload_probe_source = payload_probe_source_value
        payload_probe_root_value = metadata.get("payload_probe_root")
        if isinstance(payload_probe_root_value, str):
            expected_payload_probe_root = payload_probe_root_value
        payload_probe_manifest_path_value = metadata.get("payload_probe_manifest_path")
        if isinstance(payload_probe_manifest_path_value, str):
            expected_payload_probe_manifest_path = payload_probe_manifest_path_value
        payload_probe_fallback_path_value = metadata.get("payload_probe_fallback_path")
        if isinstance(payload_probe_fallback_path_value, str):
            expected_payload_probe_fallback_path = payload_probe_fallback_path_value

def parse_ppm_artifact(path: Path):
    data = path.read_bytes()
    newline_count = 0
    pixel_offset = None
    for idx, byte in enumerate(data):
        if byte == 0x0A:
            newline_count += 1
            if newline_count == 3:
                pixel_offset = idx + 1
                break
    if pixel_offset is None:
        raise ValueError("missing ppm header terminator")
    header_lines = data[:pixel_offset].decode("ascii").splitlines()
    if len(header_lines) < 3:
        raise ValueError("incomplete ppm header")
    if header_lines[0] != "P6":
        raise ValueError(f"unsupported ppm magic: {header_lines[0]!r}")
    width_text, height_text = header_lines[1].split()
    width = int(width_text)
    height = int(height_text)
    max_value = int(header_lines[2])
    if width <= 0 or height <= 0:
        raise ValueError("ppm dimensions must be positive")
    if max_value != 255:
        raise ValueError(f"unsupported ppm max value {max_value}")
    pixel_data = data[pixel_offset:]
    expected_pixel_bytes = width * height * 3
    if len(pixel_data) != expected_pixel_bytes:
        raise ValueError(
            f"ppm pixel byte count mismatch: expected {expected_pixel_bytes}, got {len(pixel_data)}"
        )
    distinct_colors = set()
    for index in range(0, len(pixel_data), 3):
        distinct_colors.add(pixel_data[index : index + 3].hex())
        if len(distinct_colors) >= 4096:
            break
    distinct_colors = sorted(distinct_colors)
    return {
        "width": width,
        "height": height,
        "pixel_bytes": len(pixel_data),
        "distinct_color_count": len(distinct_colors),
        "distinct_color_samples": distinct_colors[:16],
        "distinct_colors": distinct_colors,
        "checksum_sha256": __import__("hashlib").sha256(pixel_data).hexdigest(),
    }

def parse_kgsl_holder_scan(text: str):
    parsed = {
        "format": None,
        "device_path": None,
        "max_fd_checks": None,
        "max_holders": None,
        "pid_count": None,
        "fd_checks": None,
        "holder_count": 0,
        "has_holders": False,
        "truncated": None,
        "holders": [],
        "parse_error": None,
    }
    try:
        for raw_line in text.splitlines():
            if not raw_line:
                continue
            parts = raw_line.split("\t")
            kind = parts[0]
            if kind == "format" and len(parts) >= 2:
                parsed["format"] = parts[1]
            elif kind == "device_path" and len(parts) >= 2:
                parsed["device_path"] = parts[1]
            elif kind == "limits" and len(parts) >= 3:
                parsed["max_fd_checks"] = int(parts[1])
                parsed["max_holders"] = int(parts[2])
            elif kind == "holder" and len(parts) >= 5:
                parsed["holders"].append(
                    {
                        "pid": int(parts[1]),
                        "fd": int(parts[2]),
                        "comm": parts[3],
                        "cmdline": parts[4],
                    }
                )
            elif kind == "summary" and len(parts) >= 5:
                parsed["pid_count"] = int(parts[1])
                parsed["fd_checks"] = int(parts[2])
                parsed["holder_count"] = int(parts[3])
                parsed["truncated"] = parts[4] == "true"
    except ValueError as exc:
        parsed["parse_error"] = str(exc)

    if parsed["holder_count"] == 0 and parsed["holders"]:
        parsed["holder_count"] = len(parsed["holders"])
    parsed["has_holders"] = parsed["holder_count"] > 0
    return parsed

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
android_has_kgsl_holders = None
android_kgsl_holder_count = None

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
            "source_kind": row.get("source_kind", ""),
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
        if row["name"] == "kgsl-holder-scan":
            entry.update(parse_kgsl_holder_scan(output_text))
            if available:
                android_has_kgsl_holders = entry["has_holders"]
                android_kgsl_holder_count = entry["holder_count"]
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

probe_report_child_completed = recovered_metadata_probe_report_child_completed == "true"
probe_report_child_exit_status = (
    int(recovered_metadata_probe_report_child_exit_status)
    if recovered_metadata_probe_report_child_exit_status not in ("", None)
    else None
)
probe_report_proves_child_success = (
    recovered_metadata_probe_report_present
    and probe_report_child_completed
    and recovered_metadata_probe_report_timed_out == "false"
    and probe_report_child_exit_status == 0
)
probe_report_proves_child_timeout = (
    recovered_metadata_probe_report_present
    and not probe_report_child_completed
    and recovered_metadata_probe_report_timed_out == "true"
    and probe_report_child_exit_status is None
)
if recovered_metadata_probe_summary_present and recovered_metadata_probe_summary_output_path:
    summary_path = channel_status_path.parent / recovered_metadata_probe_summary_output_path
    if summary_path.exists():
        try:
            recovered_probe_summary = json.loads(
                summary_path.read_text(encoding="utf-8", errors="replace")
            )
        except json.JSONDecodeError as exc:
            recovered_probe_summary = {}
            recovered_probe_summary_parse_error = str(exc)

summary_scene = recovered_probe_summary.get("scene")
summary_present_kms = recovered_probe_summary.get("present_kms")
summary_kms_present = recovered_probe_summary.get("kms_present")
summary_software_backed = recovered_probe_summary.get("software_backed")
summary_distinct_color_count = recovered_probe_summary.get("distinct_color_count")
summary_checksum = recovered_probe_summary.get("checksum_fnv1a64")
summary_color_samples = recovered_probe_summary.get("distinct_color_samples_rgba8")
summary_adapter = recovered_probe_summary.get("adapter")
summary_mode = recovered_probe_summary.get("mode")
summary_kind = recovered_probe_summary.get("kind")
summary_ok = recovered_probe_summary.get("ok")
summary_startup_mode = recovered_probe_summary.get("startup_mode")
summary_app_id = recovered_probe_summary.get("app_id")
summary_frame_path = recovered_probe_summary.get("frame_path")
summary_frame_bytes = recovered_probe_summary.get("frame_bytes")
summary_payload_strategy = recovered_probe_summary.get("payload_strategy")
summary_payload_source = recovered_probe_summary.get("payload_source")
summary_payload_root = recovered_probe_summary.get("payload_root")
summary_payload_manifest_path = recovered_probe_summary.get("payload_manifest_path")
summary_payload_marker_path = recovered_probe_summary.get("payload_marker_path")
summary_payload_version = recovered_probe_summary.get("payload_version")
summary_payload_fingerprint = recovered_probe_summary.get("payload_fingerprint")
summary_payload_marker_fingerprint = recovered_probe_summary.get("payload_marker_fingerprint")
summary_payload_fingerprint_verified = recovered_probe_summary.get("payload_fingerprint_verified")
summary_payload_mounted_roots = recovered_probe_summary.get("mounted_roots")
summary_payload_userdata_mount_error = recovered_probe_summary.get("userdata_mount_error")
summary_payload_shadow_logical_mount_error = recovered_probe_summary.get(
    "shadow_logical_mount_error"
)
summary_payload_fallback_path = recovered_probe_summary.get("fallback_path")
summary_payload_blocker = recovered_probe_summary.get("blocker")
summary_payload_blocker_detail = recovered_probe_summary.get("blocker_detail")
summary_target_duration_secs = recovered_probe_summary.get("target_duration_secs")
summary_frame_interval_millis = recovered_probe_summary.get("frame_interval_millis")
summary_frames_rendered = recovered_probe_summary.get("frames_rendered")
summary_scanout_updates = recovered_probe_summary.get("scanout_updates")
summary_distinct_frame_count = recovered_probe_summary.get("distinct_frame_count")
summary_frame_label_samples = recovered_probe_summary.get("frame_label_samples")
summary_frame_checksum_samples = recovered_probe_summary.get("frame_checksum_samples_fnv1a64")
summary_first_frame = recovered_probe_summary.get("first_frame")
summary_last_frame = recovered_probe_summary.get("last_frame")
summary_touch_counter_probe = recovered_probe_summary.get("touch_counter_probe")
summary_touch_counter_probe_ok = recovered_probe_summary.get("touch_counter_probe_ok")
summary_shell_session_probe = recovered_probe_summary.get("shell_session_probe")
summary_shell_session_probe_ok = recovered_probe_summary.get("shell_session_probe_ok")
summary_adapter_backend = (
    summary_adapter.get("backend")
    if isinstance(summary_adapter, dict)
    else None
)
summary_touch_counter_injection = (
    summary_touch_counter_probe.get("injection")
    if isinstance(summary_touch_counter_probe, dict)
    else None
)
summary_touch_counter_input_observed = (
    summary_touch_counter_probe.get("input_observed")
    if isinstance(summary_touch_counter_probe, dict)
    else None
)
summary_touch_counter_tap_dispatched = (
    summary_touch_counter_probe.get("tap_dispatched")
    if isinstance(summary_touch_counter_probe, dict)
    else None
)
summary_touch_counter_counter_incremented = (
    summary_touch_counter_probe.get("counter_incremented")
    if isinstance(summary_touch_counter_probe, dict)
    else None
)
summary_touch_counter_post_touch_frame_committed = (
    summary_touch_counter_probe.get("post_touch_frame_committed")
    if isinstance(summary_touch_counter_probe, dict)
    else None
)
summary_touch_counter_post_touch_frame_artifact_logged = (
    summary_touch_counter_probe.get("post_touch_frame_artifact_logged")
    if isinstance(summary_touch_counter_probe, dict)
    else None
)
summary_touch_counter_touch_latency_present = (
    summary_touch_counter_probe.get("touch_latency_present")
    if isinstance(summary_touch_counter_probe, dict)
    else None
)
summary_touch_counter_post_touch_frame_captured = (
    summary_touch_counter_probe.get("post_touch_frame_captured")
    if isinstance(summary_touch_counter_probe, dict)
    else None
)
summary_shell_session_shell_mode_enabled = (
    summary_shell_session_probe.get("shell_mode_enabled")
    if isinstance(summary_shell_session_probe, dict)
    else None
)
summary_shell_session_home_frame_done = (
    summary_shell_session_probe.get("home_frame_done")
    if isinstance(summary_shell_session_probe, dict)
    else None
)
summary_shell_session_start_app_requested = (
    summary_shell_session_probe.get("start_app_requested")
    if isinstance(summary_shell_session_probe, dict)
    else None
)
summary_shell_session_app_launch_mode_logged = (
    summary_shell_session_probe.get("app_launch_mode_logged")
    if isinstance(summary_shell_session_probe, dict)
    else None
)
summary_shell_session_mapped_window = (
    summary_shell_session_probe.get("mapped_window")
    if isinstance(summary_shell_session_probe, dict)
    else None
)
summary_shell_session_surface_app_tracked = (
    summary_shell_session_probe.get("surface_app_tracked")
    if isinstance(summary_shell_session_probe, dict)
    else None
)
summary_shell_session_app_frame_artifact_logged = (
    summary_shell_session_probe.get("app_frame_artifact_logged")
    if isinstance(summary_shell_session_probe, dict)
    else None
)
summary_shell_session_app_frame_captured = (
    summary_shell_session_probe.get("app_frame_captured")
    if isinstance(summary_shell_session_probe, dict)
    else None
)
summary_kms_present_count = (
    summary_kms_present.get("present_count")
    if isinstance(summary_kms_present, dict)
    else None
)
summary_first_frame_label = (
    summary_first_frame.get("label")
    if isinstance(summary_first_frame, dict)
    else None
)
summary_first_frame_distinct_color_count = (
    summary_first_frame.get("distinct_color_count")
    if isinstance(summary_first_frame, dict)
    else None
)
summary_first_frame_color_samples = (
    summary_first_frame.get("distinct_color_samples_rgba8")
    if isinstance(summary_first_frame, dict)
    else None
)
summary_last_frame_checksum = (
    summary_last_frame.get("checksum_fnv1a64")
    if isinstance(summary_last_frame, dict)
    else None
)
required_gpu_render_samples = {"ff7a00ff"}
required_app_direct_present_distinct_color_count = 3
required_app_direct_present_frame_samples = set()
if expected_orange_gpu_mode == "shell-session-runtime-touch-counter" or (
    expected_orange_gpu_mode == "shell-session-held"
    and expected_app_direct_present_app_id == "counter"
):
    required_app_direct_present_frame_samples = {
        "1b1208",
        "181616",
        "eeecec",
    }
elif expected_orange_gpu_mode == "shell-session" and expected_app_direct_present_app_id == "counter":
    required_app_direct_present_frame_samples = {
        "30160b",
        "ffb82f",
        "ffda89",
    }
elif expected_orange_gpu_mode == "app-direct-present-runtime-touch-counter":
    required_app_direct_present_frame_samples = {
        "2a1209",
        "ff8a42",
        "ffe0a6",
    }
elif expected_app_direct_present_app_id == "rust-demo":
    required_app_direct_present_frame_samples = {
        "17362c",
        "74d3ae",
        "f7fafc",
    }
elif expected_app_direct_present_app_id == "counter":
    required_app_direct_present_frame_samples = {
        "0b1630",
        "10243b",
        "2fb8ff",
    }
elif expected_app_direct_present_app_id == "timeline":
    required_app_direct_present_frame_samples = {
        "311f09",
        "2b180e",
        "322008",
    }
summary_samples_set = (
    set(sample for sample in summary_color_samples if isinstance(sample, str))
    if isinstance(summary_color_samples, list)
    else set()
)
summary_loop_label_samples_set = (
    set(sample for sample in summary_frame_label_samples if isinstance(sample, str))
    if isinstance(summary_frame_label_samples, list)
    else set()
)
summary_loop_checksum_samples_set = (
    set(sample for sample in summary_frame_checksum_samples if isinstance(sample, str))
    if isinstance(summary_frame_checksum_samples, list)
    else set()
)
summary_first_frame_color_samples_set = (
    set(sample for sample in summary_first_frame_color_samples if isinstance(sample, str))
    if isinstance(summary_first_frame_color_samples, list)
    else set()
)
probe_summary_proves_gpu_render = (
    expected_orange_gpu_mode == "gpu-render"
    and expected_orange_gpu_firmware_helper is True
    and probe_report_proves_child_success
    and recovered_metadata_probe_summary_present
    and recovered_probe_summary_parse_error is None
    and summary_scene == (expected_orange_gpu_scene or "flat-orange")
    and summary_present_kms is True
    and isinstance(summary_kms_present, dict)
    and summary_software_backed is False
    and summary_adapter_backend == "Vulkan"
    and summary_distinct_color_count == 1
    and required_gpu_render_samples.issubset(summary_samples_set)
    and isinstance(summary_checksum, str)
    and bool(summary_checksum)
)
probe_summary_proves_orange_gpu_loop = (
    expected_orange_gpu_mode == "orange-gpu-loop"
    and expected_orange_gpu_firmware_helper is True
    and probe_report_proves_child_success
    and recovered_metadata_probe_summary_present
    and recovered_probe_summary_parse_error is None
    and summary_mode == "orange-gpu-loop"
    and summary_scene == (expected_orange_gpu_scene or "orange-gpu-loop")
    and summary_present_kms is True
    and isinstance(summary_kms_present, dict)
    and summary_software_backed is False
    and summary_adapter_backend == "Vulkan"
    and isinstance(summary_target_duration_secs, int)
    and summary_target_duration_secs >= 2
    and isinstance(summary_frame_interval_millis, int)
    and summary_frame_interval_millis > 0
    and isinstance(summary_frames_rendered, int)
    and summary_frames_rendered >= 2
    and isinstance(summary_scanout_updates, int)
    and summary_scanout_updates >= 2
    and summary_scanout_updates == summary_frames_rendered
    and isinstance(summary_kms_present_count, int)
    and summary_kms_present_count == summary_scanout_updates
    and isinstance(summary_distinct_frame_count, int)
    and summary_distinct_frame_count >= 2
    and {"flat-orange", "smoke"}.issubset(summary_loop_label_samples_set)
    and len(summary_loop_checksum_samples_set) >= 2
    and summary_first_frame_label == "flat-orange"
    and summary_first_frame_distinct_color_count == 1
    and required_gpu_render_samples.issubset(summary_first_frame_color_samples_set)
    and isinstance(summary_last_frame_checksum, str)
    and bool(summary_last_frame_checksum)
)
if recovered_metadata_compositor_frame_present and recovered_metadata_compositor_frame_output_path:
    compositor_frame_path = channel_status_path.parent / recovered_metadata_compositor_frame_output_path
    if compositor_frame_path.exists():
        try:
            compositor_frame_summary = parse_ppm_artifact(compositor_frame_path)
        except ValueError as exc:
            recovered_compositor_frame_parse_error = str(exc)
        else:
            compositor_frame_width = compositor_frame_summary["width"]
            compositor_frame_height = compositor_frame_summary["height"]
            compositor_frame_pixel_bytes = compositor_frame_summary["pixel_bytes"]
            compositor_frame_distinct_color_count = compositor_frame_summary["distinct_color_count"]
            compositor_frame_distinct_color_samples = compositor_frame_summary["distinct_color_samples"]
            compositor_frame_distinct_color_set = set(
                compositor_frame_summary["distinct_colors"]
            )
            compositor_frame_checksum_sha256 = compositor_frame_summary["checksum_sha256"]
probe_summary_proves_compositor_scene = (
    expected_orange_gpu_mode == "compositor-scene"
    and expected_orange_gpu_firmware_helper is True
    and probe_report_proves_child_success
    and recovered_metadata_probe_summary_present
    and recovered_probe_summary_parse_error is None
    and summary_kind == "compositor-scene"
    and summary_frame_path == expected_metadata_compositor_frame_path
    and isinstance(summary_frame_bytes, int)
    and summary_frame_bytes > 0
)
probe_summary_proves_shell_session = (
    expected_orange_gpu_mode == "shell-session"
    and expected_orange_gpu_firmware_helper is True
    and probe_report_proves_child_success
    and recovered_metadata_probe_summary_present
    and recovered_probe_summary_parse_error is None
    and summary_kind == "shell-session"
    and summary_startup_mode == "shell"
    and summary_app_id == expected_shell_session_start_app_id
    and summary_frame_path == expected_metadata_compositor_frame_path
    and isinstance(summary_frame_bytes, int)
    and summary_frame_bytes > 0
    and summary_shell_session_probe_ok is True
    and summary_shell_session_shell_mode_enabled is True
    and summary_shell_session_home_frame_done is True
    and summary_shell_session_start_app_requested is True
    and summary_shell_session_app_launch_mode_logged is True
    and summary_shell_session_mapped_window is True
    and summary_shell_session_surface_app_tracked is True
    and summary_shell_session_app_frame_artifact_logged is True
    and summary_shell_session_app_frame_captured is True
)
probe_summary_proves_shell_session_held = (
    expected_orange_gpu_mode == "shell-session-held"
    and expected_orange_gpu_firmware_helper is True
    and probe_report_proves_child_timeout
    and recovered_metadata_probe_summary_present
    and recovered_probe_summary_parse_error is None
    and summary_kind == "shell-session-held"
    and summary_startup_mode == "shell"
    and summary_app_id == expected_shell_session_start_app_id
    and summary_frame_path == expected_metadata_compositor_frame_path
    and isinstance(summary_frame_bytes, int)
    and summary_frame_bytes > 0
    and summary_shell_session_probe_ok is True
    and summary_shell_session_shell_mode_enabled is True
    and summary_shell_session_home_frame_done is True
    and summary_shell_session_start_app_requested is True
    and summary_shell_session_app_launch_mode_logged is True
    and summary_shell_session_mapped_window is True
    and summary_shell_session_surface_app_tracked is True
    and summary_shell_session_app_frame_artifact_logged is True
    and summary_shell_session_app_frame_captured is True
)
expected_touch_counter_injection = (
    "physical-touch"
    if expected_app_direct_present_manual_touch
    else "synthetic-compositor"
)
shell_session_held_requires_touch_counter = (
    expected_orange_gpu_mode == "shell-session-held"
    and expected_shell_session_start_app_id == "counter"
    and expected_app_direct_present_client_kind == "typescript"
)
probe_summary_proves_shell_session_held_touch_counter = (
    shell_session_held_requires_touch_counter
    and probe_summary_proves_shell_session_held
    and summary_touch_counter_probe_ok is True
    and summary_touch_counter_injection == expected_touch_counter_injection
    and summary_touch_counter_input_observed is True
    and summary_touch_counter_tap_dispatched is True
    and summary_touch_counter_counter_incremented is True
    and summary_touch_counter_post_touch_frame_committed is True
    and summary_touch_counter_post_touch_frame_artifact_logged is True
    and summary_touch_counter_touch_latency_present is True
    and summary_touch_counter_post_touch_frame_captured is True
)
probe_summary_proves_shell_session_runtime_touch_counter = (
    expected_orange_gpu_mode == "shell-session-runtime-touch-counter"
    and expected_orange_gpu_firmware_helper is True
    and probe_report_proves_child_success
    and recovered_metadata_probe_summary_present
    and recovered_probe_summary_parse_error is None
    and summary_kind == "shell-session-runtime-touch-counter"
    and summary_startup_mode == "shell"
    and summary_app_id == expected_shell_session_start_app_id
    and summary_app_id == expected_app_direct_present_app_id
    and summary_app_id == "counter"
    and summary_frame_path == expected_metadata_compositor_frame_path
    and isinstance(summary_frame_bytes, int)
    and summary_frame_bytes > 0
    and summary_shell_session_probe_ok is True
    and summary_shell_session_shell_mode_enabled is True
    and summary_shell_session_home_frame_done is True
    and summary_shell_session_start_app_requested is True
    and summary_shell_session_app_launch_mode_logged is True
    and summary_shell_session_mapped_window is True
    and summary_shell_session_surface_app_tracked is True
    and summary_shell_session_app_frame_artifact_logged is True
    and summary_shell_session_app_frame_captured is True
    and summary_touch_counter_probe_ok is True
    and summary_touch_counter_injection == expected_touch_counter_injection
    and summary_touch_counter_input_observed is True
    and summary_touch_counter_tap_dispatched is True
    and summary_touch_counter_counter_incremented is True
    and summary_touch_counter_post_touch_frame_committed is True
    and summary_touch_counter_post_touch_frame_artifact_logged is True
    and summary_touch_counter_touch_latency_present is True
    and summary_touch_counter_post_touch_frame_captured is True
)
probe_summary_proves_app_direct_present = (
    expected_orange_gpu_mode == "app-direct-present"
    and expected_orange_gpu_firmware_helper is True
    and probe_report_proves_child_success
    and recovered_metadata_probe_summary_present
    and recovered_probe_summary_parse_error is None
    and summary_kind == "app-direct-present"
    and summary_startup_mode == "app"
    and summary_app_id == expected_app_direct_present_app_id
    and summary_frame_path == expected_metadata_compositor_frame_path
    and isinstance(summary_frame_bytes, int)
    and summary_frame_bytes > 0
)
probe_summary_proves_app_direct_present_touch_counter = (
    expected_orange_gpu_mode == "app-direct-present-touch-counter"
    and expected_orange_gpu_firmware_helper is True
    and probe_report_proves_child_success
    and recovered_metadata_probe_summary_present
    and recovered_probe_summary_parse_error is None
    and summary_kind == "app-direct-present-touch-counter"
    and summary_startup_mode == "app"
    and summary_app_id == "rust-demo"
    and summary_frame_path == expected_metadata_compositor_frame_path
    and isinstance(summary_frame_bytes, int)
    and summary_frame_bytes > 0
    and summary_touch_counter_probe_ok is True
    and summary_touch_counter_injection == expected_touch_counter_injection
    and summary_touch_counter_input_observed is True
    and summary_touch_counter_tap_dispatched is True
    and summary_touch_counter_counter_incremented is True
    and summary_touch_counter_post_touch_frame_committed is True
    and summary_touch_counter_post_touch_frame_artifact_logged is True
    and summary_touch_counter_touch_latency_present is True
    and summary_touch_counter_post_touch_frame_captured is True
)
probe_summary_proves_app_direct_present_runtime_touch_counter = (
    expected_orange_gpu_mode == "app-direct-present-runtime-touch-counter"
    and expected_orange_gpu_firmware_helper is True
    and probe_report_proves_child_success
    and recovered_metadata_probe_summary_present
    and recovered_probe_summary_parse_error is None
    and summary_kind == "app-direct-present-runtime-touch-counter"
    and summary_startup_mode == "app"
    and summary_app_id == "counter"
    and summary_frame_path == expected_metadata_compositor_frame_path
    and isinstance(summary_frame_bytes, int)
    and summary_frame_bytes > 0
    and summary_touch_counter_probe_ok is True
    and summary_touch_counter_injection == expected_touch_counter_injection
    and summary_touch_counter_input_observed is True
    and summary_touch_counter_tap_dispatched is True
    and summary_touch_counter_counter_incremented is True
    and summary_touch_counter_post_touch_frame_committed is True
    and summary_touch_counter_post_touch_frame_artifact_logged is True
    and summary_touch_counter_touch_latency_present is True
    and summary_touch_counter_post_touch_frame_captured is True
)
payload_probe_root_is_metadata = isinstance(
    expected_payload_probe_root, str
) and expected_payload_probe_root.startswith("/metadata/shadow-payload/by-token/")
payload_probe_root_is_data = isinstance(
    expected_payload_probe_root, str
) and expected_payload_probe_root.startswith("/data/local/tmp/shadow-payload/by-token/")
payload_probe_root_is_shadow_logical = (
    isinstance(expected_payload_probe_root, str)
    and expected_payload_probe_root == "/shadow-payload"
)
payload_probe_source_matches_root = (
    (
        expected_payload_probe_source == "metadata"
        and (payload_probe_root_is_metadata or payload_probe_root_is_data)
    )
    or (
        expected_payload_probe_source == "shadow-logical-partition"
        and payload_probe_root_is_shadow_logical
    )
)
expected_metadata_payload_manifest_path = (
    f"/metadata/shadow-payload/by-token/{expected_run_token}/manifest.env"
)
payload_probe_manifest_path_matches_root = (
    payload_probe_root_is_metadata
    and expected_payload_probe_manifest_path == f"{expected_payload_probe_root}/manifest.env"
)
payload_probe_manifest_path_matches_control_plane = (
    payload_probe_root_is_data
    and bool(expected_run_token)
    and expected_payload_probe_manifest_path == expected_metadata_payload_manifest_path
)
payload_probe_manifest_path_matches_shadow_logical = (
    payload_probe_root_is_shadow_logical
    and expected_payload_probe_manifest_path == "/shadow-payload/manifest.env"
)
payload_probe_mount_roots_proven = (
    isinstance(summary_payload_mounted_roots, list)
    and "/metadata" in summary_payload_mounted_roots
    and (
        payload_probe_root_is_metadata
        or (
            payload_probe_root_is_data
            and "/data" in summary_payload_mounted_roots
            and summary_payload_userdata_mount_error in ("", None)
        )
        or (
            payload_probe_root_is_shadow_logical
            and "/shadow-payload" in summary_payload_mounted_roots
            and summary_payload_shadow_logical_mount_error in ("", None)
        )
    )
)
probe_summary_proves_payload_partition = (
    expected_orange_gpu_mode == "payload-partition-probe"
    and recovered_metadata_probe_summary_present
    and recovered_probe_summary_parse_error is None
    and summary_kind == "payload-partition-probe"
    and summary_ok is True
    and expected_payload_probe_strategy == "metadata-shadow-payload-v1"
    and expected_payload_probe_source in ("metadata", "shadow-logical-partition")
    and payload_probe_source_matches_root
    and (
        payload_probe_root_is_metadata
        or payload_probe_root_is_data
        or payload_probe_root_is_shadow_logical
    )
    and (
        payload_probe_manifest_path_matches_root
        or payload_probe_manifest_path_matches_control_plane
        or payload_probe_manifest_path_matches_shadow_logical
    )
    and expected_payload_probe_fallback_path == "/orange-gpu"
    and summary_payload_strategy == expected_payload_probe_strategy
    and summary_payload_source == expected_payload_probe_source
    and isinstance(summary_payload_root, str)
    and summary_payload_root == expected_payload_probe_root
    and isinstance(summary_payload_manifest_path, str)
    and summary_payload_manifest_path == expected_payload_probe_manifest_path
    and isinstance(summary_payload_marker_path, str)
    and summary_payload_marker_path == f"{expected_payload_probe_root}/payload.txt"
    and isinstance(summary_payload_version, str)
    and bool(summary_payload_version)
    and isinstance(summary_payload_fingerprint, str)
    and summary_payload_fingerprint.startswith("sha256:")
    and summary_payload_marker_fingerprint == summary_payload_fingerprint
    and summary_payload_fingerprint_verified is True
    and payload_probe_mount_roots_proven
    and summary_payload_fallback_path == expected_payload_probe_fallback_path
    and summary_payload_blocker == "none"
)
compositor_frame_proves_scene = (
    expected_orange_gpu_mode == "compositor-scene"
    and recovered_metadata_compositor_frame_present
    and recovered_compositor_frame_parse_error is None
    and isinstance(compositor_frame_width, int)
    and compositor_frame_width > 0
    and isinstance(compositor_frame_height, int)
    and compositor_frame_height > 0
    and isinstance(compositor_frame_pixel_bytes, int)
    and compositor_frame_pixel_bytes > 0
    and isinstance(compositor_frame_distinct_color_count, int)
    and compositor_frame_distinct_color_count > 1
    and isinstance(compositor_frame_checksum_sha256, str)
    and bool(compositor_frame_checksum_sha256)
    and summary_frame_bytes == compositor_frame_pixel_bytes + len(
        f"P6\n{compositor_frame_width} {compositor_frame_height}\n255\n".encode("ascii")
    )
)
compositor_frame_proves_shell_session_app = (
    expected_orange_gpu_mode
    in {"shell-session", "shell-session-held", "shell-session-runtime-touch-counter"}
    and recovered_metadata_compositor_frame_present
    and recovered_compositor_frame_parse_error is None
    and isinstance(compositor_frame_width, int)
    and compositor_frame_width > 0
    and isinstance(compositor_frame_height, int)
    and compositor_frame_height > 0
    and isinstance(compositor_frame_pixel_bytes, int)
    and compositor_frame_pixel_bytes > 0
    and isinstance(compositor_frame_distinct_color_count, int)
    and compositor_frame_distinct_color_count >= 3
    and isinstance(compositor_frame_checksum_sha256, str)
    and bool(compositor_frame_checksum_sha256)
    and summary_frame_bytes == compositor_frame_pixel_bytes + len(
        f"P6\n{compositor_frame_width} {compositor_frame_height}\n255\n".encode("ascii")
    )
)
compositor_frame_proves_app_direct_present = (
    expected_orange_gpu_mode
    in {
        "shell-session",
        "shell-session-held",
        "shell-session-runtime-touch-counter",
        "app-direct-present",
        "app-direct-present-touch-counter",
        "app-direct-present-runtime-touch-counter",
    }
    and recovered_metadata_compositor_frame_present
    and recovered_compositor_frame_parse_error is None
    and isinstance(compositor_frame_width, int)
    and compositor_frame_width > 0
    and isinstance(compositor_frame_height, int)
    and compositor_frame_height > 0
    and isinstance(compositor_frame_pixel_bytes, int)
    and compositor_frame_pixel_bytes > 0
    and isinstance(compositor_frame_distinct_color_count, int)
    and compositor_frame_distinct_color_count >= max(
        required_app_direct_present_distinct_color_count,
        len(required_app_direct_present_frame_samples),
    )
    and required_app_direct_present_frame_samples.issubset(compositor_frame_distinct_color_set)
    and isinstance(compositor_frame_checksum_sha256, str)
    and bool(compositor_frame_checksum_sha256)
    and summary_frame_bytes == compositor_frame_pixel_bytes + len(
        f"P6\n{compositor_frame_width} {compositor_frame_height}\n255\n".encode("ascii")
    )
)
app_direct_present_proof_contract = {
    "app_id": expected_app_direct_present_app_id,
    "client_kind": expected_app_direct_present_client_kind,
    "typescript_renderer": expected_app_direct_present_typescript_renderer,
    "runtime_bundle_env": expected_app_direct_present_runtime_bundle_env,
    "runtime_bundle_path": expected_app_direct_present_runtime_bundle_path,
    "expected_frame_path": expected_metadata_compositor_frame_path,
    "probe_summary_frame_path": summary_frame_path,
    "recovered_frame_output_path": recovered_metadata_compositor_frame_output_path,
}
app_direct_present_proof_contract_summary = ",".join(
    [
        f"app_id={expected_app_direct_present_app_id}",
        f"client_kind={expected_app_direct_present_client_kind}",
        f"typescript_renderer={expected_app_direct_present_typescript_renderer}",
        f"runtime_bundle_env={expected_app_direct_present_runtime_bundle_env}",
        f"runtime_bundle_path={expected_app_direct_present_runtime_bundle_path}",
        f"expected_frame_path={expected_metadata_compositor_frame_path}",
        f"probe_summary_frame_path={summary_frame_path or ''}",
        f"recovered_frame_output_path={recovered_metadata_compositor_frame_output_path}",
    ]
)
app_direct_present_proof_contract_ok = (
    expected_orange_gpu_mode
    not in {
        "shell-session",
        "shell-session-held",
        "shell-session-runtime-touch-counter",
        "app-direct-present",
        "app-direct-present-runtime-touch-counter",
    }
    or (
        bool(expected_app_direct_present_app_id)
        and expected_app_direct_present_client_kind in {"rust", "typescript"}
        and bool(expected_metadata_compositor_frame_path)
        and (
            expected_app_direct_present_client_kind != "typescript"
            or (
                expected_app_direct_present_typescript_renderer in {"cpu", "gpu"}
                and bool(expected_app_direct_present_runtime_bundle_env)
                and bool(expected_app_direct_present_runtime_bundle_path)
            )
        )
    )
)
app_direct_present_proof_contract_required = (
    expected_orange_gpu_mode
    in {
        "shell-session",
        "shell-session-held",
        "shell-session-runtime-touch-counter",
        "app-direct-present",
        "app-direct-present-runtime-touch-counter",
    }
    and (
        expected_app_direct_present_app_id != "rust-demo"
        or bool(expected_app_direct_present_client_kind)
        or bool(expected_app_direct_present_runtime_bundle_env)
        or bool(expected_app_direct_present_runtime_bundle_path)
        or bool(expected_app_direct_present_typescript_renderer)
    )
)
shell_session_requires_app_direct_frame_samples = (
    expected_app_direct_present_client_kind != "rust"
)
if expected_orange_gpu_mode == "gpu-render":
    proof_ok = probe_summary_proves_gpu_render
elif expected_orange_gpu_mode == "orange-gpu-loop":
    proof_ok = probe_summary_proves_orange_gpu_loop
elif expected_orange_gpu_mode == "compositor-scene":
    proof_ok = probe_summary_proves_compositor_scene and compositor_frame_proves_scene
elif expected_orange_gpu_mode == "shell-session":
    proof_ok = (
        app_direct_present_proof_contract_ok
        and probe_summary_proves_shell_session
        and compositor_frame_proves_shell_session_app
        and (
            not shell_session_requires_app_direct_frame_samples
            or compositor_frame_proves_app_direct_present
        )
    )
elif expected_orange_gpu_mode == "shell-session-held":
    proof_ok = (
        app_direct_present_proof_contract_ok
        and probe_summary_proves_shell_session_held
        and (
            not shell_session_held_requires_touch_counter
            or probe_summary_proves_shell_session_held_touch_counter
        )
        and compositor_frame_proves_shell_session_app
        and (
            not shell_session_requires_app_direct_frame_samples
            or compositor_frame_proves_app_direct_present
        )
    )
elif expected_orange_gpu_mode == "shell-session-runtime-touch-counter":
    proof_ok = (
        app_direct_present_proof_contract_ok
        and probe_summary_proves_shell_session_runtime_touch_counter
        and compositor_frame_proves_shell_session_app
        and (
            not shell_session_requires_app_direct_frame_samples
            or compositor_frame_proves_app_direct_present
        )
    )
elif expected_orange_gpu_mode == "app-direct-present":
    proof_ok = (
        (not app_direct_present_proof_contract_required or app_direct_present_proof_contract_ok)
        and probe_summary_proves_app_direct_present
        and compositor_frame_proves_app_direct_present
    )
elif expected_orange_gpu_mode == "app-direct-present-touch-counter":
    proof_ok = (
        probe_summary_proves_app_direct_present_touch_counter
        and compositor_frame_proves_app_direct_present
    )
elif expected_orange_gpu_mode == "app-direct-present-runtime-touch-counter":
    proof_ok = (
        app_direct_present_proof_contract_ok
        and probe_summary_proves_app_direct_present_runtime_touch_counter
        and compositor_frame_proves_app_direct_present
    )
elif expected_orange_gpu_mode == "payload-partition-probe":
    proof_ok = probe_summary_proves_payload_partition
else:
    proof_ok = matched_any_correlated_shadow_tags or probe_report_proves_child_success

payload = {
    "kind": "boot_trace_recovery",
    "ok": True,
    "proof_ok": proof_ok,
    "matched_correlated_trace": matched_any_correlated_shadow_tags,
    "probe_report_proves_child_success": probe_report_proves_child_success,
    "probe_report_proves_child_timeout": probe_report_proves_child_timeout,
    "probe_summary_proves_gpu_render": probe_summary_proves_gpu_render,
    "probe_summary_proves_orange_gpu_loop": probe_summary_proves_orange_gpu_loop,
    "probe_summary_proves_compositor_scene": probe_summary_proves_compositor_scene,
    "probe_summary_proves_shell_session": probe_summary_proves_shell_session,
    "probe_summary_proves_shell_session_held": probe_summary_proves_shell_session_held,
    "probe_summary_proves_shell_session_held_touch_counter": probe_summary_proves_shell_session_held_touch_counter,
    "probe_summary_proves_shell_session_runtime_touch_counter": probe_summary_proves_shell_session_runtime_touch_counter,
    "probe_summary_proves_app_direct_present": probe_summary_proves_app_direct_present,
    "probe_summary_proves_app_direct_present_touch_counter": probe_summary_proves_app_direct_present_touch_counter,
    "probe_summary_proves_app_direct_present_runtime_touch_counter": probe_summary_proves_app_direct_present_runtime_touch_counter,
    "probe_summary_proves_payload_partition": probe_summary_proves_payload_partition,
    "app_direct_present_proof_contract_ok": app_direct_present_proof_contract_ok,
    "app_direct_present_proof_contract_required": app_direct_present_proof_contract_required,
    "app_direct_present_proof_contract": app_direct_present_proof_contract,
    "app_direct_present_proof_contract_summary": app_direct_present_proof_contract_summary,
    "shell_session_requires_app_direct_frame_samples": shell_session_requires_app_direct_frame_samples,
    "shell_session_held_requires_touch_counter": shell_session_held_requires_touch_counter,
        "metadata_compositor_frame_proves_scene": compositor_frame_proves_scene,
        "metadata_compositor_frame_proves_shell_session_app": compositor_frame_proves_shell_session_app,
        "metadata_compositor_frame_proves_app_direct_present": compositor_frame_proves_app_direct_present,
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
    "expected_orange_gpu_mode": expected_orange_gpu_mode,
    "expected_orange_gpu_scene": expected_orange_gpu_scene,
    "expected_orange_gpu_firmware_helper": expected_orange_gpu_firmware_helper,
    "expected_shell_session_start_app_id": expected_shell_session_start_app_id,
    "expected_app_direct_present_app_id": expected_app_direct_present_app_id,
    "expected_app_direct_present_client_kind": expected_app_direct_present_client_kind,
    "expected_app_direct_present_runtime_bundle_env": expected_app_direct_present_runtime_bundle_env,
    "expected_app_direct_present_runtime_bundle_path": expected_app_direct_present_runtime_bundle_path,
    "expected_app_direct_present_typescript_renderer": expected_app_direct_present_typescript_renderer,
    "expected_metadata_stage_breadcrumb": expected_metadata_stage_breadcrumb,
    "expected_metadata_stage_path": expected_metadata_stage_path,
    "expected_metadata_probe_stage_path": expected_metadata_probe_stage_path,
    "expected_metadata_probe_fingerprint_path": expected_metadata_probe_fingerprint_path,
    "expected_metadata_probe_report_path": expected_metadata_probe_report_path,
    "expected_metadata_probe_timeout_class_path": expected_metadata_probe_timeout_class_path,
    "expected_metadata_probe_summary_path": expected_metadata_probe_summary_path,
    "expected_metadata_compositor_frame_path": expected_metadata_compositor_frame_path,
    "expected_payload_probe_strategy": expected_payload_probe_strategy,
    "expected_payload_probe_source": expected_payload_probe_source,
    "expected_payload_probe_root": expected_payload_probe_root,
    "expected_payload_probe_manifest_path": expected_payload_probe_manifest_path,
    "expected_payload_probe_fallback_path": expected_payload_probe_fallback_path,
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
    "metadata_probe_report_present": recovered_metadata_probe_report_present,
    "metadata_probe_report_actual_access_mode": recovered_metadata_probe_report_actual_access_mode,
    "metadata_probe_report_exit_code": (
        int(recovered_metadata_probe_report_exit_code)
        if recovered_metadata_probe_report_exit_code not in ("", None)
        else None
    ),
    "metadata_probe_report_output_path": recovered_metadata_probe_report_output_path,
    "metadata_probe_report_stderr_path": recovered_metadata_probe_report_stderr_path,
    "metadata_probe_report_observed_stage": recovered_metadata_probe_report_observed_stage,
    "metadata_probe_report_timed_out": (
        recovered_metadata_probe_report_timed_out == "true"
        if recovered_metadata_probe_report_timed_out in ("true", "false")
        else None
    ),
    "metadata_probe_report_wchan": recovered_metadata_probe_report_wchan,
    "metadata_probe_report_child_completed": (
        probe_report_child_completed
        if recovered_metadata_probe_report_child_completed in ("true", "false")
        else None
    ),
    "metadata_probe_report_child_exit_status": probe_report_child_exit_status,
    "metadata_probe_timeout_class_present": recovered_metadata_probe_timeout_class_present,
    "metadata_probe_timeout_class_actual_access_mode": recovered_metadata_probe_timeout_class_actual_access_mode,
    "metadata_probe_timeout_class_exit_code": (
        int(recovered_metadata_probe_timeout_class_exit_code)
        if recovered_metadata_probe_timeout_class_exit_code not in ("", None)
        else None
    ),
    "metadata_probe_timeout_class_output_path": recovered_metadata_probe_timeout_class_output_path,
    "metadata_probe_timeout_class_stderr_path": recovered_metadata_probe_timeout_class_stderr_path,
    "metadata_probe_timeout_class_checkpoint": recovered_metadata_probe_timeout_class_checkpoint,
    "metadata_probe_timeout_class_bucket": recovered_metadata_probe_timeout_class_bucket,
    "metadata_probe_timeout_class_matched_needle": recovered_metadata_probe_timeout_class_matched_needle,
    "metadata_probe_timeout_class_wchan": recovered_metadata_probe_timeout_class_wchan,
    "metadata_probe_summary_present": recovered_metadata_probe_summary_present,
    "metadata_probe_summary_actual_access_mode": recovered_metadata_probe_summary_actual_access_mode,
    "metadata_probe_summary_exit_code": (
        int(recovered_metadata_probe_summary_exit_code)
        if recovered_metadata_probe_summary_exit_code not in ("", None)
        else None
    ),
    "metadata_probe_summary_output_path": recovered_metadata_probe_summary_output_path,
    "metadata_probe_summary_stderr_path": recovered_metadata_probe_summary_stderr_path,
    "metadata_probe_summary_parse_error": recovered_probe_summary_parse_error,
    "metadata_probe_summary_kind": summary_kind,
    "metadata_probe_summary_ok": summary_ok,
    "metadata_probe_summary_startup_mode": summary_startup_mode,
    "metadata_probe_summary_app_id": summary_app_id,
    "metadata_probe_summary_payload_strategy": summary_payload_strategy,
    "metadata_probe_summary_payload_source": summary_payload_source,
    "metadata_probe_summary_payload_root": summary_payload_root,
    "metadata_probe_summary_payload_manifest_path": summary_payload_manifest_path,
    "metadata_probe_summary_payload_marker_path": summary_payload_marker_path,
    "metadata_probe_summary_payload_version": summary_payload_version,
    "metadata_probe_summary_payload_fingerprint": summary_payload_fingerprint,
    "metadata_probe_summary_payload_marker_fingerprint": summary_payload_marker_fingerprint,
    "metadata_probe_summary_payload_fingerprint_verified": summary_payload_fingerprint_verified,
    "metadata_probe_summary_payload_mounted_roots": summary_payload_mounted_roots,
    "metadata_probe_summary_payload_userdata_mount_error": summary_payload_userdata_mount_error,
    "metadata_probe_summary_payload_shadow_logical_mount_error": summary_payload_shadow_logical_mount_error,
    "metadata_probe_summary_payload_fallback_path": summary_payload_fallback_path,
    "metadata_probe_summary_payload_blocker": summary_payload_blocker,
    "metadata_probe_summary_payload_blocker_detail": summary_payload_blocker_detail,
    "metadata_probe_summary_touch_counter_probe_ok": summary_touch_counter_probe_ok,
    "metadata_probe_summary_touch_counter_injection": summary_touch_counter_injection,
    "metadata_probe_summary_touch_counter_input_observed": summary_touch_counter_input_observed,
    "metadata_probe_summary_touch_counter_tap_dispatched": summary_touch_counter_tap_dispatched,
    "metadata_probe_summary_touch_counter_counter_incremented": summary_touch_counter_counter_incremented,
    "metadata_probe_summary_touch_counter_post_touch_frame_committed": summary_touch_counter_post_touch_frame_committed,
    "metadata_probe_summary_touch_counter_post_touch_frame_artifact_logged": summary_touch_counter_post_touch_frame_artifact_logged,
    "metadata_probe_summary_touch_counter_touch_latency_present": summary_touch_counter_touch_latency_present,
    "metadata_probe_summary_touch_counter_post_touch_frame_captured": summary_touch_counter_post_touch_frame_captured,
    "metadata_probe_summary_shell_session_probe_ok": summary_shell_session_probe_ok,
    "metadata_probe_summary_shell_session_shell_mode_enabled": summary_shell_session_shell_mode_enabled,
    "metadata_probe_summary_shell_session_home_frame_done": summary_shell_session_home_frame_done,
    "metadata_probe_summary_shell_session_start_app_requested": summary_shell_session_start_app_requested,
    "metadata_probe_summary_shell_session_app_launch_mode_logged": summary_shell_session_app_launch_mode_logged,
    "metadata_probe_summary_shell_session_mapped_window": summary_shell_session_mapped_window,
    "metadata_probe_summary_shell_session_surface_app_tracked": summary_shell_session_surface_app_tracked,
    "metadata_probe_summary_shell_session_app_frame_artifact_logged": summary_shell_session_app_frame_artifact_logged,
    "metadata_probe_summary_shell_session_app_frame_captured": summary_shell_session_app_frame_captured,
    "metadata_probe_summary_scene": summary_scene,
    "metadata_probe_summary_frame_path": summary_frame_path,
    "metadata_probe_summary_frame_bytes": summary_frame_bytes,
    "metadata_probe_summary_present_kms": summary_present_kms,
    "metadata_probe_summary_kms_present": summary_kms_present,
    "metadata_probe_summary_software_backed": summary_software_backed,
    "metadata_probe_summary_adapter_backend": summary_adapter_backend,
    "metadata_probe_summary_distinct_color_count": summary_distinct_color_count,
    "metadata_probe_summary_distinct_color_samples_rgba8": sorted(summary_samples_set),
    "metadata_probe_summary_checksum_fnv1a64": summary_checksum,
    "metadata_compositor_frame_present": recovered_metadata_compositor_frame_present,
    "metadata_compositor_frame_actual_access_mode": recovered_metadata_compositor_frame_actual_access_mode,
    "metadata_compositor_frame_exit_code": (
        int(recovered_metadata_compositor_frame_exit_code)
        if recovered_metadata_compositor_frame_exit_code not in ("", None)
        else None
    ),
    "metadata_compositor_frame_output_path": recovered_metadata_compositor_frame_output_path,
    "metadata_compositor_frame_stderr_path": recovered_metadata_compositor_frame_stderr_path,
    "metadata_compositor_frame_parse_error": recovered_compositor_frame_parse_error,
    "metadata_compositor_frame_width": compositor_frame_width,
    "metadata_compositor_frame_height": compositor_frame_height,
    "metadata_compositor_frame_pixel_bytes": compositor_frame_pixel_bytes,
    "metadata_compositor_frame_distinct_color_count": compositor_frame_distinct_color_count,
    "metadata_compositor_frame_distinct_color_samples_rgb8": compositor_frame_distinct_color_samples,
    "metadata_compositor_frame_checksum_sha256": compositor_frame_checksum_sha256,
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
    "android_has_kgsl_holders": android_has_kgsl_holders,
    "android_kgsl_holder_count": android_kgsl_holder_count,
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
  printf 'root_timeout_secs=%s\n' "$ROOT_TIMEOUT_SECS"
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
printf 'name\tscope\tcommand\trequested_access_mode\tactual_access_mode\tsource_kind\toutput_path\tstderr_path\texit_code\tavailable\tmatched_shadow_tags\tshadow_match_count\tmatched_expected_run_token\trun_token_match_count\tcorrelated\tcorrelation_state\tmatches_path\trun_token_matches_path\n' >"$CHANNEL_STATUS_TSV"
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
recover_metadata_probe_report_file
recover_metadata_probe_summary_file
recover_metadata_compositor_frame_file
recover_metadata_probe_timeout_class_file

shell_best_effort "logcat-last" "previous-boot" "adb" "logcat -L -d -v threadtime"
shell_best_effort "dropbox-system-boot" "previous-boot" "adb" "dumpsys dropbox --print SYSTEM_BOOT"
shell_best_effort "dropbox-system-last-kmsg" "previous-boot" "adb" "dumpsys dropbox --print SYSTEM_LAST_KMSG"
shell_best_effort "pmsg0" "previous-boot" "root" "cat /dev/pmsg0"
shell_best_effort "pstore" "previous-boot" "root" $'if [ ! -d /sys/fs/pstore ]; then\n  echo "missing /sys/fs/pstore" >&2\n  exit 1\nfi\nfound=0\nfor path in /sys/fs/pstore/*; do\n  [ -e "$path" ] || continue\n  found=1\n  printf "== %s ==\\n" "$path"\n  cat "$path"\n  printf "\\n"\ndone\nif [ "$found" -ne 1 ]; then\n  printf "no pstore entries\\n"\nfi'
shell_best_effort "bootreason-props" "current-boot" "adb" $'for key in ro.boot.bootreason sys.boot.reason sys.boot.reason.last persist.sys.boot.reason.history ro.boot.bootreason_history ro.boot.bootreason_last; do\n  printf "%s=%s\\n" "$key" "$(getprop "$key" | tr -d "\\r")"\ndone'
shell_best_effort "getprop" "current-boot" "adb" "getprop"
shell_best_effort "logcat-current" "current-boot" "adb" "logcat -d -v threadtime"
capture_kernel_log_best_effort "kernel-current-best-effort" "current-boot" "dmesg 2>/dev/null" "logcat -b kernel -d -v threadtime"
shell_best_effort "logcat-kernel-current" "current-boot" "adb" "logcat -b kernel -d -v threadtime"
shell_best_effort "kgsl-holder-scan" "current-boot" "root" "$(pixel_kgsl_holder_scan_command)" "root-proc-fd-scan"

write_bootreason_summary
write_all_matches
write_all_run_token_matches
write_status_json

printf 'Recovered boot traces: %s\n' "$OUTPUT_DIR"
printf 'Serial: %s\n' "$serial"
printf 'Live boot id: %s\n' "${live_boot_id:-unknown}"
printf 'Live slot suffix: %s\n' "${live_slot_suffix:-unknown}"
trap - EXIT
