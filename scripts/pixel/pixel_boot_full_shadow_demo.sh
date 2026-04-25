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
wifi_enabled="${WIFI:-0}"
wifi_credentials_file="${WIFI_CREDENTIALS_FILE:-}"
wifi_assets_dir="${PIXEL_BOOT_FULL_SHADOW_WIFI_ASSETS_DIR:-${PIXEL_WIFI_BOOT_ASSETS_DIR:-}}"
wifi_linker_capsule_dir="${PIXEL_BOOT_FULL_SHADOW_WIFI_LINKER_CAPSULE_DIR:-${PIXEL_WIFI_LINKER_CAPSULE_DIR:-${PIXEL_CAMERA_LINKER_CAPSULE_DIR:-}}}"
wifi_dhcp_client_binary="${PIXEL_BOOT_FULL_SHADOW_WIFI_DHCP_CLIENT_BIN:-${PIXEL_BOOT_WIFI_DHCP_CLIENT_BIN:-}}"
wifi_helper_profile="${PIXEL_BOOT_FULL_SHADOW_WIFI_HELPER_PROFILE:-vnd-sm-core-binder-node}"
wifi_credentials_device_path=""
wifi_credentials_tmp_device_path=""
wifi_credentials_remote_tmp=""
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
                                                    [--wifi]
                                                    [--wifi-credentials FILE]
                                                    [--wifi-assets DIR]
                                                    [--wifi-linker-capsule DIR]
                                                    [--wifi-dhcp-client BIN]
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

validate_run_token() {
  if [[ ! "$run_token" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]]; then
    echo "pixel_boot_full_shadow_demo: run token must be 1-63 safe characters and start with an alphanumeric character: $run_token" >&2
    exit 64
  fi
}

latest_existing_dir() {
  local root pattern
  root="${1:?latest_existing_dir requires a root}"
  pattern="${2:?latest_existing_dir requires a pattern}"
  [[ -d "$root" ]] || return 1
  find "$root" -path "$pattern" -type d -print 2>/dev/null | sort | tail -n 1
}

device_shell_quote() {
  local value
  value="${1:?device_shell_quote requires a value}"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

find_wifi_dhcp_client() {
  if [[ -n "$wifi_dhcp_client_binary" ]]; then
    printf '%s\n' "$wifi_dhcp_client_binary"
    return 0
  fi
  find /nix/store -maxdepth 3 -type f \
    -path '*busybox-static-aarch64-unknown-linux-musl-*/bin/busybox' \
    -perm -111 -print 2>/dev/null | sort | sed -n '1p'
}

validate_wifi_dhcp_client() {
  local binary_path file_output
  binary_path="${1:?validate_wifi_dhcp_client requires a binary path}"
  if [[ ! -x "$binary_path" ]]; then
    return 1
  fi
  file_output="$(file "$binary_path" 2>/dev/null || true)"
  [[ "$file_output" == *ELF* && "$file_output" == *"ARM aarch64"* && "$file_output" != *"dynamically linked"* ]]
}

stage_wifi_credentials() {
  local command encoded_credentials

  encoded_credentials="$(base64 <"$wifi_credentials_file" | tr -d '\n')"
  command=$(
    cat <<EOF
set -eu
trap 'rm -f $(device_shell_quote "$wifi_credentials_tmp_device_path")' EXIT
umask 077
mkdir -p /metadata/shadow-wifi-credentials/by-token
printf %s $(device_shell_quote "$encoded_credentials") | /system/bin/base64 -d > $(device_shell_quote "$wifi_credentials_tmp_device_path")
chmod 0600 $(device_shell_quote "$wifi_credentials_tmp_device_path")
chown 0:0 $(device_shell_quote "$wifi_credentials_tmp_device_path") 2>/dev/null || true
mv $(device_shell_quote "$wifi_credentials_tmp_device_path") $(device_shell_quote "$wifi_credentials_device_path")
trap - EXIT
EOF
  )
  pixel_root_shell_timeout 60 "$serial" "$command" >/dev/null
}

cleanup_wifi_credentials_best_effort() {
  local command
  if [[ -z "$wifi_credentials_device_path" && -z "$wifi_credentials_tmp_device_path" && -z "$wifi_credentials_remote_tmp" ]]; then
    return 0
  fi
  if [[ -z "$serial" || "$dry_run" == "1" ]]; then
    return 0
  fi
  command=$(
    cat <<EOF
rm -f $(device_shell_quote "$wifi_credentials_device_path") $(device_shell_quote "$wifi_credentials_tmp_device_path") $(device_shell_quote "$wifi_credentials_remote_tmp")
EOF
  )
  pixel_root_shell_timeout 10 "$serial" "$command" >/dev/null 2>&1 || true
}

trap cleanup_wifi_credentials_best_effort EXIT

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
    --wifi)
      wifi_enabled=1
      shift
      ;;
    --wifi-credentials)
      wifi_credentials_file="${2:?missing value for --wifi-credentials}"
      shift 2
      ;;
    --wifi-assets)
      wifi_assets_dir="${2:?missing value for --wifi-assets}"
      shift 2
      ;;
    --wifi-linker-capsule)
      wifi_linker_capsule_dir="${2:?missing value for --wifi-linker-capsule}"
      shift 2
      ;;
    --wifi-dhcp-client)
      wifi_dhcp_client_binary="${2:?missing value for --wifi-dhcp-client}"
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

validate_run_token

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
if bool_true "$wifi_enabled"; then
  wifi_assets_dir="$(
    first_existing_dir \
      "$wifi_assets_dir" \
      "$(latest_existing_dir "build/pixel/wifi-boot" "*/wifi-assets" || true)" || true
  )"
  wifi_linker_capsule_dir="$(
    first_existing_dir \
      "$wifi_linker_capsule_dir" \
      "$(latest_existing_dir "build/pixel/wifi-boot" "*/wifi-linker-capsule" || true)" || true
  )"
  wifi_dhcp_client_binary="$(find_wifi_dhcp_client)"
  wifi_credentials_device_path="/metadata/shadow-wifi-credentials/by-token/$run_token.env"
  wifi_credentials_tmp_device_path="$wifi_credentials_device_path.tmp"
  wifi_credentials_remote_tmp="/data/local/tmp/shadow-wifi-credentials-$run_token.env"
fi

if [[ "$dry_run" == "1" ]]; then
  firmware_dir="${firmware_dir:-\$PIXEL_BOOT_FULL_SHADOW_FIRMWARE_DIR}"
  input_module_dir="${input_module_dir:-\$PIXEL_BOOT_FULL_SHADOW_INPUT_MODULE_DIR}"
  if bool_true "$wifi_enabled"; then
    wifi_assets_dir="${wifi_assets_dir:-\$PIXEL_BOOT_FULL_SHADOW_WIFI_ASSETS_DIR}"
    wifi_linker_capsule_dir="${wifi_linker_capsule_dir:-\$PIXEL_BOOT_FULL_SHADOW_WIFI_LINKER_CAPSULE_DIR}"
    wifi_dhcp_client_binary="${wifi_dhcp_client_binary:-\$PIXEL_BOOT_FULL_SHADOW_WIFI_DHCP_CLIENT_BIN}"
  fi
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
if bool_true "$wifi_enabled" && [[ "$dry_run" != "1" ]]; then
  if [[ -z "$wifi_credentials_file" || ! -r "$wifi_credentials_file" ]]; then
    echo "pixel_boot_full_shadow_demo: --wifi requires --wifi-credentials FILE" >&2
    exit 66
  fi
  if [[ "$needs_build" == "1" && ( -z "$wifi_assets_dir" || ! -d "$wifi_assets_dir/modules" || ! -d "$wifi_assets_dir/firmware" ) ]]; then
    echo "pixel_boot_full_shadow_demo: --wifi requires Wi-Fi assets with modules/ and firmware/" >&2
    exit 66
  fi
  if [[ "$needs_build" == "1" && ( -z "$wifi_linker_capsule_dir" || ! -d "$wifi_linker_capsule_dir" ) ]]; then
    echo "pixel_boot_full_shadow_demo: --wifi requires a Wi-Fi linker capsule directory" >&2
    exit 66
  fi
  if ! validate_wifi_dhcp_client "$wifi_dhcp_client_binary"; then
    echo "pixel_boot_full_shadow_demo: --wifi requires an executable static aarch64 busybox DHCP client" >&2
    exit 66
  fi
fi

manual_touch_arg=false
if bool_true "$manual_touch"; then
  manual_touch_arg=true
fi

mkdir -p "$run_dir"
effective_firmware_dir="$firmware_dir"
combined_firmware_dir="$run_dir/combined-firmware"
if bool_true "$wifi_enabled"; then
  effective_firmware_dir="$combined_firmware_dir"
  if [[ "$dry_run" != "1" && "$needs_build" == "1" ]]; then
    rm -rf "$combined_firmware_dir"
    mkdir -p "$combined_firmware_dir"
    cp -R "$firmware_dir"/. "$combined_firmware_dir"/
    cp -R "$wifi_assets_dir/firmware"/. "$combined_firmware_dir"/
  fi
fi

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
  --firmware-dir "$effective_firmware_dir"
  --app-direct-present-manual-touch "$manual_touch_arg"
  --shell-session-extra-app-ids "$extra_apps"
  --run-token "$run_token"
)
if bool_true "$wifi_enabled"; then
  build_cmd+=(
    --wifi-bootstrap sunfish-wlan0
    --wifi-helper-profile "$wifi_helper_profile"
    --wifi-runtime-network true
    --wifi-credentials-path "$wifi_credentials_device_path"
    --wifi-dhcp-client "$wifi_dhcp_client_binary"
    --wifi-module-dir "$wifi_assets_dir/modules"
    --wifi-linker-capsule "$wifi_linker_capsule_dir"
  )
fi

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
  printf 'firmware_dir=%s\ninput_module_dir=%s\n' "$effective_firmware_dir" "$input_module_dir"
  if bool_true "$wifi_enabled"; then
    printf 'wifi_enabled=true\nwifi_assets_dir=%s\nwifi_linker_capsule_dir=%s\nwifi_dhcp_client=%s\nwifi_credentials_device_path=%s\n' \
      "$wifi_assets_dir" \
      "$wifi_linker_capsule_dir" \
      "$wifi_dhcp_client_binary" \
      "$wifi_credentials_device_path"
  fi
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
if bool_true "$wifi_enabled"; then
  echo "wifi: enabled"
  echo "wifi_assets: $wifi_assets_dir"
  echo "wifi_linker_capsule: $wifi_linker_capsule_dir"
fi
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

if bool_true "$wifi_enabled"; then
  echo
  echo "staging Wi-Fi credentials..."
  stage_wifi_credentials
fi

echo
echo "booting full Shadow demo..."
echo "$start_app should be visible first; use home/pill to switch apps during the held window."
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
