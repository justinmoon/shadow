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
PROOF_PROP_SPEC="${PIXEL_BOOT_PROOF_PROP:-}"
PROOF_PROP_KEY=""
PROOF_PROP_VALUE=""
PROOF_LOGCAT_SUBSTRING="${PIXEL_BOOT_PROOF_LOGCAT_SUBSTRING:-}"
PROOF_DEVICE_PATH="${PIXEL_BOOT_PROOF_DEVICE_PATH:-}"
PROOF_PS_SUBSTRING="${PIXEL_BOOT_PROOF_PS_SUBSTRING:-}"
OBSERVED_PROP_SPEC="${PIXEL_BOOT_OBSERVED_PROP:-}"
OBSERVED_PROP_KEY=""
OBSERVED_PROP_VALUE=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_collect_logs.sh [--output DIR] [--device-log-root PATH] [--wait-ready SECONDS]
                                              [--metadata PATH] [--wrapper-marker-root PATH]
                                              [--proof-prop KEY=VALUE] [--proof-logcat-substring TEXT]
                                              [--proof-device-path PATH]
                                              [--proof-ps-substring TEXT]
                                              [--observed-prop KEY=VALUE]

Pull private Shadow boot helper logs from a booted Pixel after an experimental stock-init boot.
EOF
}

validate_proof_prop_spec() {
  [[ -z "$PROOF_PROP_SPEC" ]] && return 0
  [[ "$PROOF_PROP_SPEC" == *=* ]] || {
    echo "pixel_boot_collect_logs: --proof-prop must be KEY=VALUE" >&2
    exit 1
  }

  PROOF_PROP_KEY="${PROOF_PROP_SPEC%%=*}"
  PROOF_PROP_VALUE="${PROOF_PROP_SPEC#*=}"
  [[ -n "$PROOF_PROP_KEY" && -n "$PROOF_PROP_VALUE" ]] || {
    echo "pixel_boot_collect_logs: --proof-prop requires non-empty KEY and VALUE" >&2
    exit 1
  }
  [[ "$PROOF_PROP_KEY" =~ ^[A-Za-z0-9._:-]+$ ]] || {
    echo "pixel_boot_collect_logs: --proof-prop key contains unsupported characters" >&2
    exit 1
  }
}

validate_observed_prop_spec() {
  [[ -z "$OBSERVED_PROP_SPEC" ]] && return 0
  [[ "$OBSERVED_PROP_SPEC" == *=* ]] || {
    echo "pixel_boot_collect_logs: --observed-prop must be KEY=VALUE" >&2
    exit 1
  }

  OBSERVED_PROP_KEY="${OBSERVED_PROP_SPEC%%=*}"
  OBSERVED_PROP_VALUE="${OBSERVED_PROP_SPEC#*=}"
  [[ -n "$OBSERVED_PROP_KEY" && -n "$OBSERVED_PROP_VALUE" ]] || {
    echo "pixel_boot_collect_logs: --observed-prop requires non-empty KEY and VALUE" >&2
    exit 1
  }
  [[ "$OBSERVED_PROP_KEY" =~ ^[A-Za-z0-9._:-]+$ ]] || {
    echo "pixel_boot_collect_logs: --observed-prop key contains unsupported characters" >&2
    exit 1
  }
}

validate_proof_logcat_substring() {
  [[ -z "$PROOF_LOGCAT_SUBSTRING" ]] && return 0
  [[ "$PROOF_LOGCAT_SUBSTRING" != *$'\n'* ]] || {
    echo "pixel_boot_collect_logs: --proof-logcat-substring must be a single line" >&2
    exit 1
  }
}

validate_proof_device_path() {
  [[ -z "$PROOF_DEVICE_PATH" ]] && return 0
  [[ "$PROOF_DEVICE_PATH" != *$'\n'* ]] || {
    echo "pixel_boot_collect_logs: --proof-device-path must be a single path" >&2
    exit 1
  }
  [[ "$PROOF_DEVICE_PATH" == /* ]] || {
    echo "pixel_boot_collect_logs: --proof-device-path must be absolute" >&2
    exit 1
  }
}

validate_proof_ps_substring() {
  [[ -z "$PROOF_PS_SUBSTRING" ]] && return 0
  [[ "$PROOF_PS_SUBSTRING" != *$'\n'* ]] || {
    echo "pixel_boot_collect_logs: --proof-ps-substring must be a single line" >&2
    exit 1
  }
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

device_prop_value() {
  local serial key
  serial="$1"
  key="$2"
  pixel_prop "$serial" "$key" 2>/dev/null | tr -d '\r\n' || true
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

load_preflight_summary() {
  local summary_path key value
  summary_path="$1"
  [[ -f "$summary_path" ]] || return 0

  preflight_summary_present=true
  while IFS='=' read -r key value; do
    case "$key" in
      profile)
        preflight_profile="$value"
        ;;
      status)
        preflight_status="$value"
        ;;
      blocked_reason)
        preflight_blocked_reason="$value"
        ;;
      data_mounted)
        preflight_data_mounted="$value"
        ;;
      data_writable)
        preflight_data_writable="$value"
        ;;
      data_local_tmp_ready)
        preflight_data_local_tmp_ready="$value"
        ;;
      required_check_count)
        preflight_required_check_count="$value"
        ;;
      missing_required_count)
        preflight_missing_required_count="$value"
        ;;
      required_missing_labels)
        preflight_required_missing_labels="$value"
        ;;
    esac
  done <"$summary_path"

  if [[ "$preflight_status" == "ready" ]]; then
    preflight_ready=true
  fi
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

proof_prop_ready() {
  local serial observed
  serial="$1"
  [[ -n "$PROOF_PROP_KEY" ]] || return 1

  observed="$(device_prop_value "$serial" "$PROOF_PROP_KEY")"
  [[ "$observed" == "$PROOF_PROP_VALUE" ]]
}

observed_prop_ready() {
  local serial observed
  serial="$1"
  [[ -n "$OBSERVED_PROP_KEY" ]] || return 1

  observed="$(device_prop_value "$serial" "$OBSERVED_PROP_KEY")"
  [[ "$observed" == "$OBSERVED_PROP_VALUE" ]]
}

proof_logcat_ready() {
  local serial
  serial="$1"
  [[ -n "$PROOF_LOGCAT_SUBSTRING" ]] || return 1

  pixel_adb "$serial" shell 'logcat -d 2>/dev/null || true' 2>/dev/null | \
    grep -F -- "$PROOF_LOGCAT_SUBSTRING" >/dev/null
}

proof_device_path_ready() {
  local serial
  serial="$1"
  [[ -n "$PROOF_DEVICE_PATH" ]] || return 1

  device_path_exists "$serial" "$PROOF_DEVICE_PATH"
}

proof_ps_ready() {
  local serial
  serial="$1"
  [[ -n "$PROOF_PS_SUBSTRING" ]] || return 1

  pixel_adb "$serial" shell 'ps -A -o USER,PID,PPID,NAME,ARGS 2>/dev/null || ps -A || true' 2>/dev/null | \
    grep -F -- "$PROOF_PS_SUBSTRING" >/dev/null
}

probe_signal_ready() {
  local serial
  serial="$1"
  if device_log_ready "$serial" "$DEVICE_LOG_ROOT"; then
    return 0
  fi
  if proof_prop_ready "$serial"; then
    return 0
  fi
  if proof_logcat_ready "$serial"; then
    return 0
  fi
  if proof_device_path_ready "$serial"; then
    return 0
  fi
  if proof_ps_ready "$serial"; then
    return 0
  fi
  observed_prop_ready "$serial"
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
    --proof-prop)
      PROOF_PROP_SPEC="${2:?missing value for --proof-prop}"
      shift 2
      ;;
    --proof-logcat-substring)
      PROOF_LOGCAT_SUBSTRING="${2:?missing value for --proof-logcat-substring}"
      shift 2
      ;;
    --proof-device-path)
      PROOF_DEVICE_PATH="${2:?missing value for --proof-device-path}"
      shift 2
      ;;
    --proof-ps-substring)
      PROOF_PS_SUBSTRING="${2:?missing value for --proof-ps-substring}"
      shift 2
      ;;
    --observed-prop)
      OBSERVED_PROP_SPEC="${2:?missing value for --observed-prop}"
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

validate_proof_prop_spec
validate_proof_logcat_substring
validate_proof_device_path
validate_proof_ps_substring
validate_observed_prop_spec

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
  if ! pixel_wait_for_condition "$WAIT_READY_SECS" 1 probe_signal_ready "$serial"; then
    cat <<EOF >&2
pixel_boot_collect_logs: timed out waiting for a boot probe signal on $serial; continuing with best-effort collection

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
capture_adb_shell_best_effort "$serial" "$OUTPUT_DIR/logcat-all.txt" 'logcat -d 2>/dev/null || true' || true
capture_adb_shell_best_effort "$serial" "$OUTPUT_DIR/logcat-shadow.txt" 'logcat -d -s shadow-init:I shadow-boot:I 2>/dev/null || true' || true
capture_adb_shell_best_effort "$serial" "$OUTPUT_DIR/logcat-kernel.txt" 'logcat -b kernel -d 2>/dev/null || true' || true
capture_adb_shell_best_effort "$serial" "$OUTPUT_DIR/ps.txt" 'ps -A -o USER,PID,PPID,NAME,ARGS 2>/dev/null || ps -A || true' || true

proof_logcat_path="$OUTPUT_DIR/proof-logcat.txt"
matched_proof_logcat=false
proof_logcat_match_count=0
if [[ -n "$PROOF_LOGCAT_SUBSTRING" ]]; then
  if grep -F -- "$PROOF_LOGCAT_SUBSTRING" "$OUTPUT_DIR/logcat-all.txt" >"$proof_logcat_path"; then
    matched_proof_logcat=true
    proof_logcat_match_count="$(wc -l <"$proof_logcat_path" | tr -d '[:space:]')"
  else
    : >"$proof_logcat_path"
  fi
fi

matched_proof_device_path=false
if [[ -n "$PROOF_DEVICE_PATH" ]] && device_path_exists "$serial" "$PROOF_DEVICE_PATH"; then
  matched_proof_device_path=true
fi

proof_ps_path="$OUTPUT_DIR/proof-ps.txt"
matched_proof_ps=false
proof_ps_match_count=0
if [[ -n "$PROOF_PS_SUBSTRING" ]]; then
  if grep -F -- "$PROOF_PS_SUBSTRING" "$OUTPUT_DIR/ps.txt" >"$proof_ps_path"; then
    matched_proof_ps=true
    proof_ps_match_count="$(wc -l <"$proof_ps_path" | tr -d '[:space:]')"
  else
    : >"$proof_ps_path"
  fi
fi

log_dir="$OUTPUT_DIR/device/$(device_log_dir_name)"
helper_status_present=false
if [[ -f "$log_dir/status.txt" ]]; then
  helper_status_present=true
fi
preflight_summary_present=false
preflight_checks_present=false
preflight_profile=""
preflight_status=""
preflight_blocked_reason=""
preflight_data_mounted=""
preflight_data_writable=""
preflight_data_local_tmp_ready=""
preflight_required_check_count=0
preflight_missing_required_count=0
preflight_required_missing_labels=""
preflight_ready=false
if [[ -f "$log_dir/preflight-checks.tsv" ]]; then
  preflight_checks_present=true
fi
load_preflight_summary "$log_dir/preflight-summary.txt"
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
live_matches_expected_slot=true
wrapper_dir="$OUTPUT_DIR/device/$(wrapper_marker_dir_name)"
wrapper_status=""
wrapper_boot_id=""
wrapper_matches_current_boot=false
observed_prop_value=""
matched_proof_prop=false
observed_secondary_prop_value=""
matched_observed_prop=false

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
if [[ -n "$expected_slot_suffix" && "$live_slot_suffix" != "$expected_slot_suffix" ]]; then
  live_matches_expected_slot=false
fi
if [[ -n "$wrapper_boot_id" && -n "$live_boot_id" && "$wrapper_boot_id" == "$live_boot_id" ]]; then
  wrapper_matches_current_boot=true
fi
if [[ -n "$PROOF_PROP_KEY" ]]; then
  observed_prop_value="$(device_prop_value "$serial" "$PROOF_PROP_KEY")"
  if [[ "$observed_prop_value" == "$PROOF_PROP_VALUE" ]]; then
    matched_proof_prop=true
  fi
fi
if [[ -n "$OBSERVED_PROP_KEY" ]]; then
  observed_secondary_prop_value="$(device_prop_value "$serial" "$OBSERVED_PROP_KEY")"
  if [[ "$observed_secondary_prop_value" == "$OBSERVED_PROP_VALUE" ]]; then
    matched_observed_prop=true
  fi
fi

collection_succeeded=false
if [[ "$helper_dir_present" == "true" && "$helper_dir_pulled" == "true" && "$helper_status_present" == "true" && "$matched_current_boot" == "true" && "$matched_current_slot" == "true" && "$matched_expected_slot" == "true" ]]; then
  collection_succeeded=true
fi
if [[ "$collection_succeeded" != "true" && -n "$PROOF_PROP_KEY" && "$matched_proof_prop" == "true" && "$live_matches_expected_slot" == "true" ]]; then
  collection_succeeded=true
fi
if [[ "$collection_succeeded" != "true" && -n "$PROOF_LOGCAT_SUBSTRING" && "$matched_proof_logcat" == "true" && "$live_matches_expected_slot" == "true" ]]; then
  collection_succeeded=true
fi
if [[ "$collection_succeeded" != "true" && -n "$PROOF_DEVICE_PATH" && "$matched_proof_device_path" == "true" && "$live_matches_expected_slot" == "true" ]]; then
  collection_succeeded=true
fi
if [[ "$collection_succeeded" != "true" && -n "$PROOF_PS_SUBSTRING" && "$matched_proof_ps" == "true" && "$live_matches_expected_slot" == "true" ]]; then
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
  live_matches_expected_slot="$live_matches_expected_slot" \
  proof_mode="$(if [[ -n "$PROOF_PROP_KEY" ]]; then printf property; elif [[ -n "$PROOF_LOGCAT_SUBSTRING" ]]; then printf logcat-substring; elif [[ -n "$PROOF_DEVICE_PATH" ]]; then printf device-path; elif [[ -n "$PROOF_PS_SUBSTRING" ]]; then printf ps-substring; else printf helper-dir; fi)" \
  proof_property_key="$PROOF_PROP_KEY" \
  proof_property_expected="$PROOF_PROP_VALUE" \
  proof_property_actual="$observed_prop_value" \
  proof_property_matched="$matched_proof_prop" \
  proof_logcat_substring="$PROOF_LOGCAT_SUBSTRING" \
  proof_logcat_match_count="$proof_logcat_match_count" \
  proof_logcat_matched="$matched_proof_logcat" \
  proof_device_path="$PROOF_DEVICE_PATH" \
  proof_device_path_present="$matched_proof_device_path" \
  proof_ps_substring="$PROOF_PS_SUBSTRING" \
  proof_ps_match_count="$proof_ps_match_count" \
  proof_ps_matched="$matched_proof_ps" \
  observed_property_key="$OBSERVED_PROP_KEY" \
  observed_property_expected="$OBSERVED_PROP_VALUE" \
  observed_property_actual="$observed_secondary_prop_value" \
  observed_property_matched="$matched_observed_prop" \
  preflight_summary_present="$preflight_summary_present" \
  preflight_checks_present="$preflight_checks_present" \
  preflight_profile="$preflight_profile" \
  preflight_status="$preflight_status" \
  preflight_ready="$preflight_ready" \
  preflight_blocked_reason="$preflight_blocked_reason" \
  preflight_data_mounted="$preflight_data_mounted" \
  preflight_data_writable="$preflight_data_writable" \
  preflight_data_local_tmp_ready="$preflight_data_local_tmp_ready" \
  preflight_required_check_count="$preflight_required_check_count" \
  preflight_missing_required_count="$preflight_missing_required_count" \
  preflight_required_missing_labels="$preflight_required_missing_labels" \
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
proof_property_key=${PROOF_PROP_KEY:-<none>}
proof_property_expected=${PROOF_PROP_VALUE:-<none>}
proof_property_actual=${observed_prop_value:-<none>}
proof_property_matched=$matched_proof_prop
proof_logcat_substring=${PROOF_LOGCAT_SUBSTRING:-<none>}
proof_logcat_match_count=$proof_logcat_match_count
proof_logcat_matched=$matched_proof_logcat
proof_device_path=${PROOF_DEVICE_PATH:-<none>}
proof_device_path_present=$matched_proof_device_path
proof_ps_substring=${PROOF_PS_SUBSTRING:-<none>}
proof_ps_match_count=$proof_ps_match_count
proof_ps_matched=$matched_proof_ps
observed_property_key=${OBSERVED_PROP_KEY:-<none>}
observed_property_expected=${OBSERVED_PROP_VALUE:-<none>}
observed_property_actual=${observed_secondary_prop_value:-<none>}
observed_property_matched=$matched_observed_prop
live_matches_expected_slot=$live_matches_expected_slot
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
if [[ -n "$PROOF_PROP_KEY" ]]; then
  printf 'Proof property: %s=%s\n' "$PROOF_PROP_KEY" "$PROOF_PROP_VALUE"
  printf 'Observed property: %s\n' "$observed_prop_value"
fi
if [[ -n "$PROOF_LOGCAT_SUBSTRING" ]]; then
  printf 'Proof logcat substring: %s\n' "$PROOF_LOGCAT_SUBSTRING"
  printf 'Proof logcat matches: %s\n' "$proof_logcat_match_count"
fi
if [[ -n "$PROOF_DEVICE_PATH" ]]; then
  printf 'Proof device path: %s\n' "$PROOF_DEVICE_PATH"
  printf 'Proof device path present: %s\n' "$matched_proof_device_path"
fi
if [[ -n "$PROOF_PS_SUBSTRING" ]]; then
  printf 'Proof ps substring: %s\n' "$PROOF_PS_SUBSTRING"
  printf 'Proof ps matches: %s\n' "$proof_ps_match_count"
fi
if [[ -n "$OBSERVED_PROP_KEY" ]]; then
  printf 'Observed property target: %s=%s\n' "$OBSERVED_PROP_KEY" "$OBSERVED_PROP_VALUE"
  printf 'Observed property actual: %s\n' "$observed_secondary_prop_value"
fi
if [[ "$preflight_summary_present" == "true" ]]; then
  printf 'Preflight profile: %s\n' "$preflight_profile"
  printf 'Preflight status: %s\n' "$preflight_status"
  if [[ -n "$preflight_blocked_reason" ]]; then
    printf 'Preflight blocked reason: %s\n' "$preflight_blocked_reason"
  fi
fi
