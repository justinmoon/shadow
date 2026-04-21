#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs

original_args=("$@")
matrix_root="$(pixel_runs_dir)/kgsl-cold-matrix"
matrix_dir="${PIXEL_KGSL_COLD_MATRIX_DIR-}"
manifest_path=""
scene="${PIXEL_KGSL_COLD_MATRIX_SCENE:-raw-kgsl-open-readonly-smoke}"
profile="${PIXEL_KGSL_COLD_MATRIX_PROFILE:-dri+kgsl}"
default_serial="${PIXEL_KGSL_COLD_MATRIX_DEFAULT_SERIAL:-${PIXEL_SERIAL:-}}"
dry_run=0
matrix_status=0

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_kgsl_cold_matrix.sh [--output-dir DIR] [--manifest FILE]
                                               [--serial SERIAL] [--scene SCENE]
                                               [--profile PROFILE] [--dry-run]

Run a rooted cold-boot KGSL availability matrix using the tmpfs-/dev control
harness.

Manifest format:
  case_name<TAB>serial<TAB>origin<TAB>readiness<TAB>extra_wait_secs<TAB>scene<TAB>profile

Supported origin values:
  warm
  reboot

Supported readiness values:
  root-ready
  pd-mapper
  qseecom-service
  gpu-service
  display-services
  boot-complete
  display-restored

Notes:
  - manifests are intentionally single-serial; reserve one phone per matrix lane
  - non-numeric extra_wait_secs values are rejected up front
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      matrix_dir="${2:?pixel_kgsl_cold_matrix: --output-dir requires a value}"
      shift 2
      ;;
    --output-dir=*)
      matrix_dir="${1#*=}"
      shift
      ;;
    --manifest)
      manifest_path="${2:?pixel_kgsl_cold_matrix: --manifest requires a value}"
      shift 2
      ;;
    --manifest=*)
      manifest_path="${1#*=}"
      shift
      ;;
    --serial)
      default_serial="${2:?pixel_kgsl_cold_matrix: --serial requires a value}"
      shift 2
      ;;
    --serial=*)
      default_serial="${1#*=}"
      shift
      ;;
    --scene)
      scene="${2:?pixel_kgsl_cold_matrix: --scene requires a value}"
      shift 2
      ;;
    --scene=*)
      scene="${1#*=}"
      shift
      ;;
    --profile)
      profile="${2:?pixel_kgsl_cold_matrix: --profile requires a value}"
      shift 2
      ;;
    --profile=*)
      profile="${1#*=}"
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
      usage >&2
      exit 2
      ;;
  esac
done

generate_default_manifest() {
  local target_path serial
  target_path="${1:?generate_default_manifest requires a target path}"
  serial="${2:?generate_default_manifest requires a serial}"

  cat >"$target_path" <<EOF
# case_name	serial	origin	readiness	extra_wait_secs	scene	profile
warm-baseline	$serial	warm	display-restored	0	$scene	$profile
cold-root-ready	$serial	reboot	root-ready	0	$scene	$profile
cold-pd-mapper	$serial	reboot	pd-mapper	0	$scene	$profile
cold-qseecom-service	$serial	reboot	qseecom-service	0	$scene	$profile
cold-gpu-service	$serial	reboot	gpu-service	0	$scene	$profile
cold-display-services	$serial	reboot	display-services	0	$scene	$profile
cold-boot-complete	$serial	reboot	boot-complete	0	$scene	$profile
cold-display-restored	$serial	reboot	display-restored	0	$scene	$profile
EOF
}

validate_extra_wait_secs() {
  local extra_wait_secs
  extra_wait_secs="${1:?validate_extra_wait_secs requires a value}"
  [[ "$extra_wait_secs" =~ ^[0-9]+$ ]]
}

origin_supported() {
  case "${1:?origin_supported requires a value}" in
    warm|reboot)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

readiness_supported() {
  case "${1:?readiness_supported requires a value}" in
    root-ready|pd-mapper|qseecom-service|gpu-service|display-services|boot-complete|display-restored)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_manifest_serial() {
  local target_manifest fallback_serial resolved_serial
  local case_name serial origin readiness extra_wait_secs case_scene case_profile
  target_manifest="${1:?resolve_manifest_serial requires a manifest path}"
  fallback_serial="${2-}"
  resolved_serial=""

  while IFS=$'\t' read -r case_name serial origin readiness extra_wait_secs case_scene case_profile; do
    [[ -n "${case_name:-}" ]] || continue
    [[ "${case_name:0:1}" == "#" ]] && continue
    serial="${serial:-$fallback_serial}"
    extra_wait_secs="${extra_wait_secs:-0}"
    if [[ -z "$serial" ]]; then
      echo "pixel_kgsl_cold_matrix: missing serial for case $case_name" >&2
      return 2
    fi
    if ! origin_supported "$origin"; then
      echo "pixel_kgsl_cold_matrix: unsupported origin for case $case_name: $origin" >&2
      return 2
    fi
    if ! readiness_supported "$readiness"; then
      echo "pixel_kgsl_cold_matrix: unsupported readiness for case $case_name: $readiness" >&2
      return 2
    fi
    if ! validate_extra_wait_secs "$extra_wait_secs"; then
      echo "pixel_kgsl_cold_matrix: non-numeric extra_wait_secs for case $case_name: $extra_wait_secs" >&2
      return 2
    fi
    if [[ -z "$resolved_serial" ]]; then
      resolved_serial="$serial"
    elif [[ "$serial" != "$resolved_serial" ]]; then
      echo "pixel_kgsl_cold_matrix: multi-serial manifests are unsupported; split lanes by device" >&2
      echo "  saw both $resolved_serial and $serial" >&2
      return 2
    fi
  done <"$target_manifest"

  if [[ -z "$resolved_serial" ]]; then
    echo "pixel_kgsl_cold_matrix: manifest contains no runnable cases" >&2
    return 2
  fi

  printf '%s\n' "$resolved_serial"
}

capture_holder_scan() {
  local serial output_path stderr_path timeout_secs
  serial="${1:?capture_holder_scan requires a serial}"
  output_path="${2:?capture_holder_scan requires an output path}"
  stderr_path="${3:?capture_holder_scan requires a stderr path}"
  timeout_secs="${PIXEL_KGSL_HOLDER_SCAN_TIMEOUT_SECS:-20}"

  if [[ "$dry_run" == "1" ]]; then
    cat >"$output_path" <<'EOF'
format	shadow-kgsl-holder-scan-v1
device_path	/dev/kgsl-3d0
limits	8192	64
summary	4	12	0	false
EOF
    : >"$stderr_path"
    return 0
  fi

  set +e
  pixel_root_shell_timeout "$timeout_secs" "$serial" "$(pixel_kgsl_holder_scan_command)" \
    >"$output_path" 2>"$stderr_path"
  local status=$?
  set -e
  if [[ "$status" -eq 124 ]]; then
    printf 'pixel_kgsl_cold_matrix: holder scan timed out after %ss\n' "$timeout_secs" >>"$stderr_path"
  fi
  return "$status"
}

root_ready() {
  local serial
  serial="${1:?root_ready requires a serial}"
  pixel_root_id "$serial" >/dev/null 2>&1
}

prop_equals() {
  local serial key expected
  serial="${1:?prop_equals requires a serial}"
  key="${2:?prop_equals requires a key}"
  expected="${3:?prop_equals requires an expected value}"
  [[ "$(pixel_prop "$serial" "$key")" == "$expected" ]]
}

wait_for_readiness() {
  local serial readiness timeout_secs extra_wait_secs milestone_log
  serial="${1:?wait_for_readiness requires a serial}"
  readiness="${2:?wait_for_readiness requires readiness}"
  timeout_secs="${3:?wait_for_readiness requires timeout_secs}"
  extra_wait_secs="${4:?wait_for_readiness requires extra_wait_secs}"
  milestone_log="${5:?wait_for_readiness requires milestone_log}"

  if [[ "$dry_run" == "1" ]]; then
    printf '[kgsl-cold] readiness=%s dry_run=true\n' "$readiness" >>"$milestone_log"
    return 0
  fi

  if ! pixel_wait_for_adb "$serial" "$timeout_secs" >/dev/null; then
    return 1
  fi
  printf '[kgsl-cold] adb-ready\n' >>"$milestone_log"
  if ! pixel_wait_for_condition "$timeout_secs" 1 root_ready "$serial"; then
    return 1
  fi
  printf '[kgsl-cold] root-ready\n' >>"$milestone_log"

  case "$readiness" in
    root-ready)
      ;;
    pd-mapper)
      if ! pixel_wait_for_condition "$timeout_secs" 1 prop_equals "$serial" init.svc.pd_mapper running; then
        return 1
      fi
      printf '[kgsl-cold] pd-mapper\n' >>"$milestone_log"
      ;;
    qseecom-service)
      if ! pixel_wait_for_condition "$timeout_secs" 1 prop_equals "$serial" init.svc.qseecom-service running; then
        return 1
      fi
      printf '[kgsl-cold] qseecom-service\n' >>"$milestone_log"
      ;;
    gpu-service)
      if ! pixel_wait_for_condition "$timeout_secs" 1 prop_equals "$serial" init.svc.gpu running; then
        return 1
      fi
      printf '[kgsl-cold] gpu-service\n' >>"$milestone_log"
      ;;
    display-services)
      if ! pixel_wait_for_condition "$timeout_secs" 1 pixel_display_services_running "$serial"; then
        return 1
      fi
      printf '[kgsl-cold] display-services\n' >>"$milestone_log"
      ;;
    boot-complete)
      if ! pixel_wait_for_boot_completed "$serial" "$timeout_secs" >/dev/null; then
        return 1
      fi
      printf '[kgsl-cold] boot-complete\n' >>"$milestone_log"
      ;;
    display-restored)
      if ! pixel_wait_for_condition "$timeout_secs" 1 pixel_android_display_restored "$serial"; then
        return 1
      fi
      printf '[kgsl-cold] display-restored\n' >>"$milestone_log"
      ;;
    *)
      echo "pixel_kgsl_cold_matrix: unsupported readiness: $readiness" >&2
      return 2
      ;;
  esac

  if [[ "$extra_wait_secs" != "0" ]]; then
    printf '[kgsl-cold] extra-wait-secs=%s\n' "$extra_wait_secs" >>"$milestone_log"
    sleep "$extra_wait_secs"
  fi
}

collect_props_snapshot() {
  local serial output_path
  serial="${1:?collect_props_snapshot requires a serial}"
  output_path="${2:?collect_props_snapshot requires an output path}"

  if [[ "$dry_run" == "1" ]]; then
    cat >"$output_path" <<'EOF'
serial	TESTSERIAL
slot_suffix	_a
sys.boot_completed	1
dev.bootcomplete	1
init.svc.pd_mapper	running
init.svc.qseecom-service	running
init.svc.gpu	running
init.svc.surfaceflinger	running
init.svc.vendor.hwcomposer-2-4	running
init.svc.vendor.qti.hardware.display.allocator	running
uptime_secs	12.34
EOF
    return 0
  fi

  {
    printf 'serial\t%s\n' "$serial"
    printf 'slot_suffix\t%s\n' "$(pixel_prop "$serial" ro.boot.slot_suffix)"
    printf 'sys.boot_completed\t%s\n' "$(pixel_prop "$serial" sys.boot_completed)"
    printf 'dev.bootcomplete\t%s\n' "$(pixel_prop "$serial" dev.bootcomplete)"
    printf 'init.svc.pd_mapper\t%s\n' "$(pixel_prop "$serial" init.svc.pd_mapper)"
    printf 'init.svc.qseecom-service\t%s\n' "$(pixel_prop "$serial" init.svc.qseecom-service)"
    printf 'init.svc.gpu\t%s\n' "$(pixel_prop "$serial" init.svc.gpu)"
    printf 'init.svc.surfaceflinger\t%s\n' "$(pixel_service_state "$serial" surfaceflinger)"
    printf 'init.svc.vendor.hwcomposer-2-4\t%s\n' "$(pixel_service_state "$serial" vendor.hwcomposer-2-4)"
    printf 'init.svc.vendor.qti.hardware.display.allocator\t%s\n' \
      "$(pixel_service_state "$serial" vendor.qti.hardware.display.allocator)"
    printf 'uptime_secs\t%s\n' \
      "$(pixel_adb "$serial" shell cat /proc/uptime 2>/dev/null | tr -d '\r' | awk '{print $1}' || true)"
  } >"$output_path"
}

warm_case_preflight() {
  local serial milestone_log
  serial="${1:?warm_case_preflight requires a serial}"
  milestone_log="${2:?warm_case_preflight requires a milestone log}"

  if [[ "$dry_run" == "1" ]]; then
    printf '[kgsl-cold] warm-preflight dry_run=true\n' >>"$milestone_log"
    return 0
  fi

  if pixel_wait_for_condition 20 1 pixel_android_display_restored "$serial"; then
    printf '[kgsl-cold] warm-preflight display-restored\n' >>"$milestone_log"
    return 0
  fi

  printf '[kgsl-cold] warm-preflight restore-best-effort\n' >>"$milestone_log"
  pixel_restore_android_best_effort "$serial" 60 || true
  if ! pixel_wait_for_condition 60 1 pixel_android_display_restored "$serial"; then
    return 1
  fi
  printf '[kgsl-cold] warm-preflight restored\n' >>"$milestone_log"
}

write_case_json() {
  python3 - "$@" <<'PY'
import json
import sys
from pathlib import Path


def parse_holder_scan(path_raw: str):
    path = Path(path_raw)
    payload = {
        "path": str(path),
        "present": path.exists(),
        "holder_count": None,
        "has_holders": None,
        "truncated": None,
    }
    if not path.exists():
        return payload
    try:
        for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            parts = raw_line.split("\t")
            if parts[0] == "summary" and len(parts) >= 5:
                payload["holder_count"] = int(parts[3])
                payload["has_holders"] = int(parts[3]) > 0
                payload["truncated"] = parts[4] == "true"
                break
    except ValueError as exc:
        payload["parse_error"] = str(exc)
    return payload


def parse_props_snapshot(path_raw: str):
    path = Path(path_raw)
    payload = {"path": str(path), "present": path.exists(), "values": {}}
    if not path.exists():
        return payload
    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        parts = raw_line.split("\t", 1)
        if len(parts) == 2:
            payload["values"][parts[0]] = parts[1]
    return payload


(
    case_name,
    serial,
    origin,
    readiness,
    extra_wait_secs,
    scene,
    profile,
    case_dir,
    case_log,
    case_exit_status,
    reboot_attempted,
    readiness_ok,
    restore_ok,
    milestone_log_path,
    props_snapshot_path,
    before_scan_path,
    before_scan_stderr,
    after_scan_path,
    after_scan_stderr,
    device_run_dir,
    status_path,
    output_path,
    dry_run_word,
) = sys.argv[1:24]

status_payload = None
status_file = Path(status_path)
if status_file.is_file():
    status_payload = json.loads(status_file.read_text(encoding="utf-8"))

payload = {
    "case": case_name,
    "serial": serial,
    "origin": origin,
    "readiness": readiness,
    "extra_wait_secs": int(extra_wait_secs),
    "scene": scene,
    "profile": profile,
    "case_dir": case_dir,
    "case_log": case_log,
    "device_run_dir": device_run_dir,
    "exit_status": int(case_exit_status),
    "reboot_attempted": reboot_attempted == "true",
    "readiness_ok": readiness_ok == "true",
    "restore_ok": restore_ok == "true",
    "dry_run": dry_run_word == "true",
    "milestone_log_path": milestone_log_path,
    "milestones": Path(milestone_log_path).read_text(encoding="utf-8", errors="replace").splitlines()
    if Path(milestone_log_path).exists()
    else [],
    "props_snapshot": parse_props_snapshot(props_snapshot_path),
    "before_holder_scan": parse_holder_scan(before_scan_path),
    "after_holder_scan": parse_holder_scan(after_scan_path),
    "before_holder_scan_stderr_path": before_scan_stderr,
    "after_holder_scan_stderr_path": after_scan_stderr,
    "status_path": status_path,
    "status": status_payload,
    "run_succeeded": bool((status_payload or {}).get("run_succeeded")),
    "kgsl_device_opened": (status_payload or {}).get("summary", {}).get("kgsl_device_opened"),
}
payload["success"] = (
    payload["exit_status"] == 0
    and payload["readiness_ok"]
    and payload["restore_ok"]
    and (payload["run_succeeded"] is True or payload["dry_run"])
)

Path(output_path).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
print(json.dumps(payload, indent=2, sort_keys=True))
PY
}

run_case() {
  local case_name serial origin readiness extra_wait_secs case_scene case_profile
  local case_slug case_dir case_log case_json case_run_dir status_path
  local before_scan_path before_scan_stderr after_scan_path after_scan_stderr
  local milestone_log_path props_snapshot_path
  local reboot_attempted=false readiness_ok=false restore_ok=false case_exit_status=0

  case_name="${1:?run_case requires case_name}"
  serial="${2:?run_case requires serial}"
  origin="${3:?run_case requires origin}"
  readiness="${4:?run_case requires readiness}"
  extra_wait_secs="${5:?run_case requires extra_wait_secs}"
  case_scene="${6:?run_case requires case_scene}"
  case_profile="${7:?run_case requires case_profile}"

  case_slug="$(printf '%s' "$case_name" | tr -c 'A-Za-z0-9._-' '_')"
  case_dir="$matrix_dir/$case_slug"
  case_log="$case_dir/case.log"
  case_json="$case_dir/case.json"
  case_run_dir="$case_dir/device-run"
  status_path="$case_run_dir/status.json"
  before_scan_path="$case_dir/kgsl-holder-before.tsv"
  before_scan_stderr="$case_dir/kgsl-holder-before.stderr.txt"
  after_scan_path="$case_dir/kgsl-holder-after.tsv"
  after_scan_stderr="$case_dir/kgsl-holder-after.stderr.txt"
  milestone_log_path="$case_dir/milestones.log"
  props_snapshot_path="$case_dir/props.tsv"

  rm -rf "$case_dir"
  mkdir -p "$case_dir"
  : >"$milestone_log_path"

  {
    printf '[kgsl-cold] case=%s serial=%s origin=%s readiness=%s extra_wait_secs=%s scene=%s profile=%s dry_run=%s\n' \
      "$case_name" "$serial" "$origin" "$readiness" "$extra_wait_secs" "$case_scene" "$case_profile" "$dry_run"

    if [[ "$origin" == "warm" ]]; then
      if ! warm_case_preflight "$serial" "$milestone_log_path"; then
        case_exit_status=69
      fi
    elif [[ "$origin" == "reboot" ]]; then
      reboot_attempted=true
      if [[ "$dry_run" != "1" ]]; then
        if ! pixel_adb "$serial" reboot >/dev/null; then
          case_exit_status=68
        fi
      fi
      if [[ "$case_exit_status" -eq 0 ]]; then
        printf '[kgsl-cold] reboot-attempted\n' >>"$milestone_log_path"
      else
        printf '[kgsl-cold] reboot-failed\n' >>"$milestone_log_path"
      fi
    else
      echo "pixel_kgsl_cold_matrix: unsupported origin: $origin" >&2
      case_exit_status=2
    fi

    if [[ "$case_exit_status" -eq 0 ]]; then
      if wait_for_readiness "$serial" "$readiness" 180 "$extra_wait_secs" "$milestone_log_path"; then
        readiness_ok=true
      else
        case_exit_status=70
      fi
    fi
    printf '[kgsl-cold] readiness_ok=%s\n' "$readiness_ok"

    collect_props_snapshot "$serial" "$props_snapshot_path" || true
    capture_holder_scan "$serial" "$before_scan_path" "$before_scan_stderr" || true

    if [[ "$readiness_ok" == "true" ]]; then
      if [[ "$dry_run" == "1" ]]; then
        case_exit_status=0
      else
        set +e
        PIXEL_SERIAL="$serial" \
          PIXEL_GPU_TMPFS_DEV_RUN_DIR="$case_run_dir" \
          "$SCRIPT_DIR/pixel/pixel_tmpfs_dev_gpu_smoke.sh" \
          --profile "$case_profile" \
          --scene "$case_scene"
        case_exit_status=$?
        set -e
      fi
    fi
    printf '[kgsl-cold] case_exit_status=%s\n' "$case_exit_status"

    if [[ "$dry_run" == "1" ]]; then
      restore_ok=true
    elif pixel_wait_for_condition 60 1 pixel_android_display_restored "$serial"; then
      restore_ok=true
    else
      pixel_restore_android_best_effort "$serial" 60 || true
      if pixel_wait_for_condition 60 1 pixel_android_display_restored "$serial"; then
        restore_ok=true
      fi
    fi
    printf '[kgsl-cold] restore_ok=%s\n' "$restore_ok"

    capture_holder_scan "$serial" "$after_scan_path" "$after_scan_stderr" || true
  } >"$case_log" 2>&1

  write_case_json \
    "$case_name" \
    "$serial" \
    "$origin" \
    "$readiness" \
    "$extra_wait_secs" \
    "$case_scene" \
    "$case_profile" \
    "$case_dir" \
    "$case_log" \
    "$case_exit_status" \
    "$reboot_attempted" \
    "$readiness_ok" \
    "$restore_ok" \
    "$milestone_log_path" \
    "$props_snapshot_path" \
    "$before_scan_path" \
    "$before_scan_stderr" \
    "$after_scan_path" \
    "$after_scan_stderr" \
    "$case_run_dir" \
    "$status_path" \
    "$case_json" \
    "$( [[ "$dry_run" == "1" ]] && printf true || printf false )" >/dev/null

  if [[ "$case_exit_status" -ne 0 && "$matrix_status" -eq 0 ]]; then
    matrix_status="$case_exit_status"
  elif [[ ( "$readiness_ok" != "true" || "$restore_ok" != "true" ) && "$matrix_status" -eq 0 ]]; then
    matrix_status=71
  fi
}

if [[ -z "$manifest_path" ]]; then
  if [[ -z "$default_serial" ]]; then
    if [[ "$dry_run" == "1" ]]; then
      echo "pixel_kgsl_cold_matrix: --serial is required for --dry-run" >&2
      exit 2
    fi
    default_serial="$(pixel_resolve_serial)"
  fi
  matrix_serial="$default_serial"
else
  matrix_serial="$(resolve_manifest_serial "$manifest_path" "$default_serial")"
fi

if [[ "$dry_run" != "1" ]]; then
  pixel_require_host_lock "$matrix_serial" "$0" "${original_args[@]}"
fi

if [[ -z "$matrix_dir" ]]; then
  matrix_dir="$(pixel_prepare_named_run_dir "$matrix_root")"
else
  mkdir -p "$matrix_dir"
fi

manifest_copy_path="$matrix_dir/cases.tsv"
summary_path="$matrix_dir/matrix-summary.json"
table_path="$matrix_dir/matrix.tsv"

if [[ -n "$manifest_path" ]]; then
  cp "$manifest_path" "$manifest_copy_path"
else
  generate_default_manifest "$manifest_copy_path" "$default_serial"
fi

resolved_manifest_serial="$(resolve_manifest_serial "$manifest_copy_path" "$default_serial")"
if [[ "$resolved_manifest_serial" != "$matrix_serial" ]]; then
  echo "pixel_kgsl_cold_matrix: manifest serial drift detected after staging" >&2
  exit 2
fi

while IFS=$'\t' read -r case_name serial origin readiness extra_wait_secs case_scene case_profile; do
  [[ -n "${case_name:-}" ]] || continue
  [[ "${case_name:0:1}" == "#" ]] && continue
  serial="${serial:-$default_serial}"
  extra_wait_secs="${extra_wait_secs:-0}"
  case_scene="${case_scene:-$scene}"
  case_profile="${case_profile:-$profile}"
  run_case \
    "$case_name" \
    "$serial" \
    "$origin" \
    "$readiness" \
    "$extra_wait_secs" \
    "$case_scene" \
    "$case_profile"
done <"$manifest_copy_path"

python3 - "$matrix_dir" "$summary_path" "$table_path" <<'PY'
import json
import sys
from pathlib import Path

matrix_dir = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
table_path = Path(sys.argv[3])
cases = []

for case_json in sorted(matrix_dir.glob("*/case.json")):
    cases.append(json.loads(case_json.read_text(encoding="utf-8")))

payload = {
    "kind": "kgsl_cold_matrix",
    "matrix_dir": str(matrix_dir),
    "case_count": len(cases),
    "success_count": sum(1 for case in cases if case.get("success")),
    "cases": cases,
}
summary_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

lines = [
    "case\tserial\torigin\treadiness\textra_wait_secs\tscene\tprofile\texit_status\tsuccess\tkgsl_device_opened\tbefore_holders\tafter_holders"
]
for case in cases:
    lines.append(
        "\t".join(
            [
                case["case"],
                case["serial"],
                case["origin"],
                case["readiness"],
                str(case["extra_wait_secs"]),
                case["scene"],
                case["profile"],
                str(case["exit_status"]),
                "true" if case.get("success") else "false",
                str(case.get("kgsl_device_opened")),
                str(case["before_holder_scan"].get("holder_count")),
                str(case["after_holder_scan"].get("holder_count")),
            ]
        )
    )
table_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(json.dumps(payload, indent=2, sort_keys=True))
PY

exit "$matrix_status"
