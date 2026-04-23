#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

original_args=("$@")
matrix_root="$(pixel_runs_dir)/boot-kgsl-trigger-ladder"
matrix_dir="${PIXEL_BOOT_KGSL_TRIGGER_LADDER_DIR:-}"
input_image="${PIXEL_BOOT_INPUT_IMAGE:-}"
key_path="${AVB_TEST_KEY_PATH:-}"
default_serial="${PIXEL_SERIAL:-}"
device_log_root="$(pixel_boot_device_log_root)"
launch_proof_prop="${PIXEL_BOOT_KGSL_PROBE_LAUNCH_PROOF_PROP:-debug.shadow.boot.kgsl.launch=started}"
second_stage_proof_prop="${PIXEL_BOOT_KGSL_PROBE_SECOND_STAGE_PROOF_PROP:-debug.shadow.boot.kgsl.second_stage=ready}"
init_script_selection_proof_prop="${PIXEL_BOOT_KGSL_PROBE_INIT_SCRIPT_SELECTION_PROOF_PROP:-init.svc.servicemanager=running}"
imported_rc_proof_prop="${PIXEL_BOOT_KGSL_PROBE_IMPORTED_RC_PROOF_PROP:-init.svc.adbd=running}"
control_point_prop="${PIXEL_BOOT_KGSL_PROBE_CONTROL_POINT_PROP:-llk.enable=1}"
control_point_proof_prop="${PIXEL_BOOT_KGSL_PROBE_CONTROL_POINT_PROOF_PROP:-init.svc.llkd-0=running}"
kgsl_timeout_secs="${PIXEL_BOOT_KGSL_PROBE_TIMEOUT_SECS:-12}"
patch_target_override="${PIXEL_BOOT_KGSL_PROBE_PATCH_TARGET:-}"
wait_ready_secs="${PIXEL_BOOT_KGSL_PROBE_WAIT_READY_SECS:-120}"
adb_timeout_secs="${PIXEL_BOOT_KGSL_PROBE_ADB_TIMEOUT_SECS:-180}"
boot_timeout_secs="${PIXEL_BOOT_KGSL_PROBE_BOOT_TIMEOUT_SECS:-240}"
recover_traces_after="${PIXEL_BOOT_KGSL_PROBE_RECOVER_TRACES_AFTER:-0}"
wait_boot_completed=1
dry_run=0
serial=""
summary_path=""
table_path=""
manifest_path=""
runner_script="${PIXEL_BOOT_KGSL_TRIGGER_LADDER_RUNNER:-$SCRIPT_DIR/pixel/pixel_boot_kgsl_probe.sh}"
declare -a triggers=()
declare -a case_json_paths=()

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_kgsl_trigger_ladder.sh [--output-dir DIR] [--serial SERIAL]
                                                       [--input PATH] [--key PATH]
                                                       [--trigger EXPR]...
                                                       [--device-log-root PATH]
                                                       [--launch-proof-prop KEY=VALUE]
                                                       [--second-stage-proof-prop KEY=VALUE]
                                                       [--init-script-selection-proof-prop KEY=VALUE]
                                                       [--imported-rc-proof-prop KEY=VALUE]
                                                       [--control-point-prop KEY=VALUE]
                                                       [--control-point-proof-prop KEY=VALUE]
                                                       [--timeout SECONDS]
                                                       [--patch-target ENTRY]
                                                       [--wait-ready SECONDS]
                                                       [--adb-timeout SECONDS]
                                                       [--boot-timeout SECONDS]
                                                       [--recover-traces-after]
                                                       [--no-wait-boot-completed]
                                                       [--dry-run]

Run the stock-init KGSL probe across a small trigger ladder and summarize whether
each trigger launched the helper plus what the supervised /dev/kgsl-3d0 readonly
open reported.
EOF
}

default_triggers() {
  cat <<'EOF'
post-fs-data
property:init.svc.pd_mapper=running
property:init.svc.qseecom-service=running
property:init.svc.gpu=running
property:sys.boot_completed=1
EOF
}

append_default_triggers() {
  local trigger_value
  while IFS= read -r trigger_value; do
    [[ -n "$trigger_value" ]] || continue
    triggers+=("$trigger_value")
  done < <(default_triggers)
}

slugify_trigger() {
  local trigger_value
  trigger_value="${1:?slugify_trigger requires a trigger}"
  python3 - "$trigger_value" <<'PY'
import re
import sys

value = sys.argv[1].strip().lower()
value = re.sub(r"[^a-z0-9._-]+", "-", value)
value = value.strip("-") or "trigger"
print(value[:96])
PY
}

bool_word() {
  if [[ "$1" == "1" || "$1" == "true" ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

resolve_serial_for_mode() {
  if [[ -n "$default_serial" ]]; then
    printf '%s\n' "$default_serial"
    return 0
  fi

  if [[ "$dry_run" == "1" ]]; then
    echo "pixel_boot_kgsl_trigger_ladder: --serial or PIXEL_SERIAL is required for --dry-run" >&2
    exit 2
  fi

  pixel_resolve_serial
}

prepare_matrix_dir() {
  if [[ -z "$matrix_dir" ]]; then
    matrix_dir="$(pixel_prepare_named_run_dir "$matrix_root")"
  else
    if [[ -e "$matrix_dir" ]] && find "$matrix_dir" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
      echo "pixel_boot_kgsl_trigger_ladder: output dir must be empty or absent: $matrix_dir" >&2
      exit 1
    fi
    mkdir -p "$matrix_dir"
  fi

  summary_path="$matrix_dir/matrix-summary.json"
  table_path="$matrix_dir/matrix.tsv"
  manifest_path="$matrix_dir/cases.tsv"
  printf '# case_name\tserial\ttrigger\n' >"$manifest_path"
}

write_matrix_outputs() {
  python3 - "$summary_path" "$table_path" "$matrix_dir" "$serial" "$input_image" "$kgsl_timeout_secs" "${case_json_paths[@]}" <<'PY'
import json
import sys
from collections import Counter
from pathlib import Path

summary_path, table_path, output_dir, serial, input_image, kgsl_timeout_secs, *case_json_paths = sys.argv[1:]
cases = []
for path_str in case_json_paths:
    path = Path(path_str)
    if not path.exists():
        continue
    with path.open("r", encoding="utf-8") as fh:
        cases.append(json.load(fh))

second_stage_proved_cases = [
    case["case_name"] for case in cases if case.get("second_stage_property_proved_current_boot") is True
]
init_script_selection_proved_cases = [
    case["case_name"] for case in cases if case.get("init_script_selection_proved_current_boot") is True
]
imported_rc_proved_cases = [
    case["case_name"] for case in cases if case.get("imported_rc_proved_current_boot") is True
]
control_point_proved_cases = [
    case["case_name"] for case in cases if case.get("control_point_proved_current_boot") is True
]
import_proved_cases = [case["case_name"] for case in cases if case.get("import_proved_current_boot") is True]
helper_launch_cases = [case["case_name"] for case in cases if case.get("helper_launch_proved_current_boot") is True]
kgsl_result_cases = [case["case_name"] for case in cases if case.get("kgsl_result")]
discriminator_counts = Counter(str(case.get("launch_discriminator") or "unknown") for case in cases)

payload = {
    "kind": "boot_kgsl_trigger_ladder",
    "ok": all(case.get("ok") is True for case in cases),
    "serial": serial,
    "input_image": input_image,
    "kgsl_timeout_secs": int(kgsl_timeout_secs),
    "output_dir": output_dir,
    "case_count": len(cases),
    "second_stage_proved_case_count": len(second_stage_proved_cases),
    "init_script_selection_proved_case_count": len(init_script_selection_proved_cases),
    "imported_rc_proved_case_count": len(imported_rc_proved_cases),
    "control_point_proved_case_count": len(control_point_proved_cases),
    "import_proved_case_count": len(import_proved_cases),
    "helper_launch_case_count": len(helper_launch_cases),
    "kgsl_result_case_count": len(kgsl_result_cases),
    "second_stage_proved_cases": second_stage_proved_cases,
    "init_script_selection_proved_cases": init_script_selection_proved_cases,
    "imported_rc_proved_cases": imported_rc_proved_cases,
    "control_point_proved_cases": control_point_proved_cases,
    "import_proved_cases": import_proved_cases,
    "helper_launch_cases": helper_launch_cases,
    "kgsl_result_cases": kgsl_result_cases,
    "first_second_stage_proved_case": second_stage_proved_cases[0] if second_stage_proved_cases else "",
    "first_init_script_selection_proved_case": init_script_selection_proved_cases[0] if init_script_selection_proved_cases else "",
    "first_imported_rc_proved_case": imported_rc_proved_cases[0] if imported_rc_proved_cases else "",
    "first_control_point_proved_case": control_point_proved_cases[0] if control_point_proved_cases else "",
    "first_import_proved_case": import_proved_cases[0] if import_proved_cases else "",
    "first_helper_launch_case": helper_launch_cases[0] if helper_launch_cases else "",
    "first_kgsl_result_case": kgsl_result_cases[0] if kgsl_result_cases else "",
    "discriminator_case_counts": dict(sorted(discriminator_counts.items())),
    "surviving_discriminator": next(iter(discriminator_counts)) if len(discriminator_counts) == 1 else "",
    "cases": cases,
}
Path(summary_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

columns = [
    "case_name",
    "trigger",
    "ok",
    "second_stage_property_proved_current_boot",
    "init_script_selection_proved_current_boot",
    "imported_rc_proved_current_boot",
    "control_point_proved_current_boot",
    "import_proved_current_boot",
    "helper_launch_proved_current_boot",
    "helper_proved_current_boot",
    "launch_discriminator",
    "kgsl_result",
    "kgsl_stage",
    "kgsl_wchan",
    "adb_ready",
    "transport_last_state",
    "failure_stage",
    "bootreason_sys_boot_reason",
]
lines = ["\t".join(columns)]
for case in cases:
    lines.append(
        "\t".join(
            [
                str(case.get("case_name") or ""),
                str(case.get("trigger") or ""),
                "true" if case.get("ok") else "false",
                "true" if case.get("second_stage_property_proved_current_boot") else "false",
                "true" if case.get("init_script_selection_proved_current_boot") else "false",
                "true" if case.get("imported_rc_proved_current_boot") else "false",
                "true" if case.get("control_point_proved_current_boot") else "false",
                "true" if case.get("import_proved_current_boot") else "false",
                "true" if case.get("helper_launch_proved_current_boot") else "false",
                "true" if case.get("helper_proved_current_boot") else "false",
                str(case.get("launch_discriminator") or ""),
                str(case.get("kgsl_result") or ""),
                str(case.get("kgsl_stage") or ""),
                str(case.get("kgsl_wchan") or ""),
                str(case.get("adb_ready") if case.get("adb_ready") is not None else ""),
                str(case.get("transport_last_state") or ""),
                str(case.get("failure_stage") or ""),
                str(case.get("bootreason_sys_boot_reason") or ""),
            ]
        )
    )
Path(table_path).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

run_case() {
  local case_index trigger_value trigger_slug case_name case_dir case_output case_json case_status
  local -a runner_args

  case_index="${1:?run_case requires a case index}"
  trigger_value="${2:?run_case requires a trigger}"
  trigger_slug="$(slugify_trigger "$trigger_value")"
  case_name="$(printf '%02d-%s' "$case_index" "$trigger_slug")"
  case_dir="$matrix_dir/$case_name"
  case_output="$case_dir/output"
  case_json="$case_output/summary.json"
  case_status=0

  mkdir -p "$case_dir"
  printf '%s\t%s\t%s\n' "$case_name" "$serial" "$trigger_value" >>"$manifest_path"
  printf '[boot-kgsl-trigger-ladder] %s trigger=%s\n' "$case_name" "$trigger_value"

  runner_args=(
    --serial "$serial"
    --output-dir "$case_output"
    --trigger "$trigger_value"
    --device-log-root "$device_log_root"
    --launch-proof-prop "$launch_proof_prop"
    --second-stage-proof-prop "$second_stage_proof_prop"
    --init-script-selection-proof-prop "$init_script_selection_proof_prop"
    --imported-rc-proof-prop "$imported_rc_proof_prop"
    --control-point-prop "$control_point_prop"
    --control-point-proof-prop "$control_point_proof_prop"
    --timeout "$kgsl_timeout_secs"
    --wait-ready "$wait_ready_secs"
    --adb-timeout "$adb_timeout_secs"
    --boot-timeout "$boot_timeout_secs"
  )
  if [[ -n "$input_image" ]]; then
    runner_args+=(--input "$input_image")
  fi
  if [[ -n "$key_path" ]]; then
    runner_args+=(--key "$key_path")
  fi
  if [[ -n "$patch_target_override" ]]; then
    runner_args+=(--patch-target "$patch_target_override")
  fi
  if [[ "$recover_traces_after" == "1" ]]; then
    runner_args+=(--recover-traces-after)
  fi
  if [[ "$wait_boot_completed" != "1" ]]; then
    runner_args+=(--no-wait-boot-completed)
  fi
  if [[ "$dry_run" == "1" ]]; then
    runner_args+=(--dry-run)
  fi

  set +e
  PIXEL_HOST_LOCK_HELD_SERIAL="$serial" \
    "$runner_script" "${runner_args[@]}" >"$case_dir/run.log" 2>&1
  case_status="$?"
  set -e

  if [[ -f "$case_json" ]]; then
    python3 - "$case_json" "$case_name" "$trigger_value" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
case_name = sys.argv[2]
trigger = sys.argv[3]
with path.open("r", encoding="utf-8") as fh:
    payload = json.load(fh)
payload["case_name"] = case_name
payload["trigger"] = trigger
path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  fi
  case_json_paths+=("$case_json")

  if [[ "$case_status" -ne 0 ]]; then
    return "$case_status"
  fi
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      matrix_dir="${2:?missing value for --output-dir}"
      shift 2
      ;;
    --serial)
      default_serial="${2:?missing value for --serial}"
      shift 2
      ;;
    --input)
      input_image="${2:?missing value for --input}"
      shift 2
      ;;
    --key)
      key_path="${2:?missing value for --key}"
      shift 2
      ;;
    --trigger)
      triggers+=("${2:?missing value for --trigger}")
      shift 2
      ;;
    --device-log-root)
      device_log_root="${2:?missing value for --device-log-root}"
      shift 2
      ;;
    --launch-proof-prop)
      launch_proof_prop="${2:?missing value for --launch-proof-prop}"
      shift 2
      ;;
    --second-stage-proof-prop)
      second_stage_proof_prop="${2:?missing value for --second-stage-proof-prop}"
      shift 2
      ;;
    --init-script-selection-proof-prop)
      init_script_selection_proof_prop="${2:?missing value for --init-script-selection-proof-prop}"
      shift 2
      ;;
    --imported-rc-proof-prop)
      imported_rc_proof_prop="${2:?missing value for --imported-rc-proof-prop}"
      shift 2
      ;;
    --control-point-prop)
      control_point_prop="${2:?missing value for --control-point-prop}"
      shift 2
      ;;
    --control-point-proof-prop)
      control_point_proof_prop="${2:?missing value for --control-point-proof-prop}"
      shift 2
      ;;
    --timeout)
      kgsl_timeout_secs="${2:?missing value for --timeout}"
      shift 2
      ;;
    --patch-target)
      patch_target_override="${2:?missing value for --patch-target}"
      shift 2
      ;;
    --wait-ready)
      wait_ready_secs="${2:?missing value for --wait-ready}"
      shift 2
      ;;
    --adb-timeout)
      adb_timeout_secs="${2:?missing value for --adb-timeout}"
      shift 2
      ;;
    --boot-timeout)
      boot_timeout_secs="${2:?missing value for --boot-timeout}"
      shift 2
      ;;
    --recover-traces-after)
      recover_traces_after=1
      shift
      ;;
    --no-wait-boot-completed)
      wait_boot_completed=0
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "pixel_boot_kgsl_trigger_ladder: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${#triggers[@]}" -eq 0 ]]; then
  append_default_triggers
fi

serial="$(resolve_serial_for_mode)"
pixel_prepare_dirs
pixel_require_host_lock "$serial" "$0" "${original_args[@]}"
prepare_matrix_dir

case_index=0
matrix_status=0
for trigger_value in "${triggers[@]}"; do
  case_index=$((case_index + 1))
  if run_case "$case_index" "$trigger_value"; then
    :
  else
    case_status="$?"
    if [[ "$matrix_status" -eq 0 ]]; then
      matrix_status="$case_status"
    fi
  fi
done

write_matrix_outputs

printf 'KGSL trigger ladder output: %s\n' "$matrix_dir"
printf 'Serial: %s\n' "$serial"
printf 'Case count: %s\n' "${#triggers[@]}"
printf 'Summary: %s\n' "$summary_path"

exit "$matrix_status"
