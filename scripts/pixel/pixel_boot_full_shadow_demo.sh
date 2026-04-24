#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="${PIXEL_SERIAL:-}"
run_token="${RUN_TOKEN:-full-shadow-demo-$(date -u +%Y%m%dT%H%M%SZ)}"
run_root="${OUTPUT_ROOT:-build/pixel/runs/boot-full-shadow-demo}"
run_dir=""
hold_secs="${HOLD_SECS:-240}"
watchdog_secs="${WATCHDOG_SECS:-60}"
start_app="${START_APP:-counter}"
if [[ -n "${EXTRA_APPS+x}" ]]; then
  extra_apps="$EXTRA_APPS"
  extra_apps_explicit=1
else
  extra_apps=""
  extra_apps_explicit=0
fi
manual_touch="${MANUAL_TOUCH:-0}"
dry_run=0
reuse_image=0

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_full_shadow_demo.sh [--serial SERIAL]
                                                    [--run-token TOKEN]
                                                    [--output-root DIR]
                                                    [--hold-secs N]
                                                    [--watchdog-secs N]
                                                    [--start-app APP_ID]
                                                    [--extra-apps CSV]
                                                    [--manual-touch]
                                                    [--reuse-image]
                                                    [--dry-run]

Build and run the current rust-booted Shadow shell demo:
  - GPU shell compositor
  - logical payload partition bundle
  - TypeScript counter and timeline
  - Rust rust-demo
  - sunfish touch bootstrap
  - held observation window after watchdog proof
EOF
}

first_existing_dir() {
  local candidate
  for candidate in "$@"; do
    [[ -n "$candidate" ]] || continue
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

default_boot_shell_demo_extra_apps() {
  local app start_app
  start_app="${1:?default_boot_shell_demo_extra_apps requires a start app}"
  local -a apps=(counter timeline rust-demo)
  local -a extras=()

  for app in "${apps[@]}"; do
    [[ "$app" != "$start_app" ]] || continue
    extras+=("$app")
  done

  local IFS=,
  printf '%s\n' "${extras[*]}"
}

bool_true() {
  case "$1" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)
      serial="${2:?missing value for --serial}"
      shift 2
      ;;
    --run-token)
      run_token="${2:?missing value for --run-token}"
      shift 2
      ;;
    --output-root)
      run_root="${2:?missing value for --output-root}"
      shift 2
      ;;
    --hold-secs)
      hold_secs="${2:?missing value for --hold-secs}"
      shift 2
      ;;
    --watchdog-secs)
      watchdog_secs="${2:?missing value for --watchdog-secs}"
      shift 2
      ;;
    --start-app)
      start_app="${2:?missing value for --start-app}"
      shift 2
      ;;
    --extra-apps)
      extra_apps="${2:?missing value for --extra-apps}"
      extra_apps_explicit=1
      shift 2
      ;;
    --manual-touch)
      manual_touch=1
      shift
      ;;
    --reuse-image)
      reuse_image=1
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
      echo "pixel_boot_full_shadow_demo: unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ ! "$hold_secs" =~ ^[0-9]+$ || ! "$watchdog_secs" =~ ^[0-9]+$ ]]; then
  echo "pixel_boot_full_shadow_demo: hold/watchdog seconds must be integers" >&2
  exit 64
fi

if [[ "$extra_apps_explicit" != "1" ]]; then
  extra_apps="$(default_boot_shell_demo_extra_apps "$start_app")"
fi

if [[ -z "$serial" && "$dry_run" != "1" ]]; then
  serial="$(pixel_resolve_serial)"
fi

run_dir="$run_root/$run_token"
image="$run_dir/full-shadow-demo.img"
payload="$image.orange-gpu.tar.xz"
stage_dir="$run_dir/payload-stage-logical"
device_output="$run_dir/device-run"
needs_build=0
if [[ "$reuse_image" != "1" || ! -f "$image" || ! -f "$payload" ]]; then
  needs_build=1
fi
firmware_dir="$(
  first_existing_dir \
    "${PIXEL_BOOT_FULL_SHADOW_FIRMWARE_DIR:-}" \
    "build/pixel/firmware/sunfish-gpu-touch" || true
)"
input_module_dir="$(
  first_existing_dir \
    "${PIXEL_BOOT_FULL_SHADOW_INPUT_MODULE_DIR:-}" \
    "build/pixel/modules/sunfish-touch" || true
)"

if [[ "$dry_run" == "1" ]]; then
  firmware_dir="${firmware_dir:-\$PIXEL_BOOT_FULL_SHADOW_FIRMWARE_DIR}"
  input_module_dir="${input_module_dir:-\$PIXEL_BOOT_FULL_SHADOW_INPUT_MODULE_DIR}"
elif [[ "$needs_build" == "1" && ( -z "$firmware_dir" || -z "$input_module_dir" ) ]]; then
  cat >&2 <<EOF
pixel_boot_full_shadow_demo: missing sunfish touch firmware/modules.

Set:
  PIXEL_BOOT_FULL_SHADOW_FIRMWARE_DIR=/path/to/sunfish-gpu-touch
  PIXEL_BOOT_FULL_SHADOW_INPUT_MODULE_DIR=/path/to/sunfish-touch
or stage them in:
  build/pixel/firmware/sunfish-gpu-touch
  build/pixel/modules/sunfish-touch
EOF
  exit 66
fi

manual_touch_arg=false
if bool_true "$manual_touch"; then
  manual_touch_arg=true
fi

mkdir -p "$run_dir"

build_cmd=(
  "$SCRIPT_DIR/pixel/pixel_boot_build_orange_gpu.sh"
  --output "$image"
  --hello-init-mode rust-bridge
  --rust-shim-mode exec
  --orange-gpu-mode shell-session-held
  --orange-gpu-metadata-stage-breadcrumb true
  --orange-gpu-metadata-prune-token-root true
  --orange-gpu-firmware-helper true
  --orange-gpu-timeout-action hold
  --orange-gpu-watchdog-timeout-secs "$watchdog_secs"
  --orange-gpu-bundle-archive-source shadow-logical-partition
  --payload-probe-source shadow-logical-partition
  --payload-probe-root /shadow-payload
  --payload-probe-manifest-path /shadow-payload/manifest.env
  --hold-secs "$hold_secs"
  --dev-mount tmpfs
  --mount-dev true
  --mount-proc true
  --mount-sys true
  --dri-bootstrap sunfish-card0-renderD128-kgsl3d0
  --input-bootstrap sunfish-touch-event2
  --input-module-dir "$input_module_dir"
  --firmware-bootstrap ramdisk-lib-firmware
  --firmware-dir "$firmware_dir"
  --app-direct-present-manual-touch "$manual_touch_arg"
  --shell-session-extra-app-ids "$extra_apps"
  --run-token "$run_token"
)

stage_cmd=(
  "$SCRIPT_DIR/pixel/pixel_boot_stage_metadata_payload.sh"
  --run-token "$run_token"
  --source shadow-logical-partition
  --skip-shadow-logical-setup
  --extra-payload "$payload:orange-gpu.tar.xz"
  --output-dir "$stage_dir"
  --version "full-shadow-demo-v1"
)

boot_cmd=(
  "$SCRIPT_DIR/pixel/pixel_boot_oneshot.sh"
  --image "$image"
  --output "$device_output"
  --wait-ready 240
  --adb-timeout 280
  --boot-timeout 320
  --return-timeout "$((watchdog_secs + hold_secs + 120))"
  --recover-traces-after
)

if [[ "$dry_run" == "1" ]]; then
  printf 'pixel_boot_full_shadow_demo: dry-run\n'
  printf 'run_token=%s\nrun_dir=%s\nimage=%s\npayload=%s\n' "$run_token" "$run_dir" "$image" "$payload"
  printf 'firmware_dir=%s\ninput_module_dir=%s\n' "$firmware_dir" "$input_module_dir"
  printf 'build_command=%q' env
  printf ' %q' \
    "PIXEL_GUEST_BUILD_SYSTEM=${PIXEL_GUEST_BUILD_SYSTEM:-aarch64-linux}" \
    "PIXEL_ORANGE_GPU_SHELL_SESSION_APP_PROFILE=boot-shell-demo" \
    "PIXEL_ORANGE_GPU_SHELL_START_APP_ID=$start_app" \
    "PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_APP_ID=$start_app"
  printf ' %q' "${build_cmd[@]}"
  printf '\n'
  printf 'stage_command=%q' env
  printf ' %q' "PIXEL_SERIAL=${serial:-SERIAL}"
  printf ' %q' "${stage_cmd[@]}"
  printf '\n'
  printf 'boot_command=%q' env
  printf ' %q' "PIXEL_SERIAL=${serial:-SERIAL}"
  printf ' %q' "${boot_cmd[@]}"
  printf '\n'
  exit 0
fi

echo "serial: $serial"
echo "run_token: $run_token"
echo "run_dir: $run_dir"
echo "start_app: $start_app"
echo "extra_apps: $extra_apps"
echo "manual_touch: $manual_touch_arg"
echo

scripts/shadowctl lease acquire "$serial" \
  --owner "${USER:-codex}" \
  --lane boot-full-shadow-demo \
  --ttl 7200

if [[ "$needs_build" == "1" ]]; then
  echo "building full Shadow demo image..."
  env \
    PIXEL_GUEST_BUILD_SYSTEM="${PIXEL_GUEST_BUILD_SYSTEM:-aarch64-linux}" \
    PIXEL_ORANGE_GPU_SHELL_SESSION_APP_PROFILE=boot-shell-demo \
    PIXEL_ORANGE_GPU_SHELL_START_APP_ID="$start_app" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_APP_ID="$start_app" \
    "${build_cmd[@]}"
else
  echo "reusing image: $image"
fi

echo
echo "staging logical payload..."
rm -rf "$stage_dir" "$device_output"
env PIXEL_SERIAL="$serial" "${stage_cmd[@]}"

echo
echo "booting full Shadow demo..."
echo "Counter should be visible first; use home/pill to return home, then launch Timeline and Rust Demo."
boot_status=0
env PIXEL_SERIAL="$serial" "${boot_cmd[@]}" || boot_status=$?

status="$device_output/recover-traces/status.json"
if [[ ! -f "$status" ]]; then
  echo
  echo "missing recovered status: $status" >&2
  echo "Check device state with: adb devices && fastboot devices" >&2
  exit 1
fi

echo
echo "proof summary:"
jq '{
  proof_ok,
  expected_orange_gpu_mode,
  expected_app_direct_present_app_id,
  expected_shell_session_start_app_id,
  metadata_probe_summary_touch_counter_injection,
  probe_summary_proves_shell_session_held,
  probe_summary_proves_shell_session_held_touch_counter,
  metadata_probe_summary_touch_counter_counter_incremented,
  metadata_probe_summary_touch_counter_touch_latency_present,
  metadata_compositor_frame_proves_app_direct_present,
  metadata_probe_stage_value
}' "$status"

echo
echo "frame:"
echo "  $device_output/recover-traces/channels/metadata-compositor-frame.ppm"
echo
echo "release lease when finished:"
echo "  scripts/shadowctl lease release \"$serial\" --force"
if [[ "$boot_status" != "0" ]]; then
  echo
  echo "boot/recovery command exited with status $boot_status" >&2
  exit "$boot_status"
fi
