#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

original_args=("$@")
preflight_root="$(pixel_runs_dir)/boot-preflight"
output_dir="${PIXEL_BOOT_PREFLIGHT_DIR:-}"
input_image="${PIXEL_BOOT_INPUT_IMAGE:-}"
key_path="${AVB_TEST_KEY_PATH:-}"
default_serial="${PIXEL_SERIAL:-}"
trigger="${PIXEL_BOOT_LOG_PROBE_TRIGGER:-post-fs-data}"
patch_target_override="${PIXEL_BOOT_LOG_PROBE_PATCH_TARGET:-}"
preflight_profile="${PIXEL_BOOT_PREFLIGHT_PROFILE:-phase1-shell}"
launch_proof_prop="${PIXEL_BOOT_PREFLIGHT_LAUNCH_PROOF_PROP:-debug.shadow.boot.preflight.launch=started}"
wait_ready_secs="${PIXEL_BOOT_PREFLIGHT_WAIT_READY_SECS:-120}"
adb_timeout_secs="${PIXEL_BOOT_PREFLIGHT_ADB_TIMEOUT_SECS:-180}"
boot_timeout_secs="${PIXEL_BOOT_PREFLIGHT_BOOT_TIMEOUT_SECS:-240}"
recover_traces_after="${PIXEL_BOOT_PREFLIGHT_RECOVER_TRACES_AFTER:-0}"
wait_boot_completed=1
dry_run=0
serial=""
build_script="${PIXEL_BOOT_PREFLIGHT_BUILD_SCRIPT:-$SCRIPT_DIR/pixel/pixel_boot_build_log_probe.sh}"
oneshot_script="${PIXEL_BOOT_PREFLIGHT_ONESHOT_SCRIPT:-$SCRIPT_DIR/pixel/pixel_boot_oneshot.sh}"
image_path=""
device_run_dir=""
build_log=""
run_log=""
summary_path=""
device_status_path=""
collect_status_path=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_preflight.sh [--output-dir DIR] [--serial SERIAL]
                                             [--input PATH] [--key PATH]
                                             [--trigger EXPR]
                                             [--patch-target ENTRY]
                                             [--preflight-profile phase1-shell]
                                             [--wait-ready SECONDS]
                                             [--adb-timeout SECONDS]
                                             [--boot-timeout SECONDS]
                                             [--recover-traces-after]
                                             [--no-wait-boot-completed]
                                             [--dry-run]

Build a stock-init boot-helper preflight image, one-shot boot it, and summarize
whether the helper proved the current boot plus whether preflight is ready.
EOF
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
    echo "pixel_boot_preflight: --serial or PIXEL_SERIAL is required for --dry-run" >&2
    exit 2
  fi

  pixel_resolve_serial
}

prepare_output_dir() {
  if [[ -z "$output_dir" ]]; then
    output_dir="$(pixel_prepare_named_run_dir "$preflight_root")"
  else
    if [[ -e "$output_dir" ]] && find "$output_dir" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
      echo "pixel_boot_preflight: output dir must be empty or absent: $output_dir" >&2
      exit 1
    fi
    mkdir -p "$output_dir"
  fi

  image_path="$output_dir/boot-preflight.img"
  device_run_dir="$output_dir/device-run"
  build_log="$output_dir/build.log"
  run_log="$output_dir/run.log"
  summary_path="$output_dir/summary.json"
  device_status_path="$device_run_dir/status.json"
  collect_status_path="$device_run_dir/collect/status.json"
}

write_summary_json() {
  local build_exit_status run_exit_status
  build_exit_status="${1:?write_summary_json requires a build exit status}"
  run_exit_status="${2:?write_summary_json requires a run exit status}"

  python3 - \
    "$summary_path" \
    "$serial" \
    "$preflight_profile" \
    "$trigger" \
    "$launch_proof_prop" \
    "$input_image" \
    "$image_path" \
    "$build_log" \
    "$build_exit_status" \
    "$run_log" \
    "$run_exit_status" \
    "$(bool_word "$dry_run")" \
    "$output_dir" \
    "$device_run_dir" \
    "$device_status_path" \
    "$collect_status_path" <<'PY'
import json
import sys
from pathlib import Path

(
    summary_path,
    serial,
    preflight_profile,
    trigger,
    launch_proof_prop,
    input_image,
    image_path,
    build_log,
    build_exit_status,
    run_log,
    run_exit_status,
    dry_run,
    output_dir,
    device_run_dir,
    device_status_path,
    collect_status_path,
) = sys.argv[1:17]
def load_json(path_str: str):
    path = Path(path_str)
    if not path.exists():
        return None
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


device_status = load_json(device_status_path)
collect_status = load_json(collect_status_path)
helper_proved_current_boot = False
preflight_status = ""
preflight_ready = False
preflight_blocked_reason = ""

if isinstance(collect_status, dict):
    helper_proved_current_boot = bool(collect_status.get("collection_succeeded"))
    preflight_status = str(collect_status.get("preflight_status") or "")
    preflight_ready = bool(collect_status.get("preflight_ready"))
    preflight_blocked_reason = str(collect_status.get("preflight_blocked_reason") or "")

payload = {
    "kind": "boot_preflight",
    "serial": serial,
    "preflight_profile": preflight_profile,
    "trigger": trigger,
    "launch_proof_prop": launch_proof_prop,
    "input_image": input_image,
    "image_path": image_path,
    "build_log": build_log,
    "build_exit_status": int(build_exit_status),
    "build_succeeded": int(build_exit_status) == 0,
    "run_log": run_log,
    "exit_status": int(run_exit_status),
    "run_succeeded": int(run_exit_status) == 0,
    "dry_run": dry_run == "true",
    "output_dir": output_dir,
    "device_run_dir": device_run_dir,
    "device_status_path": device_status_path,
    "collect_status_path": collect_status_path,
    "device_status": device_status,
    "collect_status": collect_status,
    "helper_proved_current_boot": helper_proved_current_boot,
    "preflight_status": preflight_status,
    "preflight_ready": preflight_ready,
    "preflight_blocked_reason": preflight_blocked_reason,
}
payload["ok"] = payload["dry_run"] or (
    payload["build_succeeded"] and payload["run_succeeded"] and payload["helper_proved_current_boot"]
)

Path(summary_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      output_dir="${2:?missing value for --output-dir}"
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
      trigger="${2:?missing value for --trigger}"
      shift 2
      ;;
    --patch-target)
      patch_target_override="${2:?missing value for --patch-target}"
      shift 2
      ;;
    --preflight-profile)
      preflight_profile="${2:?missing value for --preflight-profile}"
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
      echo "pixel_boot_preflight: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

serial="$(resolve_serial_for_mode)"
pixel_prepare_dirs
pixel_require_host_lock "$serial" "$0" "${original_args[@]}"
prepare_output_dir

build_args=(
  --stock-init
  --output "$image_path"
  --trigger "$trigger"
  --preflight-profile "$preflight_profile"
)
if [[ -n "$input_image" ]]; then
  build_args+=(--input "$input_image")
fi
if [[ -n "$key_path" ]]; then
  build_args+=(--key "$key_path")
fi
if [[ -n "$patch_target_override" ]]; then
  build_args+=(--patch-target "$patch_target_override")
fi

set +e
PIXEL_BOOT_PREFLIGHT_LAUNCH_PROOF_PROP="$launch_proof_prop" \
  PIXEL_SERIAL="$serial" "$build_script" "${build_args[@]}" >"$build_log" 2>&1
build_status="$?"
set -e

if [[ "$build_status" -eq 0 && ! -f "$image_path" ]]; then
  echo "pixel_boot_preflight: build script succeeded but did not write $image_path" >&2
  build_status=1
fi

run_status=0
if [[ "$build_status" -eq 0 ]]; then
  oneshot_args=(
    --image "$image_path"
    --output "$device_run_dir"
    --wait-ready "$wait_ready_secs"
    --adb-timeout "$adb_timeout_secs"
    --boot-timeout "$boot_timeout_secs"
    --proof-prop "$launch_proof_prop"
  )
  if [[ "$recover_traces_after" == "1" ]]; then
    oneshot_args+=(--recover-traces-after)
  fi
  if [[ "$wait_boot_completed" != "1" ]]; then
    oneshot_args+=(--no-wait-boot-completed)
  fi

  set +e
  PIXEL_BOOT_PREFLIGHT_LAUNCH_PROOF_PROP="$launch_proof_prop" \
    PIXEL_SERIAL="$serial" "$oneshot_script" "${oneshot_args[@]}" >"$run_log" 2>&1
  run_status="$?"
  set -e
else
  printf 'build failed; skipping device run\n' >"$run_log"
fi

write_summary_json "$build_status" "$run_status"

printf 'Boot preflight output: %s\n' "$output_dir"
printf 'Serial: %s\n' "$serial"
printf 'Image: %s\n' "$image_path"
printf 'Summary: %s\n' "$summary_path"
printf 'Launch proof prop: %s\n' "$launch_proof_prop"
if [[ -f "$collect_status_path" ]]; then
  python3 - "$collect_status_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

preflight_status = payload.get("preflight_status", "")
preflight_ready = payload.get("preflight_ready")
blocked_reason = payload.get("preflight_blocked_reason", "")

if preflight_status:
    print(f"Preflight status: {preflight_status}")
if preflight_ready is not None:
    print(f"Preflight ready: {str(bool(preflight_ready)).lower()}")
if blocked_reason:
    print(f"Preflight blocked reason: {blocked_reason}")
PY
fi

if [[ "$dry_run" == "1" ]]; then
  exit 0
fi
if [[ "$build_status" -ne 0 ]]; then
  exit "$build_status"
fi
exit "$run_status"
