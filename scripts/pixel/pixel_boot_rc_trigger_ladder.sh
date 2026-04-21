#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

original_args=("$@")
matrix_root="$(pixel_runs_dir)/boot-rc-trigger-ladder"
matrix_dir="${PIXEL_BOOT_RC_TRIGGER_LADDER_DIR:-}"
input_image="${PIXEL_BOOT_INPUT_IMAGE:-}"
key_path="${AVB_TEST_KEY_PATH:-}"
default_serial="${PIXEL_SERIAL:-}"
property_key="${PIXEL_BOOT_RC_TRIGGER_LADDER_PROPERTY_KEY:-shadow.boot.rc_probe}"
patch_target_override="${PIXEL_BOOT_RC_TRIGGER_LADDER_PATCH_TARGET:-}"
wait_ready_secs="${PIXEL_BOOT_RC_TRIGGER_LADDER_WAIT_READY_SECS:-120}"
adb_timeout_secs="${PIXEL_BOOT_RC_TRIGGER_LADDER_ADB_TIMEOUT_SECS:-180}"
boot_timeout_secs="${PIXEL_BOOT_RC_TRIGGER_LADDER_BOOT_TIMEOUT_SECS:-240}"
recover_traces_after="${PIXEL_BOOT_RC_TRIGGER_LADDER_RECOVER_TRACES_AFTER:-0}"
wait_boot_completed=1
dry_run=0
serial=""
matrix_status=0
images_dir=""
manifest_copy_path=""
summary_path=""
table_path=""
build_script="${PIXEL_BOOT_RC_TRIGGER_LADDER_BUILD_SCRIPT:-$SCRIPT_DIR/pixel/pixel_boot_build_rc_probe.sh}"
oneshot_script="${PIXEL_BOOT_RC_TRIGGER_LADDER_ONESHOT_SCRIPT:-$SCRIPT_DIR/pixel/pixel_boot_oneshot.sh}"
declare -a triggers=()
declare -a case_json_paths=()

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_rc_trigger_ladder.sh [--output-dir DIR] [--serial SERIAL]
                                                     [--input PATH] [--key PATH]
                                                     [--trigger EXPR]...
                                                     [--property-key KEY]
                                                     [--patch-target ENTRY]
                                                     [--wait-ready SECONDS]
                                                     [--adb-timeout SECONDS]
                                                     [--boot-timeout SECONDS]
                                                     [--recover-traces-after]
                                                     [--no-wait-boot-completed]
                                                     [--dry-run]

Build stock-init property-only rc-probe images for a small trigger ladder and run
them through the one-shot boot loop with explicit proof-property collection.

Default triggers:
  post-fs-data
  property:init.svc.pd_mapper=running
  property:init.svc.qseecom-service=running
  property:init.svc.gpu=running
  property:sys.boot_completed=1
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
  local trigger
  while IFS= read -r trigger; do
    [[ -n "$trigger" ]] || continue
    triggers+=("$trigger")
  done < <(default_triggers)
}

bool_word() {
  if [[ "$1" == "1" || "$1" == "true" ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

validate_property_key() {
  [[ "$property_key" =~ ^[A-Za-z0-9_.-]+$ ]] || {
    echo "pixel_boot_rc_trigger_ladder: --property-key contains unsupported characters" >&2
    exit 2
  }
}

validate_patch_target_override() {
  [[ -z "$patch_target_override" ]] && return 0
  [[ "$patch_target_override" =~ ^[A-Za-z0-9._/-]+$ ]] || {
    echo "pixel_boot_rc_trigger_ladder: --patch-target contains unsupported characters" >&2
    exit 2
  }
}

slugify_trigger() {
  local trigger
  trigger="${1:?slugify_trigger requires a trigger}"
  python3 - "$trigger" <<'PY'
import re
import sys

value = sys.argv[1].strip().lower()
value = re.sub(r"[^a-z0-9._-]+", "-", value)
value = value.strip("-") or "trigger"
print(value[:96])
PY
}

resolve_serial_for_mode() {
  if [[ -n "$default_serial" ]]; then
    printf '%s\n' "$default_serial"
    return 0
  fi

  if [[ "$dry_run" == "1" ]]; then
    echo "pixel_boot_rc_trigger_ladder: --serial or PIXEL_SERIAL is required for --dry-run" >&2
    exit 2
  fi

  pixel_resolve_serial
}

prepare_matrix_dir() {
  if [[ -z "$matrix_dir" ]]; then
    matrix_dir="$(pixel_prepare_named_run_dir "$matrix_root")"
  else
    if [[ -e "$matrix_dir" ]] && find "$matrix_dir" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
      echo "pixel_boot_rc_trigger_ladder: output dir must be empty or absent: $matrix_dir" >&2
      exit 1
    fi
    mkdir -p "$matrix_dir"
  fi

  images_dir="$matrix_dir/images"
  manifest_copy_path="$matrix_dir/cases.tsv"
  summary_path="$matrix_dir/matrix-summary.json"
  table_path="$matrix_dir/matrix.tsv"
  mkdir -p "$images_dir"
}

prepare_manifest() {
  cat >"$manifest_copy_path" <<'EOF'
# case_name	serial	trigger	property_assignment
EOF
}

append_manifest_case() {
  local case_name trigger property_assignment
  case_name="${1:?append_manifest_case requires a case name}"
  trigger="${2:?append_manifest_case requires a trigger}"
  property_assignment="${3:?append_manifest_case requires a property assignment}"
  printf '%s\t%s\t%s\t%s\n' "$case_name" "$serial" "$trigger" "$property_assignment" >>"$manifest_copy_path"
}

write_case_json() {
  local output_path case_name trigger property_value property_assignment image_path build_log
  local build_exit_status run_log case_exit_status device_run_dir status_path collect_status_path
  output_path="${1:?write_case_json requires an output path}"
  case_name="${2:?write_case_json requires a case name}"
  trigger="${3:?write_case_json requires a trigger}"
  property_value="${4:?write_case_json requires a property value}"
  property_assignment="${5:?write_case_json requires a property assignment}"
  image_path="${6:?write_case_json requires an image path}"
  build_log="${7:?write_case_json requires a build log path}"
  build_exit_status="${8:?write_case_json requires a build exit status}"
  run_log="${9:?write_case_json requires a run log path}"
  case_exit_status="${10:?write_case_json requires a case exit status}"
  device_run_dir="${11:?write_case_json requires a device run dir}"
  status_path="${12:?write_case_json requires a device status path}"
  collect_status_path="${13:?write_case_json requires a collect status path}"

  python3 - \
    "$output_path" \
    "$case_name" \
    "$serial" \
    "$trigger" \
    "$property_key" \
    "$property_value" \
    "$property_assignment" \
    "$image_path" \
    "$build_log" \
    "$build_exit_status" \
    "$run_log" \
    "$case_exit_status" \
    "$(bool_word "$dry_run")" \
    "$device_run_dir" \
    "$status_path" \
    "$collect_status_path" <<'PY'
import json
import sys
from pathlib import Path

(
    output_path,
    case_name,
    serial,
    trigger,
    property_key,
    property_value,
    property_assignment,
    image_path,
    build_log,
    build_exit_status,
    run_log,
    case_exit_status,
    dry_run,
    device_run_dir,
    status_path,
    collect_status_path,
) = sys.argv[1:17]


def load_json(path_str: str):
    if not path_str:
        return None
    path = Path(path_str)
    if not path.exists():
        return None
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


device_status = load_json(status_path)
collect_status = load_json(collect_status_path)
proof_actual = ""
proof_matched = False
if isinstance(collect_status, dict):
    proof_actual = str(collect_status.get("proof_property_actual") or "")
    proof_matched = bool(collect_status.get("proof_property_matched"))
elif isinstance(device_status, dict):
    proof_actual = str(device_status.get("shadow_probe_prop") or "")
    proof_matched = proof_actual == property_value

payload = {
    "case_name": case_name,
    "serial": serial,
    "trigger": trigger,
    "property_key": property_key,
    "property_value": property_value,
    "property_assignment": property_assignment,
    "image_path": image_path,
    "build_log": build_log,
    "build_exit_status": int(build_exit_status),
    "build_succeeded": int(build_exit_status) == 0,
    "run_log": run_log,
    "exit_status": int(case_exit_status),
    "run_succeeded": int(case_exit_status) == 0,
    "dry_run": dry_run == "true",
    "device_run_dir": device_run_dir,
    "device_status_path": status_path,
    "collect_status_path": collect_status_path,
    "device_status": device_status,
    "collect_status": collect_status,
    "proof_property_actual": proof_actual,
    "proof_property_matched": proof_matched,
    "adb_ready": (device_status or {}).get("adb_ready"),
    "boot_completed": (device_status or {}).get("boot_completed"),
    "failure_stage": str((device_status or {}).get("failure_stage") or ""),
}
payload["success"] = payload["dry_run"] or (
    payload["build_succeeded"] and payload["run_succeeded"] and payload["proof_property_matched"]
)

Path(output_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

write_matrix_outputs() {
  python3 - \
    "$summary_path" \
    "$table_path" \
    "$matrix_dir" \
    "$serial" \
    "$input_image" \
    "$property_key" \
    "$wait_ready_secs" \
    "$adb_timeout_secs" \
    "$boot_timeout_secs" \
    "$(bool_word "$wait_boot_completed")" \
    "$(bool_word "$recover_traces_after")" \
    "$(bool_word "$dry_run")" \
    "$manifest_copy_path" \
    "${case_json_paths[@]}" <<'PY'
import json
import sys
from pathlib import Path

(
    summary_path,
    table_path,
    output_dir,
    serial,
    input_image,
    property_key,
    wait_ready_secs,
    adb_timeout_secs,
    boot_timeout_secs,
    wait_boot_completed,
    recover_traces_after,
    dry_run,
    manifest_path,
    *case_json_paths,
) = sys.argv[1:]

cases = []
for path_str in case_json_paths:
    path = Path(path_str)
    if not path.exists():
        continue
    with path.open("r", encoding="utf-8") as fh:
        cases.append(json.load(fh))

matched_cases = [case["case_name"] for case in cases if case.get("proof_property_matched") is True]
successful_cases = [case["case_name"] for case in cases if case.get("success") is True]
payload = {
    "kind": "boot_rc_trigger_ladder",
    "ok": all(case.get("success") is True for case in cases),
    "serial": serial,
    "input_image": input_image,
    "output_dir": output_dir,
    "property_key": property_key,
    "wait_ready_secs": int(wait_ready_secs),
    "adb_timeout_secs": int(adb_timeout_secs),
    "boot_timeout_secs": int(boot_timeout_secs),
    "wait_boot_completed": wait_boot_completed == "true",
    "recover_traces_after": recover_traces_after == "true",
    "dry_run": dry_run == "true",
    "manifest_path": manifest_path,
    "case_count": len(cases),
    "matched_case_count": len(matched_cases),
    "successful_case_count": len(successful_cases),
    "matched_cases": matched_cases,
    "successful_cases": successful_cases,
    "cases": cases,
}

Path(summary_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

columns = [
    "case_name",
    "trigger",
    "property_assignment",
    "success",
    "build_exit_status",
    "exit_status",
    "proof_property_matched",
    "proof_property_actual",
    "adb_ready",
    "boot_completed",
    "failure_stage",
]
lines = ["\t".join(columns)]
for case in cases:
    lines.append(
        "\t".join(
            [
                str(case.get("case_name") or ""),
                str(case.get("trigger") or ""),
                str(case.get("property_assignment") or ""),
                "true" if case.get("success") else "false",
                str(case.get("build_exit_status") or 0),
                str(case.get("exit_status") or 0),
                "true" if case.get("proof_property_matched") else "false",
                str(case.get("proof_property_actual") or ""),
                str(case.get("adb_ready") if case.get("adb_ready") is not None else ""),
                str(case.get("boot_completed") if case.get("boot_completed") is not None else ""),
                str(case.get("failure_stage") or ""),
            ]
        )
    )
Path(table_path).write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

run_case() {
  local case_index trigger trigger_slug case_name property_value property_assignment
  local case_dir image_path build_log run_log case_json device_run_dir status_path collect_status_path
  local build_exit_status case_exit_status
  local -a build_args run_args

  case_index="${1:?run_case requires a case index}"
  trigger="${2:?run_case requires a trigger}"
  trigger_slug="$(slugify_trigger "$trigger")"
  case_name="$(printf '%02d-%s' "$case_index" "$trigger_slug")"
  property_value="$(printf 'rc-trigger-%02d-%s' "$case_index" "$trigger_slug")"
  property_assignment="${property_key}=${property_value}"
  case_dir="$matrix_dir/$case_name"
  image_path="$images_dir/$case_name.img"
  build_log="$case_dir/build.log"
  run_log="$case_dir/run.log"
  case_json="$case_dir/case.json"
  device_run_dir="$case_dir/device-run"
  status_path="$device_run_dir/status.json"
  collect_status_path="$device_run_dir/collect/status.json"
  build_exit_status=0
  case_exit_status=0

  mkdir -p "$case_dir"
  append_manifest_case "$case_name" "$trigger" "$property_assignment"
  printf '[boot-rc-trigger-ladder] %s trigger=%s\n' "$case_name" "$trigger"

  build_args=(
    --input "$input_image"
    --key "$key_path"
    --output "$image_path"
    --trigger "$trigger"
    --property "$property_assignment"
  )
  if [[ -n "$patch_target_override" ]]; then
    build_args+=(--patch-target "$patch_target_override")
  fi

  run_args=(
    --image "$image_path"
    --output "$device_run_dir"
    --wait-ready "$wait_ready_secs"
    --adb-timeout "$adb_timeout_secs"
    --boot-timeout "$boot_timeout_secs"
    --proof-prop "$property_assignment"
  )
  if [[ "$recover_traces_after" == "1" ]]; then
    run_args+=(--recover-traces-after)
  fi
  if [[ "$wait_boot_completed" != "1" ]]; then
    run_args+=(--no-wait-boot-completed)
  fi

  if [[ "$dry_run" == "1" ]]; then
    {
      printf 'build_command='
      printf '%q ' "$build_script" "${build_args[@]}"
      printf '\nrun_command='
      printf 'PIXEL_SERIAL=%q ' "$serial"
      printf '%q ' "$oneshot_script" "${run_args[@]}"
      printf '\n'
    } >"$case_dir/plan.txt"
  else
    set +e
    "$build_script" "${build_args[@]}" >"$build_log" 2>&1
    build_exit_status=$?
    set -e
    if [[ "$build_exit_status" -eq 0 && ! -f "$image_path" ]]; then
      printf 'pixel_boot_rc_trigger_ladder: build script reported success but image is missing: %s\n' "$image_path" >>"$build_log"
      build_exit_status=72
      case_exit_status=72
    elif [[ "$build_exit_status" -eq 0 ]]; then
      set +e
      PIXEL_SERIAL="$serial" "$oneshot_script" "${run_args[@]}" >"$run_log" 2>&1
      case_exit_status=$?
      set -e
    else
      case_exit_status="$build_exit_status"
    fi
  fi

  write_case_json \
    "$case_json" \
    "$case_name" \
    "$trigger" \
    "$property_value" \
    "$property_assignment" \
    "$image_path" \
    "$build_log" \
    "$build_exit_status" \
    "$run_log" \
    "$case_exit_status" \
    "$device_run_dir" \
    "$status_path" \
    "$collect_status_path"
  case_json_paths+=("$case_json")

  if [[ "$dry_run" != "1" ]]; then
    if [[ "$build_exit_status" -ne 0 && "$matrix_status" -eq 0 ]]; then
      matrix_status="$build_exit_status"
    elif [[ "$case_exit_status" -ne 0 && "$matrix_status" -eq 0 ]]; then
      matrix_status="$case_exit_status"
    elif ! python3 - "$case_json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

raise SystemExit(0 if payload.get("success") is True else 1)
PY
    then
      if [[ "$matrix_status" -eq 0 ]]; then
        matrix_status=70
      fi
    fi
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      matrix_dir="${2:?pixel_boot_rc_trigger_ladder: --output-dir requires a value}"
      shift 2
      ;;
    --output-dir=*)
      matrix_dir="${1#*=}"
      shift
      ;;
    --serial)
      default_serial="${2:?pixel_boot_rc_trigger_ladder: --serial requires a value}"
      shift 2
      ;;
    --serial=*)
      default_serial="${1#*=}"
      shift
      ;;
    --input)
      input_image="${2:?pixel_boot_rc_trigger_ladder: --input requires a value}"
      shift 2
      ;;
    --input=*)
      input_image="${1#*=}"
      shift
      ;;
    --key)
      key_path="${2:?pixel_boot_rc_trigger_ladder: --key requires a value}"
      shift 2
      ;;
    --key=*)
      key_path="${1#*=}"
      shift
      ;;
    --trigger)
      triggers+=("${2:?pixel_boot_rc_trigger_ladder: --trigger requires a value}")
      shift 2
      ;;
    --trigger=*)
      triggers+=("${1#*=}")
      shift
      ;;
    --property-key)
      property_key="${2:?pixel_boot_rc_trigger_ladder: --property-key requires a value}"
      shift 2
      ;;
    --property-key=*)
      property_key="${1#*=}"
      shift
      ;;
    --patch-target)
      patch_target_override="${2:?pixel_boot_rc_trigger_ladder: --patch-target requires a value}"
      shift 2
      ;;
    --patch-target=*)
      patch_target_override="${1#*=}"
      shift
      ;;
    --wait-ready)
      wait_ready_secs="${2:?pixel_boot_rc_trigger_ladder: --wait-ready requires a value}"
      shift 2
      ;;
    --wait-ready=*)
      wait_ready_secs="${1#*=}"
      shift
      ;;
    --adb-timeout)
      adb_timeout_secs="${2:?pixel_boot_rc_trigger_ladder: --adb-timeout requires a value}"
      shift 2
      ;;
    --adb-timeout=*)
      adb_timeout_secs="${1#*=}"
      shift
      ;;
    --boot-timeout)
      boot_timeout_secs="${2:?pixel_boot_rc_trigger_ladder: --boot-timeout requires a value}"
      shift 2
      ;;
    --boot-timeout=*)
      boot_timeout_secs="${1#*=}"
      shift
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
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "pixel_boot_rc_trigger_ladder: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${#triggers[@]}" -eq 0 ]]; then
  append_default_triggers
fi

if [[ -z "$input_image" ]]; then
  input_image="$(pixel_resolve_stock_boot_img || true)"
fi

[[ -f "$input_image" ]] || {
  cat <<EOF >&2
pixel_boot_rc_trigger_ladder: input image not found: $input_image

Run 'sc root-prep' first to cache the stock sunfish boot.img.
EOF
  exit 1
}

validate_property_key
validate_patch_target_override
[[ -x "$build_script" ]] || {
  echo "pixel_boot_rc_trigger_ladder: build script not executable: $build_script" >&2
  exit 1
}
[[ -x "$oneshot_script" ]] || {
  echo "pixel_boot_rc_trigger_ladder: oneshot script not executable: $oneshot_script" >&2
  exit 1
}

pixel_prepare_dirs
serial="$(resolve_serial_for_mode)"
pixel_require_host_lock "$serial" "$0" "${original_args[@]}"

if [[ -z "$key_path" && "$dry_run" != "1" ]]; then
  key_path="$(ensure_cached_avb_testkey)"
elif [[ -z "$key_path" ]]; then
  key_path="<auto>"
fi

prepare_matrix_dir
prepare_manifest

case_index=0
for trigger in "${triggers[@]}"; do
  case_index=$((case_index + 1))
  run_case "$case_index" "$trigger"
done

write_matrix_outputs

printf 'Trigger ladder output: %s\n' "$matrix_dir"
printf 'Trigger ladder summary: %s\n' "$summary_path"
printf 'Trigger ladder table: %s\n' "$table_path"

if [[ "$dry_run" == "1" ]]; then
  printf 'Dry-run cases: %s\n' "${#case_json_paths[@]}"
else
  python3 - "$summary_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

print(f"Matched cases: {payload.get('matched_case_count', 0)} / {payload.get('case_count', 0)}")
PY
fi

exit "$matrix_status"
