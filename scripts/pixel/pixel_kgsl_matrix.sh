#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs

matrix_root="$(pixel_runs_dir)/kgsl-matrix"
matrix_dir="${PIXEL_KGSL_MATRIX_DIR-}"
manifest_path=""
scene="${PIXEL_KGSL_MATRIX_SCENE:-raw-kgsl-open-readonly-smoke}"
profile="${PIXEL_KGSL_MATRIX_PROFILE:-dri+kgsl}"
default_serial="${PIXEL_KGSL_MATRIX_DEFAULT_SERIAL:-${PIXEL_SERIAL:-}}"
dry_run=0
matrix_status=0

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_kgsl_matrix.sh [--output-dir DIR] [--manifest FILE]
                                          [--serial SERIAL] [--scene SCENE]
                                          [--profile PROFILE] [--dry-run]

Run a small rooted KGSL falsification matrix using the tmpfs-/dev control harness.

Manifest format:
  case_name<TAB>serial<TAB>service_mode<TAB>scene<TAB>profile

Supported service modes:
  android-running
  display-stopped-keep-allocator
  display-stopped
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      matrix_dir="${2:?pixel_kgsl_matrix: --output-dir requires a value}"
      shift 2
      ;;
    --output-dir=*)
      matrix_dir="${1#*=}"
      shift
      ;;
    --manifest)
      manifest_path="${2:?pixel_kgsl_matrix: --manifest requires a value}"
      shift 2
      ;;
    --manifest=*)
      manifest_path="${1#*=}"
      shift
      ;;
    --serial)
      default_serial="${2:?pixel_kgsl_matrix: --serial requires a value}"
      shift 2
      ;;
    --serial=*)
      default_serial="${1#*=}"
      shift
      ;;
    --scene)
      scene="${2:?pixel_kgsl_matrix: --scene requires a value}"
      shift 2
      ;;
    --scene=*)
      scene="${1#*=}"
      shift
      ;;
    --profile)
      profile="${2:?pixel_kgsl_matrix: --profile requires a value}"
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

if [[ -z "$matrix_dir" ]]; then
  matrix_dir="$(pixel_prepare_named_run_dir "$matrix_root")"
else
  mkdir -p "$matrix_dir"
fi

manifest_copy_path="$matrix_dir/cases.tsv"
summary_path="$matrix_dir/matrix-summary.json"
table_path="$matrix_dir/matrix.tsv"

generate_default_manifest() {
  local target_path serial
  target_path="${1:?generate_default_manifest requires a target path}"
  serial="${2:?generate_default_manifest requires a serial}"

  cat >"$target_path" <<EOF
# case_name	serial	service_mode	scene	profile
baseline	$serial	android-running	$scene	$profile
display-stopped-keep-allocator	$serial	display-stopped-keep-allocator	$scene	$profile
display-stopped	$serial	display-stopped	$scene	$profile
EOF
}

if [[ -n "$manifest_path" ]]; then
  cp "$manifest_path" "$manifest_copy_path"
else
  if [[ -z "$default_serial" ]]; then
    if [[ "$dry_run" == "1" ]]; then
      echo "pixel_kgsl_matrix: --serial is required for --dry-run" >&2
      exit 2
    fi
    default_serial="$(pixel_resolve_serial)"
  fi
  generate_default_manifest "$manifest_copy_path" "$default_serial"
fi

capture_holder_scan() {
  local serial output_path stderr_path
  serial="${1:?capture_holder_scan requires a serial}"
  output_path="${2:?capture_holder_scan requires an output path}"
  stderr_path="${3:?capture_holder_scan requires a stderr path}"

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
  pixel_root_shell "$serial" "$(pixel_kgsl_holder_scan_command)" >"$output_path" 2>"$stderr_path"
  local status=$?
  set -e
  return "$status"
}

apply_service_mode() {
  local serial service_mode
  serial="${1:?apply_service_mode requires a serial}"
  service_mode="${2:?apply_service_mode requires a service mode}"

  case "$service_mode" in
    android-running)
      return 0
      ;;
    display-stopped-keep-allocator)
      if [[ "$dry_run" == "1" ]]; then
        return 0
      fi
      pixel_root_shell "$serial" "$(pixel_takeover_stop_services_script 0)" >/dev/null
      ;;
    display-stopped)
      if [[ "$dry_run" == "1" ]]; then
        return 0
      fi
      pixel_root_shell "$serial" "$(pixel_takeover_stop_services_script 1)" >/dev/null
      ;;
    *)
      echo "pixel_kgsl_matrix: unsupported service mode: $service_mode" >&2
      return 2
      ;;
  esac
}

service_mode_ok() {
  local serial service_mode
  serial="${1:?service_mode_ok requires a serial}"
  service_mode="${2:?service_mode_ok requires a service mode}"

  case "$service_mode" in
    android-running)
      pixel_display_services_running "$serial"
      ;;
    display-stopped-keep-allocator)
      pixel_display_services_stopped_keep_allocator "$serial"
      ;;
    display-stopped)
      pixel_display_services_stopped "$serial"
      ;;
    *)
      return 1
      ;;
  esac
}

restore_android_display_services() {
  local serial
  serial="${1:?restore_android_display_services requires a serial}"

  if [[ "$dry_run" == "1" ]]; then
    return 0
  fi

  pixel_root_shell "$serial" "$(pixel_takeover_start_services_script)" >/dev/null || return 1
  pixel_wait_for_condition 20 1 pixel_display_services_running "$serial"
}

write_case_json() {
  local case_name serial service_mode scene profile case_dir case_log case_exit_status
  local setup_ok restore_ok before_scan_path before_scan_stderr after_scan_path after_scan_stderr
  local device_run_dir status_path output_path dry_run_word

  case_name="${1:?write_case_json requires case_name}"
  serial="${2:?write_case_json requires serial}"
  service_mode="${3:?write_case_json requires service_mode}"
  scene="${4:?write_case_json requires scene}"
  profile="${5:?write_case_json requires profile}"
  case_dir="${6:?write_case_json requires case_dir}"
  case_log="${7:?write_case_json requires case_log}"
  case_exit_status="${8:?write_case_json requires case_exit_status}"
  setup_ok="${9:?write_case_json requires setup_ok}"
  restore_ok="${10:?write_case_json requires restore_ok}"
  before_scan_path="${11:?write_case_json requires before_scan_path}"
  before_scan_stderr="${12:?write_case_json requires before_scan_stderr}"
  after_scan_path="${13:?write_case_json requires after_scan_path}"
  after_scan_stderr="${14:?write_case_json requires after_scan_stderr}"
  device_run_dir="${15:?write_case_json requires device_run_dir}"
  status_path="${16:?write_case_json requires status_path}"
  output_path="${17:?write_case_json requires output_path}"
  dry_run_word="${18:?write_case_json requires dry_run_word}"

  python3 - \
    "$case_name" \
    "$serial" \
    "$service_mode" \
    "$scene" \
    "$profile" \
    "$case_dir" \
    "$case_log" \
    "$case_exit_status" \
    "$setup_ok" \
    "$restore_ok" \
    "$before_scan_path" \
    "$before_scan_stderr" \
    "$after_scan_path" \
    "$after_scan_stderr" \
    "$device_run_dir" \
    "$status_path" \
    "$output_path" \
    "$dry_run_word" <<'PY'
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


(
    case_name,
    serial,
    service_mode,
    scene,
    profile,
    case_dir,
    case_log,
    case_exit_status,
    setup_ok,
    restore_ok,
    before_scan_path,
    before_scan_stderr,
    after_scan_path,
    after_scan_stderr,
    device_run_dir,
    status_path,
    output_path,
    dry_run_word,
) = sys.argv[1:19]

status_payload = None
status_file = Path(status_path)
if status_file.is_file():
    status_payload = json.loads(status_file.read_text(encoding="utf-8"))

payload = {
    "case": case_name,
    "serial": serial,
    "service_mode": service_mode,
    "scene": scene,
    "profile": profile,
    "case_dir": case_dir,
    "case_log": case_log,
    "device_run_dir": device_run_dir,
    "exit_status": int(case_exit_status),
    "setup_ok": setup_ok == "true",
    "restore_ok": restore_ok == "true",
    "dry_run": dry_run_word == "true",
    "status_path": status_path,
    "status": status_payload,
    "run_succeeded": bool((status_payload or {}).get("run_succeeded")),
    "kgsl_device_opened": (status_payload or {}).get("summary", {}).get("kgsl_device_opened"),
    "before_holder_scan": parse_holder_scan(before_scan_path),
    "after_holder_scan": parse_holder_scan(after_scan_path),
    "before_holder_scan_stderr_path": before_scan_stderr,
    "after_holder_scan_stderr_path": after_scan_stderr,
}
payload["success"] = (
    payload["exit_status"] == 0
    and payload["setup_ok"]
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
  local case_name serial service_mode scene profile
  local case_slug case_dir case_log case_json case_run_dir status_path
  local before_scan_path before_scan_stderr after_scan_path after_scan_stderr
  local setup_ok=false restore_ok=false case_exit_status=0

  case_name="${1:?run_case requires case_name}"
  serial="${2:?run_case requires serial}"
  service_mode="${3:?run_case requires service_mode}"
  scene="${4:?run_case requires scene}"
  profile="${5:?run_case requires profile}"

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

  rm -rf "$case_dir"
  mkdir -p "$case_dir"

  {
    printf '[kgsl-matrix] case=%s serial=%s service_mode=%s scene=%s profile=%s dry_run=%s\n' \
      "$case_name" "$serial" "$service_mode" "$scene" "$profile" "$dry_run"

    if [[ "$dry_run" != "1" ]]; then
      pixel_adb "$serial" get-state >/dev/null
    fi

    capture_holder_scan "$serial" "$before_scan_path" "$before_scan_stderr" || true

    if apply_service_mode "$serial" "$service_mode"; then
      if [[ "$dry_run" == "1" ]] || service_mode_ok "$serial" "$service_mode"; then
        setup_ok=true
      fi
    fi
    printf '[kgsl-matrix] setup_ok=%s\n' "$setup_ok"

    if [[ "$setup_ok" == "true" ]]; then
      if [[ "$dry_run" == "1" ]]; then
        case_exit_status=0
      else
        set +e
        PIXEL_SERIAL="$serial" \
          PIXEL_GPU_TMPFS_DEV_RUN_DIR="$case_run_dir" \
          "$SCRIPT_DIR/pixel/pixel_tmpfs_dev_gpu_smoke.sh" \
          --profile "$profile" \
          --scene "$scene"
        case_exit_status=$?
        set -e
      fi
    else
      case_exit_status=70
    fi
    printf '[kgsl-matrix] case_exit_status=%s\n' "$case_exit_status"

    if restore_android_display_services "$serial"; then
      restore_ok=true
    fi
    printf '[kgsl-matrix] restore_ok=%s\n' "$restore_ok"

    capture_holder_scan "$serial" "$after_scan_path" "$after_scan_stderr" || true
  } >"$case_log" 2>&1

  write_case_json \
    "$case_name" \
    "$serial" \
    "$service_mode" \
    "$scene" \
    "$profile" \
    "$case_dir" \
    "$case_log" \
    "$case_exit_status" \
    "$setup_ok" \
    "$restore_ok" \
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
  elif [[ ( "$setup_ok" != "true" || "$restore_ok" != "true" ) && "$matrix_status" -eq 0 ]]; then
    matrix_status=71
  fi
}

while IFS=$'\t' read -r case_name serial service_mode case_scene case_profile; do
  [[ -n "${case_name:-}" ]] || continue
  [[ "${case_name:0:1}" == "#" ]] && continue
  serial="${serial:-$default_serial}"
  case_scene="${case_scene:-$scene}"
  case_profile="${case_profile:-$profile}"
  if [[ -z "$serial" ]]; then
    echo "pixel_kgsl_matrix: missing serial for case $case_name" >&2
    exit 2
  fi
  run_case \
    "$case_name" \
    "$serial" \
    "$service_mode" \
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
    "kind": "kgsl_matrix",
    "matrix_dir": str(matrix_dir),
    "case_count": len(cases),
    "success_count": sum(1 for case in cases if case.get("success")),
    "cases": cases,
}
summary_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")

lines = ["case\tserial\tservice_mode\tscene\tprofile\texit_status\tsuccess\tkgsl_device_opened\tbefore_holders\tafter_holders"]
for case in cases:
    lines.append(
        "\t".join(
            [
                case["case"],
                case["serial"],
                case["service_mode"],
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
