#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

input_image="${PIXEL_BOOT_RUST_BRIDGE_INPUT_IMAGE:-}"
output_dir="${PIXEL_BOOT_RUST_BRIDGE_RUN_DIR:-}"
image_output_path="${PIXEL_BOOT_RUST_BRIDGE_IMAGE_OUTPUT:-}"
shim_mode="${PIXEL_HELLO_INIT_RUST_SHIM_MODE:-exec}"
child_profile="${PIXEL_HELLO_INIT_RUST_CHILD_PROFILE:-hello}"
child_binary="${PIXEL_HELLO_INIT_RUST_CHILD_BIN:-}"
key_path="${AVB_TEST_KEY_PATH:-}"
wait_ready_secs="${PIXEL_BOOT_RUST_BRIDGE_WAIT_READY_SECS:-120}"
adb_timeout_secs="${PIXEL_BOOT_RUST_BRIDGE_ADB_TIMEOUT_SECS:-180}"
boot_timeout_secs="${PIXEL_BOOT_RUST_BRIDGE_BOOT_TIMEOUT_SECS:-240}"
success_signal="${PIXEL_BOOT_RUST_BRIDGE_SUCCESS_SIGNAL:-adb}"
return_timeout_secs="${PIXEL_BOOT_RUST_BRIDGE_RETURN_TIMEOUT_SECS:-45}"
skip_collect=0
recover_traces_after=0
wait_boot_completed=1
proof_prop="${PIXEL_BOOT_RUST_BRIDGE_PROOF_PROP:-}"
dry_run=0
original_args=("$@")

build_script="${PIXEL_BOOT_RUST_BRIDGE_BUILD_SCRIPT:-$SCRIPT_DIR/pixel/pixel_boot_build_rust_bridge.sh}"
oneshot_script="${PIXEL_BOOT_RUST_BRIDGE_ONESHOT_SCRIPT:-$SCRIPT_DIR/pixel/pixel_boot_oneshot.sh}"
run_root="$(pixel_boot_dir)/rust-bridge-run"
device_run_dir=""
build_log=""
run_log=""
status_path=""
serial=""
build_status=0
run_status=0
run_skipped=0

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_rust_bridge_run.sh --input PATH
                                                   [--output-dir DIR]
                                                   [--image-output PATH]
                                                   [--shim-mode fork|exec]
                                                   [--child-profile hello|std-probe|std-minimal-probe|std-nomain-probe|nostd-probe]
                                                   [--child PATH]
                                                   [--key PATH]
                                                   [--wait-ready SECONDS]
                                                   [--adb-timeout SECONDS]
                                                   [--boot-timeout SECONDS]
                                                   [--success-signal adb|fastboot-return]
                                                   [--return-timeout SECONDS]
                                                   [--skip-collect]
                                                   [--recover-traces-after]
                                                   [--no-wait-boot-completed]
                                                   [--proof-prop KEY=VALUE]
                                                   [--dry-run]

Build a Rust-bridge boot image from a proven owned-userspace image, then run the
standard one-shot delegate against that rebuilt image. This private helper exists
to keep the Rust PID1 migration loop as one structured boot-lab run bundle.
EOF
}

resolve_serial_for_mode() {
  if [[ "$dry_run" == "1" && -n "${PIXEL_SERIAL:-}" ]]; then
    printf '%s\n' "$PIXEL_SERIAL"
    return 0
  fi

  pixel_resolve_serial
}

bool_word() {
  if [[ "$1" == "1" || "$1" == "true" ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

prepare_output_dir() {
  if [[ -z "$output_dir" ]]; then
    output_dir="$(pixel_prepare_named_run_dir "$run_root")"
  else
    mkdir -p "$output_dir"
  fi

  if [[ -z "$image_output_path" ]]; then
    image_output_path="$output_dir/rust-bridge.img"
  fi

  device_run_dir="$output_dir/device-run"
  build_log="$output_dir/build.log"
  run_log="$output_dir/run.log"
  status_path="$output_dir/status.json"
}

write_summary_json() {
  pixel_write_status_json \
    "$status_path" \
    kind=boot_rust_bridge_run \
    serial="$serial" \
    input_image="$input_image" \
    image_output="$image_output_path" \
    output_dir="$output_dir" \
    device_run_dir="$device_run_dir" \
    build_log="$build_log" \
    run_log="$run_log" \
    build_script="$build_script" \
    oneshot_script="$oneshot_script" \
    shim_mode="$shim_mode" \
    child_profile="$child_profile" \
    child_binary="$child_binary" \
    success_signal="$success_signal" \
    wait_ready_secs="$wait_ready_secs" \
    adb_timeout_secs="$adb_timeout_secs" \
    boot_timeout_secs="$boot_timeout_secs" \
    return_timeout_secs="$return_timeout_secs" \
    skip_collect="$(bool_word "$skip_collect")" \
    recover_traces_after="$(bool_word "$recover_traces_after")" \
    wait_boot_completed="$(bool_word "$wait_boot_completed")" \
    build_status="$build_status" \
    run_status="$run_status" \
    run_skipped="$(bool_word "$run_skipped")" \
    build_succeeded="$(bool_word "$([[ "$build_status" -eq 0 ]] && echo true || echo false)")" \
    run_succeeded="$(bool_word "$([[ "$run_status" -eq 0 ]] && echo true || echo false)")" \
    proof_prop="$proof_prop"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      input_image="${2:?missing value for --input}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:?missing value for --output-dir}"
      shift 2
      ;;
    --image-output)
      image_output_path="${2:?missing value for --image-output}"
      shift 2
      ;;
    --shim-mode)
      shim_mode="${2:?missing value for --shim-mode}"
      shift 2
      ;;
    --child-profile)
      child_profile="${2:?missing value for --child-profile}"
      shift 2
      ;;
    --child)
      child_binary="${2:?missing value for --child}"
      shift 2
      ;;
    --key)
      key_path="${2:?missing value for --key}"
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
    --success-signal)
      success_signal="${2:?missing value for --success-signal}"
      shift 2
      ;;
    --return-timeout)
      return_timeout_secs="${2:?missing value for --return-timeout}"
      shift 2
      ;;
    --skip-collect)
      skip_collect=1
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
    --proof-prop)
      proof_prop="${2:?missing value for --proof-prop}"
      shift 2
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
      echo "pixel_boot_rust_bridge_run: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -n "$input_image" ]] || {
  echo "pixel_boot_rust_bridge_run: --input is required" >&2
  exit 1
}

serial="$(resolve_serial_for_mode)"
pixel_prepare_dirs
pixel_require_host_lock "$serial" "$0" "${original_args[@]}"
prepare_output_dir

if [[ "$dry_run" != "1" && ! -f "$input_image" ]]; then
  echo "pixel_boot_rust_bridge_run: input image not found: $input_image" >&2
  exit 1
fi

build_args=(
  --input "$input_image"
  --output "$image_output_path"
  --shim-mode "$shim_mode"
  --child-profile "$child_profile"
)
if [[ -n "$child_binary" ]]; then
  build_args+=(--child "$child_binary")
fi
if [[ -n "$key_path" ]]; then
  build_args+=(--key "$key_path")
fi

oneshot_args=(
  --image "$image_output_path"
  --output "$device_run_dir"
  --wait-ready "$wait_ready_secs"
  --adb-timeout "$adb_timeout_secs"
  --boot-timeout "$boot_timeout_secs"
)
if [[ -n "$success_signal" ]]; then
  oneshot_args+=(--success-signal "$success_signal")
fi
if [[ -n "$return_timeout_secs" ]]; then
  oneshot_args+=(--return-timeout "$return_timeout_secs")
fi
if [[ "$skip_collect" == "1" ]]; then
  oneshot_args+=(--skip-collect)
fi
if [[ "$recover_traces_after" == "1" ]]; then
  oneshot_args+=(--recover-traces-after)
fi
if [[ "$wait_boot_completed" != "1" ]]; then
  oneshot_args+=(--no-wait-boot-completed)
fi
if [[ -n "$proof_prop" ]]; then
  oneshot_args+=(--proof-prop "$proof_prop")
fi

if [[ "$dry_run" == "1" ]]; then
  cat <<EOF
pixel_boot_rust_bridge_run: dry-run
serial=$serial
input_image=$input_image
image_output=$image_output_path
output_dir=$output_dir
device_run_dir=$device_run_dir
build_log=$build_log
run_log=$run_log
build_script=$build_script
oneshot_script=$oneshot_script
shim_mode=$shim_mode
child_profile=$child_profile
child_binary=$child_binary
success_signal=$success_signal
wait_ready_secs=$wait_ready_secs
adb_timeout_secs=$adb_timeout_secs
boot_timeout_secs=$boot_timeout_secs
return_timeout_secs=$return_timeout_secs
skip_collect=$(bool_word "$skip_collect")
recover_traces_after=$(bool_word "$recover_traces_after")
wait_boot_completed=$(bool_word "$wait_boot_completed")
proof_prop=$proof_prop
EOF
  exit 0
fi

set +e
PIXEL_SERIAL="$serial" "$build_script" "${build_args[@]}" >"$build_log" 2>&1
build_status="$?"
set -e

if [[ "$build_status" -eq 0 && ! -f "$image_output_path" ]]; then
  echo "pixel_boot_rust_bridge_run: build script succeeded but did not write $image_output_path" >&2
  build_status=1
fi

if [[ "$build_status" -eq 0 ]]; then
  set +e
  PIXEL_SERIAL="$serial" "$oneshot_script" "${oneshot_args[@]}" >"$run_log" 2>&1
  run_status="$?"
  set -e
else
  run_status=125
  run_skipped=1
  printf 'build failed; skipping device run\n' >"$run_log"
fi

write_summary_json

if [[ "$build_status" -ne 0 ]]; then
  cat "$build_log" >&2
  exit "$build_status"
fi

if [[ "$run_status" -ne 0 ]]; then
  cat "$run_log" >&2
  exit "$run_status"
fi
