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
LATE_RECOVER_ADB_TIMEOUT_SECS="${PIXEL_BOOT_ONESHOT_LATE_RECOVER_ADB_TIMEOUT_SECS:-180}"
AUTO_FASTBOOT_REBOOT="${PIXEL_BOOT_ONESHOT_AUTO_FASTBOOT_REBOOT:-1}"
SUCCESS_SIGNAL="${PIXEL_BOOT_ONESHOT_SUCCESS_SIGNAL:-adb}"
RETURN_TIMEOUT_SECS="${PIXEL_BOOT_ONESHOT_RETURN_TIMEOUT_SECS:-45}"
FASTBOOT_LEAVE_TIMEOUT_SECS="${PIXEL_BOOT_ONESHOT_FASTBOOT_LEAVE_TIMEOUT_SECS:-15}"
WAIT_BOOT_COMPLETED=1
SKIP_COLLECT="${PIXEL_BOOT_ONESHOT_SKIP_COLLECT:-0}"
RECOVER_TRACES_AFTER="${PIXEL_BOOT_ONESHOT_RECOVER_TRACES_AFTER:-0}"
PROOF_PROP_SPEC="${PIXEL_BOOT_PROOF_PROP:-}"
OBSERVED_PROP_SPEC="${PIXEL_BOOT_OBSERVED_PROP:-}"
DRY_RUN=0
ORIGINAL_ARGS=("$@")

serial=""
metadata_path=""
status_path=""
collect_output_dir=""
recover_traces_output_dir=""
transport_timeline_path=""
image_sha256=""
slot_before=""
slot_after=""
hello_init_run_token=""
hello_init_token_dir=""
shadow_probe_prop=""
adb_ready=false
boot_completed=false
collect_attempted=false
collect_succeeded=false
boot_completed_required_failed=false
recover_traces_attempted=false
recover_traces_succeeded=false
recover_traces_matched_any_shadow_tags=false
recover_traces_matched_any_uncorrelated_shadow_tags=false
recover_traces_recovered_previous_boot_traces=false
recover_traces_previous_boot_channels_with_matches=0
recover_traces_uncorrelated_previous_boot_channels_with_matches=0
recover_traces_current_boot_channels_with_matches=0
recover_traces_reason=""
recover_traces_adb_timeout_secs_used=0
recover_traces_proof_ok=false
recover_traces_absence_reason_summary=""
recover_traces_expected_durable_logging_summary=""
transport_initial_state=""
transport_first_none_elapsed_secs=""
transport_first_fastboot_elapsed_secs=""
transport_first_adb_elapsed_secs=""
transport_last_state=""
transport_last_state_elapsed_secs=""
transport_late_recovery_reached_adb=false
fastboot_auto_reboot_attempted=false
fastboot_auto_reboot_succeeded=false
fastboot_auto_reboot_elapsed_secs=""
fastboot_auto_reboot_reason=""
fastboot_departed=false
fastboot_returned=false
fastboot_leave_elapsed_secs=0
fastboot_return_elapsed_secs=0
fastboot_cycle_elapsed_secs=0
fastboot_slot_after_return=""
bootreason_ro_boot_bootreason=""
bootreason_sys_boot_reason=""
bootreason_sys_boot_reason_last=""
bootreason_persist_sys_boot_reason_history=""
bootreason_ro_boot_bootreason_history=""
bootreason_ro_boot_bootreason_last=""
bootreason_indicates_failure=false
bootreason_failure_summary=""
token_preclear_attempted=false
token_preclear_succeeded=false
token_preclear_reason=""
token_preclear_root_id=""
failure_stage=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_oneshot.sh [--image PATH] [--output DIR] [--wait-ready SECONDS]
                                          [--adb-timeout SECONDS] [--boot-timeout SECONDS]
                                          [--success-signal adb|fastboot-return]
                                          [--return-timeout SECONDS]
                                          [--skip-collect] [--recover-traces-after]
                                          [--no-wait-boot-completed] [--proof-prop KEY=VALUE]
                                          [--observed-prop KEY=VALUE]
                                          [--dry-run]

One-shot boot a custom sunfish image with `fastboot boot`, then either wait for adb
and collect evidence or treat a bounded return to fastboot as success.

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

flag_enabled() {
  [[ "$(bool_word "$1")" == "true" ]]
}

trim_trailing_whitespace() {
  printf '%s' "${1%"${1##*[![:space:]]}"}"
}

hello_init_metadata_path() {
  local image_path
  image_path="${1:?hello_init_metadata_path requires an image path}"
  printf '%s.hello-init.json\n' "$image_path"
}

load_hello_init_run_token() {
  local metadata_path
  metadata_path="$(hello_init_metadata_path "$IMAGE_PATH")"

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

metadata_token_dir_path_for_token() {
  local run_token
  run_token="${1:?metadata_token_dir_path_for_token requires a run token}"
  printf '/metadata/shadow-hello-init/by-token/%s\n' "$run_token"
}

maybe_preclear_hello_init_token_dir() {
  local preclear_timeout_secs root_id
  preclear_timeout_secs="${PIXEL_BOOT_ONESHOT_TOKEN_PRECLEAR_TIMEOUT_SECS:-20}"

  if [[ -z "$hello_init_run_token" ]]; then
    token_preclear_reason="no-run-token"
    return 0
  fi

  hello_init_token_dir="$(metadata_token_dir_path_for_token "$hello_init_run_token")"
  token_preclear_attempted=true
  root_id="$(pixel_root_id "$serial" 2>/dev/null || true)"
  if [[ -z "$root_id" ]]; then
    token_preclear_reason="root-unavailable"
    return 0
  fi

  token_preclear_root_id="$root_id"
  if ! pixel_root_shell_timeout "$preclear_timeout_secs" "$serial" "rm -rf '$hello_init_token_dir'"; then
    token_preclear_reason="clear-failed"
    return 0
  fi

  if pixel_root_shell_timeout "$preclear_timeout_secs" "$serial" "[ ! -e '$hello_init_token_dir' ]"; then
    token_preclear_succeeded=true
    token_preclear_reason="cleared"
    return 0
  fi

  token_preclear_reason="verify-failed"
  return 0
}

wait_boot_completed_status_word() {
  if [[ "$SUCCESS_SIGNAL" == "fastboot-return" ]]; then
    printf 'false\n'
    return 0
  fi

  bool_word "$WAIT_BOOT_COMPLETED"
}

resolve_serial_for_mode() {
  if [[ "$DRY_RUN" == "1" && -n "${PIXEL_SERIAL:-}" ]]; then
    printf '%s\n' "$PIXEL_SERIAL"
    return 0
  fi

  pixel_resolve_serial
}

validate_success_mode() {
  case "$SUCCESS_SIGNAL" in
    adb|fastboot-return)
      ;;
    *)
      echo "pixel_boot_oneshot: unsupported --success-signal $SUCCESS_SIGNAL; expected adb or fastboot-return" >&2
      exit 1
      ;;
  esac

  if [[ "$SUCCESS_SIGNAL" == "fastboot-return" && "$WAIT_BOOT_COMPLETED" != "1" ]]; then
    echo "pixel_boot_oneshot: --no-wait-boot-completed is only supported with --success-signal adb" >&2
    exit 1
  fi

  if [[ "$SUCCESS_SIGNAL" == "fastboot-return" && -n "$PROOF_PROP_SPEC" ]]; then
    echo "pixel_boot_oneshot: --proof-prop is only supported with --success-signal adb" >&2
    exit 1
  fi

  if [[ "$SUCCESS_SIGNAL" == "fastboot-return" && -n "$OBSERVED_PROP_SPEC" ]]; then
    echo "pixel_boot_oneshot: --observed-prop is only supported with --success-signal adb" >&2
    exit 1
  fi

  if [[ "$SUCCESS_SIGNAL" == "fastboot-return" ]] && flag_enabled "$SKIP_COLLECT"; then
    echo "pixel_boot_oneshot: --skip-collect is only supported with --success-signal adb" >&2
    exit 1
  fi

  if [[ "$SUCCESS_SIGNAL" == "fastboot-return" ]] && flag_enabled "$RECOVER_TRACES_AFTER"; then
    echo "pixel_boot_oneshot: --recover-traces-after is only supported with --success-signal adb" >&2
    exit 1
  fi

  if flag_enabled "$SKIP_COLLECT" && [[ -n "$PROOF_PROP_SPEC" ]]; then
    echo "pixel_boot_oneshot: --proof-prop requires helper-dir collection; omit it when using --skip-collect" >&2
    exit 1
  fi

  if flag_enabled "$SKIP_COLLECT" && [[ -n "$OBSERVED_PROP_SPEC" ]]; then
    echo "pixel_boot_oneshot: --observed-prop requires helper-dir collection; omit it when using --skip-collect" >&2
    exit 1
  fi
}

capture_fastboot_cycle_status() {
  fastboot_departed="${PIXEL_FASTBOOT_CYCLE_DEPARTED:-false}"
  fastboot_returned="${PIXEL_FASTBOOT_CYCLE_RETURNED:-false}"
  fastboot_leave_elapsed_secs="${PIXEL_FASTBOOT_CYCLE_LEAVE_ELAPSED_SECS:-0}"
  fastboot_return_elapsed_secs="${PIXEL_FASTBOOT_CYCLE_RETURN_ELAPSED_SECS:-0}"
  fastboot_cycle_elapsed_secs="${PIXEL_FASTBOOT_CYCLE_TOTAL_ELAPSED_SECS:-0}"
}

capture_bootreason_props() {
  bootreason_ro_boot_bootreason="$(pixel_prop "$serial" ro.boot.bootreason 2>/dev/null || true)"
  bootreason_sys_boot_reason="$(pixel_prop "$serial" sys.boot.reason 2>/dev/null || true)"
  bootreason_sys_boot_reason_last="$(pixel_prop "$serial" sys.boot.reason.last 2>/dev/null || true)"
  bootreason_persist_sys_boot_reason_history="$(pixel_prop "$serial" persist.sys.boot.reason.history 2>/dev/null || true)"
  bootreason_ro_boot_bootreason_history="$(pixel_prop "$serial" ro.boot.bootreason_history 2>/dev/null || true)"
  bootreason_ro_boot_bootreason_last="$(pixel_prop "$serial" ro.boot.bootreason_last 2>/dev/null || true)"
}

bootreason_value_indicates_failure() {
  local normalized
  normalized="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$normalized" ]] || return 1

  case "$normalized" in
    *kernel_panic*|*panic*|*watchdog*|*crash*|*failure*|*fault*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

evaluate_bootreason_status() {
  local details=()

  if bootreason_value_indicates_failure "$bootreason_ro_boot_bootreason"; then
    details+=("ro.boot.bootreason=$bootreason_ro_boot_bootreason")
  fi
  if bootreason_value_indicates_failure "$bootreason_sys_boot_reason"; then
    details+=("sys.boot.reason=$bootreason_sys_boot_reason")
  fi
  if bootreason_value_indicates_failure "$bootreason_sys_boot_reason_last"; then
    details+=("sys.boot.reason.last=$bootreason_sys_boot_reason_last")
  fi
  if bootreason_value_indicates_failure "$bootreason_ro_boot_bootreason_last"; then
    details+=("ro.boot.bootreason_last=$bootreason_ro_boot_bootreason_last")
  fi

  if [[ "${#details[@]}" -gt 0 ]]; then
    bootreason_indicates_failure=true
    printf -v bootreason_failure_summary '%s; ' "${details[@]}"
    bootreason_failure_summary="$(trim_trailing_whitespace "${bootreason_failure_summary%; }")"
    return 0
  fi

  bootreason_indicates_failure=false
  bootreason_failure_summary=""
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

  python3 - \
    "$status_path" \
    "kind=boot_oneshot" \
    "ok=$ok" \
    "serial=$serial" \
    "image=$IMAGE_PATH" \
    "image_sha256=$image_sha256" \
    "output_dir=$OUTPUT_DIR" \
    "metadata_path=$metadata_path" \
    "hello_init_run_token=$hello_init_run_token" \
    "hello_init_token_dir=$hello_init_token_dir" \
    "collect_output_dir=$collect_output_dir" \
    "recover_traces_output_dir=$recover_traces_output_dir" \
    "transport_timeline_path=$transport_timeline_path" \
    "wait_ready_secs=$WAIT_READY_SECS" \
    "adb_timeout_secs=$ADB_TIMEOUT_SECS" \
    "boot_timeout_secs=$BOOT_TIMEOUT_SECS" \
    "success_signal=$SUCCESS_SIGNAL" \
    "return_timeout_secs=$RETURN_TIMEOUT_SECS" \
    "fastboot_leave_timeout_secs=$FASTBOOT_LEAVE_TIMEOUT_SECS" \
    "wait_boot_completed=$(wait_boot_completed_status_word)" \
    "skip_collect=$(bool_word "$SKIP_COLLECT")" \
    "recover_traces_after=$(bool_word "$RECOVER_TRACES_AFTER")" \
    "proof_prop=$PROOF_PROP_SPEC" \
    "observed_prop=$OBSERVED_PROP_SPEC" \
    "slot_before=$slot_before" \
    "slot_after=$slot_after" \
    "shadow_probe_prop=$shadow_probe_prop" \
    "adb_ready=$adb_ready" \
    "boot_completed=$boot_completed" \
    "boot_completed_required_failed=$boot_completed_required_failed" \
    "collect_attempted=$collect_attempted" \
    "collect_succeeded=$collect_succeeded" \
    "recover_traces_attempted=$recover_traces_attempted" \
    "recover_traces_succeeded=$recover_traces_succeeded" \
    "recover_traces_matched_any_shadow_tags=$recover_traces_matched_any_shadow_tags" \
    "recover_traces_matched_any_uncorrelated_shadow_tags=$recover_traces_matched_any_uncorrelated_shadow_tags" \
    "recover_traces_recovered_previous_boot_traces=$recover_traces_recovered_previous_boot_traces" \
    "recover_traces_previous_boot_channels_with_matches=$recover_traces_previous_boot_channels_with_matches" \
    "recover_traces_uncorrelated_previous_boot_channels_with_matches=$recover_traces_uncorrelated_previous_boot_channels_with_matches" \
    "recover_traces_current_boot_channels_with_matches=$recover_traces_current_boot_channels_with_matches" \
    "recover_traces_reason=$recover_traces_reason" \
    "recover_traces_adb_timeout_secs_used=$recover_traces_adb_timeout_secs_used" \
    "recover_traces_proof_ok=$recover_traces_proof_ok" \
    "recover_traces_absence_reason_summary=$recover_traces_absence_reason_summary" \
    "recover_traces_expected_durable_logging_summary=$recover_traces_expected_durable_logging_summary" \
    "token_preclear_attempted=$token_preclear_attempted" \
    "token_preclear_succeeded=$token_preclear_succeeded" \
    "token_preclear_reason=$token_preclear_reason" \
    "token_preclear_root_id=$token_preclear_root_id" \
    "transport_initial_state=$transport_initial_state" \
    "transport_first_none_elapsed_secs=$transport_first_none_elapsed_secs" \
    "transport_first_fastboot_elapsed_secs=$transport_first_fastboot_elapsed_secs" \
    "transport_first_adb_elapsed_secs=$transport_first_adb_elapsed_secs" \
    "transport_last_state=$transport_last_state" \
    "transport_last_state_elapsed_secs=$transport_last_state_elapsed_secs" \
    "transport_late_recovery_reached_adb=$transport_late_recovery_reached_adb" \
    "fastboot_auto_reboot_attempted=$fastboot_auto_reboot_attempted" \
    "fastboot_auto_reboot_succeeded=$fastboot_auto_reboot_succeeded" \
    "fastboot_auto_reboot_elapsed_secs=$fastboot_auto_reboot_elapsed_secs" \
    "fastboot_auto_reboot_reason=$fastboot_auto_reboot_reason" \
    "fastboot_departed=$fastboot_departed" \
    "fastboot_returned=$fastboot_returned" \
    "fastboot_leave_elapsed_secs=$fastboot_leave_elapsed_secs" \
    "fastboot_return_elapsed_secs=$fastboot_return_elapsed_secs" \
    "fastboot_cycle_elapsed_secs=$fastboot_cycle_elapsed_secs" \
    "fastboot_slot_after_return=$fastboot_slot_after_return" \
    "failure_stage=$failure_stage" \
    "bootreason_prop:ro.boot.bootreason=$bootreason_ro_boot_bootreason" \
    "bootreason_prop:sys.boot.reason=$bootreason_sys_boot_reason" \
    "bootreason_prop:sys.boot.reason.last=$bootreason_sys_boot_reason_last" \
    "bootreason_prop:persist.sys.boot.reason.history=$bootreason_persist_sys_boot_reason_history" \
    "bootreason_prop:ro.boot.bootreason_history=$bootreason_ro_boot_bootreason_history" \
    "bootreason_prop:ro.boot.bootreason_last=$bootreason_ro_boot_bootreason_last" \
    "bootreason_indicates_failure=$bootreason_indicates_failure" \
    "bootreason_failure_summary=$bootreason_failure_summary" <<'PY'
import json
import sys

output = sys.argv[1]
payload = {}
bootreason_props = {}

for item in sys.argv[2:]:
    key, value = item.split("=", 1)
    if value == "true":
        parsed = True
    elif value == "false":
        parsed = False
    else:
        try:
            parsed = int(value)
        except ValueError:
            parsed = value

    if key.startswith("bootreason_prop:"):
        bootreason_props[key.split(":", 1)[1]] = value
    else:
        payload[key] = parsed

payload["bootreason_props"] = bootreason_props

with open(output, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

finish() {
  local exit_code=$?
  trap - EXIT
  write_status "$exit_code"
  exit "$exit_code"
}

maybe_recover_traces() {
  local reason adb_timeout_secs boot_timeout_secs recover_status_path recover_summary hello_init_run_token
  local transport_left_fastboot
  local -a recover_args

  reason="${1:-post-boot}"
  adb_timeout_secs="${2:-$ADB_TIMEOUT_SECS}"
  boot_timeout_secs="${3:-$BOOT_TIMEOUT_SECS}"

  if ! flag_enabled "$RECOVER_TRACES_AFTER"; then
    return 0
  fi

  recover_traces_attempted=true
  recover_traces_reason="$reason"
  recover_traces_adb_timeout_secs_used="$adb_timeout_secs"
  recover_args=(
    --output "$recover_traces_output_dir"
    --adb-timeout "$adb_timeout_secs"
    --boot-timeout "$boot_timeout_secs"
  )
  if [[ "$WAIT_BOOT_COMPLETED" != "1" ]]; then
    recover_args+=(--no-wait-boot-completed)
  fi

  hello_init_run_token="$(load_hello_init_run_token)"
  recover_status_path="$recover_traces_output_dir/status.json"
  transport_left_fastboot=false
  if [[ -n "$transport_first_none_elapsed_secs" ]]; then
    transport_left_fastboot=true
  fi

  if [[ "$reason" == "late-wait-adb" && -n "$transport_timeline_path" ]]; then
    if env \
      PIXEL_SERIAL="$serial" \
      PIXEL_HELLO_INIT_RUN_TOKEN="$hello_init_run_token" \
      PIXEL_HELLO_INIT_SOURCE_IMAGE_PATH="$IMAGE_PATH" \
      PIXEL_BOOT_TRANSPORT_TIMELINE_PATH="$transport_timeline_path" \
      PIXEL_BOOT_TRANSPORT_TIMELINE_ELAPSED_OFFSET_SECS="${transport_last_state_elapsed_secs:-0}" \
      PIXEL_BOOT_TRANSPORT_TIMELINE_LAST_RECORDED_STATE="${transport_last_state:-}" \
      PIXEL_BOOT_TRANSPORT_TIMELINE_LEFT_FASTBOOT="$transport_left_fastboot" \
      "$SCRIPT_DIR/pixel/pixel_boot_recover_traces.sh" \
        "${recover_args[@]}"; then
      recover_traces_succeeded=true
    fi
  elif PIXEL_SERIAL="$serial" \
    PIXEL_HELLO_INIT_RUN_TOKEN="$hello_init_run_token" \
    PIXEL_HELLO_INIT_SOURCE_IMAGE_PATH="$IMAGE_PATH" \
    "$SCRIPT_DIR/pixel/pixel_boot_recover_traces.sh" \
      "${recover_args[@]}"; then
    recover_traces_succeeded=true
  fi

  if [[ -f "$recover_status_path" ]]; then
    recover_summary="$(
      python3 - "$recover_status_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

matched = "true" if payload.get("matched_any_shadow_tags") else "false"
uncorrelated = "true" if payload.get("matched_any_uncorrelated_shadow_tags") else "false"
previous = "true" if payload.get("recovered_previous_boot_traces") else "false"
previous_matches = payload.get("previous_boot_channels_with_matches", 0)
uncorrelated_matches = payload.get("uncorrelated_previous_boot_channels_with_matches", 0)
current_matches = payload.get("current_boot_channels_with_matches", 0)
proof_ok = "true" if payload.get("proof_ok") else "false"
absence_reason_summary = payload.get("absence_reason_summary", "")
expected_durable_logging_summary = payload.get("expected_durable_logging_summary", "")
fastboot_auto_reboot_attempted = "true" if payload.get("fastboot_auto_reboot_attempted") else "false"
fastboot_auto_reboot_succeeded = "true" if payload.get("fastboot_auto_reboot_succeeded") else "false"
fastboot_auto_reboot_elapsed_secs = payload.get("fastboot_auto_reboot_elapsed_secs", "")
fastboot_auto_reboot_reason = payload.get("fastboot_auto_reboot_reason", "")
print(
    f"{matched}\t{uncorrelated}\t{previous}\t"
    f"{previous_matches}\t{uncorrelated_matches}\t{current_matches}\t"
    f"{proof_ok}\t{absence_reason_summary}\t{expected_durable_logging_summary}\t"
    f"{fastboot_auto_reboot_attempted}\t{fastboot_auto_reboot_succeeded}\t"
    f"{fastboot_auto_reboot_elapsed_secs}\t{fastboot_auto_reboot_reason}"
)
PY
    )"
    if [[ -n "$recover_summary" ]]; then
      recover_traces_matched_any_shadow_tags="${recover_summary%%$'\t'*}"
      recover_summary="${recover_summary#*$'\t'}"
      recover_traces_matched_any_uncorrelated_shadow_tags="${recover_summary%%$'\t'*}"
      recover_summary="${recover_summary#*$'\t'}"
      recover_traces_recovered_previous_boot_traces="${recover_summary%%$'\t'*}"
      recover_summary="${recover_summary#*$'\t'}"
      recover_traces_previous_boot_channels_with_matches="${recover_summary%%$'\t'*}"
      recover_summary="${recover_summary#*$'\t'}"
      recover_traces_uncorrelated_previous_boot_channels_with_matches="${recover_summary%%$'\t'*}"
      recover_summary="${recover_summary#*$'\t'}"
      recover_traces_current_boot_channels_with_matches="${recover_summary%%$'\t'*}"
      recover_summary="${recover_summary#*$'\t'}"
      recover_traces_proof_ok="${recover_summary%%$'\t'*}"
      recover_summary="${recover_summary#*$'\t'}"
      recover_traces_absence_reason_summary="${recover_summary%%$'\t'*}"
      recover_summary="${recover_summary#*$'\t'}"
      recover_traces_expected_durable_logging_summary="${recover_summary%%$'\t'*}"
      recover_summary="${recover_summary#*$'\t'}"
      if [[ "$fastboot_auto_reboot_attempted" != "true" && "${recover_summary%%$'\t'*}" == "true" ]]; then
        fastboot_auto_reboot_attempted=true
      fi
      recover_summary="${recover_summary#*$'\t'}"
      if [[ "$fastboot_auto_reboot_succeeded" != "true" && "${recover_summary%%$'\t'*}" == "true" ]]; then
        fastboot_auto_reboot_succeeded=true
      fi
      recover_summary="${recover_summary#*$'\t'}"
      if [[ -z "$fastboot_auto_reboot_elapsed_secs" ]]; then
        fastboot_auto_reboot_elapsed_secs="${recover_summary%%$'\t'*}"
      fi
      recover_summary="${recover_summary#*$'\t'}"
      if [[ -z "$fastboot_auto_reboot_reason" ]]; then
        fastboot_auto_reboot_reason="$recover_summary"
      fi
    fi
  fi

  if [[ "$recover_traces_succeeded" == "true" ]]; then
    return 0
  fi

  if [[ -z "$failure_stage" ]]; then
    failure_stage="recover-traces"
  fi
  return 1
}

backfill_state_after_recover_traces() {
  [[ "$recover_traces_succeeded" == "true" ]] || return 0

  adb_ready=true
  slot_after="$(pixel_current_slot_letter_from_adb "$serial" 2>/dev/null || true)"
  shadow_probe_prop="$(pixel_prop "$serial" ro.boot.shadow_probe 2>/dev/null || true)"
  if [[ "$WAIT_BOOT_COMPLETED" == "1" ]]; then
    boot_completed=true
  fi
  if [[ -z "$transport_first_adb_elapsed_secs" ]]; then
    transport_late_recovery_reached_adb=true
  fi
  capture_bootreason_props
  evaluate_bootreason_status
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

  if [[ -z "${PIXEL_ADB_TRANSPORT_FIRST_NONE_ELAPSED_SECS:-}" ]]; then
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

  echo "pixel_boot_oneshot: failed to auto-reboot $serial after fastboot return" >&2
  return 1
}

wait_for_adb_with_transport_timeline_and_auto_fastboot_reboot() {
  local serial timeout timeline_path started_at elapsed_secs current_state
  serial="${1:?wait_for_adb_with_transport_timeline_and_auto_fastboot_reboot requires a serial}"
  timeout="${2:-120}"
  timeline_path="${3:-}"

  pixel_reset_adb_transport_timeline_status
  started_at=$SECONDS

  for _ in $(seq 1 "$timeout"); do
    current_state="$(pixel_transport_state "$serial")"
    elapsed_secs=$((SECONDS - started_at))
    pixel_note_adb_transport_timeline_state "$elapsed_secs" "$current_state" "$timeline_path"
    if [[ "$current_state" == "adb" ]]; then
      pixel_note_adb_transport_timeline_stop_event "$elapsed_secs" "$current_state" "adb-ready" "$timeline_path"
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
    "wait-adb-timeout" \
    "$timeline_path"
  echo "pixel: timed out waiting for adb device $serial" >&2
  return 1
}

print_recover_traces_summary() {
  if [[ "$recover_traces_succeeded" == "true" ]]; then
    printf 'Captured Android-side recovery bundle: %s\n' "$recover_traces_output_dir"
    printf 'Recovery bundle matched shadow tags: %s\n' "$recover_traces_matched_any_shadow_tags"
    printf 'Recovery bundle matched uncorrelated shadow tags: %s\n' "$recover_traces_matched_any_uncorrelated_shadow_tags"
    printf 'Recovery bundle previous-boot matches: %s\n' "$recover_traces_previous_boot_channels_with_matches"
    printf 'Recovery bundle uncorrelated previous-boot matches: %s\n' "$recover_traces_uncorrelated_previous_boot_channels_with_matches"
    printf 'Recovery bundle current-boot matches: %s\n' "$recover_traces_current_boot_channels_with_matches"
    printf 'Recovery bundle proof ok: %s\n' "$recover_traces_proof_ok"
    printf 'Recovery bundle expected durable logging: %s\n' "$recover_traces_expected_durable_logging_summary"
    if [[ -n "$recover_traces_absence_reason_summary" ]]; then
      printf 'Recovery bundle absence reasons: %s\n' "$recover_traces_absence_reason_summary"
    fi
  fi
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
    --success-signal)
      SUCCESS_SIGNAL="${2:?missing value for --success-signal}"
      shift 2
      ;;
    --return-timeout)
      RETURN_TIMEOUT_SECS="${2:?missing value for --return-timeout}"
      shift 2
      ;;
    --skip-collect)
      SKIP_COLLECT=1
      shift
      ;;
    --recover-traces-after)
      RECOVER_TRACES_AFTER=1
      shift
      ;;
    --no-wait-boot-completed)
      WAIT_BOOT_COMPLETED=0
      shift
      ;;
    --proof-prop)
      PROOF_PROP_SPEC="${2:?missing value for --proof-prop}"
      shift 2
      ;;
    --observed-prop)
      OBSERVED_PROP_SPEC="${2:?missing value for --observed-prop}"
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

validate_success_mode

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
if [[ "$SUCCESS_SIGNAL" == "adb" ]] && ! flag_enabled "$SKIP_COLLECT"; then
  collect_output_dir="$OUTPUT_DIR/collect"
fi
if [[ "$SUCCESS_SIGNAL" == "adb" ]] && flag_enabled "$RECOVER_TRACES_AFTER"; then
  recover_traces_output_dir="$OUTPUT_DIR/recover-traces"
fi
if [[ "$SUCCESS_SIGNAL" == "adb" ]]; then
  transport_timeline_path="$OUTPUT_DIR/transport-timeline.tsv"
fi
image_sha256="$(shasum -a 256 "$IMAGE_PATH" | awk '{print $1}')"
hello_init_run_token="$(load_hello_init_run_token)"
if [[ -n "$hello_init_run_token" ]]; then
  hello_init_token_dir="$(metadata_token_dir_path_for_token "$hello_init_run_token")"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  cat <<EOF
pixel_boot_oneshot: dry-run
serial=$serial
image=$IMAGE_PATH
image_sha256=$image_sha256
output_dir=$OUTPUT_DIR
metadata_path=$metadata_path
hello_init_run_token=$hello_init_run_token
hello_init_token_dir=$hello_init_token_dir
success_signal=$SUCCESS_SIGNAL
wait_ready_secs=$WAIT_READY_SECS
adb_timeout_secs=$ADB_TIMEOUT_SECS
boot_timeout_secs=$BOOT_TIMEOUT_SECS
return_timeout_secs=$RETURN_TIMEOUT_SECS
fastboot_leave_timeout_secs=$FASTBOOT_LEAVE_TIMEOUT_SECS
wait_boot_completed=$(wait_boot_completed_status_word)
skip_collect=$(bool_word "$SKIP_COLLECT")
recover_traces_after=$(bool_word "$RECOVER_TRACES_AFTER")
auto_fastboot_reboot=$(bool_word "$AUTO_FASTBOOT_REBOOT")
proof_prop=$PROOF_PROP_SPEC
observed_prop=$OBSERVED_PROP_SPEC
EOF
  if [[ -n "$collect_output_dir" ]]; then
    printf 'collect_output_dir=%s\n' "$collect_output_dir"
  fi
  if [[ -n "$recover_traces_output_dir" ]]; then
    printf 'recover_traces_output_dir=%s\n' "$recover_traces_output_dir"
    printf 'late_recover_adb_timeout_secs=%s\n' "$LATE_RECOVER_ADB_TIMEOUT_SECS"
  fi
  if [[ -n "$transport_timeline_path" ]]; then
    printf 'transport_timeline_path=%s\n' "$transport_timeline_path"
  fi
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
  success_signal="$SUCCESS_SIGNAL" \
  return_timeout_secs="$RETURN_TIMEOUT_SECS" \
  fastboot_leave_timeout_secs="$FASTBOOT_LEAVE_TIMEOUT_SECS" \
  proof_prop="$PROOF_PROP_SPEC" \
  observed_prop="$OBSERVED_PROP_SPEC" \
  wait_boot_completed="$(wait_boot_completed_status_word)" \
  skip_collect="$(bool_word "$SKIP_COLLECT")" \
  recover_traces_after="$(bool_word "$RECOVER_TRACES_AFTER")" \
  transport_timeline_path="$transport_timeline_path"

maybe_preclear_hello_init_token_dir

printf 'One-shot booting %s on %s\n' "$IMAGE_PATH" "$serial"
printf 'Current slot before fastboot boot: %s\n' "$slot_before"
if [[ -n "$hello_init_run_token" ]]; then
  if [[ "$token_preclear_succeeded" == "true" ]]; then
    printf 'Pre-cleared metadata token dir: %s\n' "$hello_init_token_dir"
  else
    printf 'Metadata token dir pre-clear status: %s (%s)\n' "$hello_init_token_dir" "${token_preclear_reason:-unknown}"
  fi
fi
pixel_adb "$serial" reboot bootloader
pixel_wait_for_fastboot "$serial" 60
pixel_fastboot "$serial" boot "$IMAGE_PATH"

if [[ "$SUCCESS_SIGNAL" == "fastboot-return" ]]; then
  if pixel_wait_for_fastboot_cycle "$serial" "$FASTBOOT_LEAVE_TIMEOUT_SECS" "$RETURN_TIMEOUT_SECS"; then
    capture_fastboot_cycle_status
    fastboot_slot_after_return="$(pixel_fastboot_current_slot "$serial" 2>/dev/null || true)"
  else
    capture_fastboot_cycle_status
    failure_stage="wait-fastboot-return"
    exit 1
  fi

  printf 'Observed fastboot return after %ss on %s\n' "$fastboot_cycle_elapsed_secs" "$serial"
  printf 'Run status: %s\n' "$status_path"
  exit 0
fi

if ! wait_for_adb_with_transport_timeline_and_auto_fastboot_reboot "$serial" "$ADB_TIMEOUT_SECS" "$transport_timeline_path"; then
  capture_transport_timeline_status
  failure_stage="wait-adb"
  if maybe_recover_traces "late-wait-adb" "$LATE_RECOVER_ADB_TIMEOUT_SECS" "$BOOT_TIMEOUT_SECS"; then
    backfill_state_after_recover_traces
    printf 'Late recovery after wait-adb timeout succeeded\n'
    print_recover_traces_summary
    if [[ "$bootreason_indicates_failure" == "true" ]]; then
      printf 'Bootreason indicates failed Android boot: %s\n' "$bootreason_failure_summary"
    fi
    printf 'Run status: %s\n' "$status_path"
  fi
  exit 1
fi
capture_transport_timeline_status
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
capture_bootreason_props
evaluate_bootreason_status

collect_failed=false
if ! flag_enabled "$SKIP_COLLECT"; then
  collect_args=(
    --output "$collect_output_dir"
    --wait-ready "$WAIT_READY_SECS"
  )
  if [[ -n "$PROOF_PROP_SPEC" ]]; then
    collect_args+=(--proof-prop "$PROOF_PROP_SPEC")
  fi
  if [[ -n "$OBSERVED_PROP_SPEC" ]]; then
    collect_args+=(--observed-prop "$OBSERVED_PROP_SPEC")
  fi

  collect_attempted=true
  if PIXEL_SERIAL="$serial" PIXEL_BOOT_METADATA_PATH="$metadata_path" \
    "$SCRIPT_DIR/pixel/pixel_boot_collect_logs.sh" \
      "${collect_args[@]}"; then
    collect_succeeded=true
  else
    if [[ -z "$failure_stage" ]]; then
      failure_stage="collect"
    fi
    collect_failed=true
  fi
fi

if ! maybe_recover_traces; then
  exit 1
fi

if [[ "$collect_failed" == "true" ]]; then
  exit 1
fi

if [[ "$boot_completed_required_failed" == "true" ]]; then
  exit 1
fi

if [[ "$bootreason_indicates_failure" == "true" ]]; then
  failure_stage="${failure_stage:-bootreason-failure}"
  if flag_enabled "$SKIP_COLLECT"; then
    printf 'Skipped helper-dir collection for one-shot boot run\n'
  else
    printf 'Collected one-shot boot evidence: %s\n' "$collect_output_dir"
  fi
  print_recover_traces_summary
  if [[ -n "$transport_timeline_path" ]]; then
    printf 'Transport timeline: %s\n' "$transport_timeline_path"
  fi
  printf 'Bootreason indicates failed Android boot: %s\n' "$bootreason_failure_summary"
  printf 'Run status: %s\n' "$status_path"
  exit 1
fi

if [[ "$fastboot_auto_reboot_attempted" == "true" ]]; then
  failure_stage="${failure_stage:-fastboot-return-auto-rebooted}"
  if flag_enabled "$SKIP_COLLECT"; then
    printf 'Skipped helper-dir collection for one-shot boot run\n'
  else
    printf 'Collected one-shot boot evidence: %s\n' "$collect_output_dir"
  fi
  print_recover_traces_summary
  if [[ -n "$transport_timeline_path" ]]; then
    printf 'Transport timeline: %s\n' "$transport_timeline_path"
  fi
  printf 'Run returned to fastboot and was auto-rebooted to Android by the host\n'
  printf 'Run status: %s\n' "$status_path"
  exit 1
fi

if flag_enabled "$SKIP_COLLECT"; then
  printf 'Skipped helper-dir collection for one-shot boot run\n'
else
  printf 'Collected one-shot boot evidence: %s\n' "$collect_output_dir"
fi
print_recover_traces_summary
if [[ -n "$transport_timeline_path" ]]; then
  printf 'Transport timeline: %s\n' "$transport_timeline_path"
fi
printf 'Run status: %s\n' "$status_path"
