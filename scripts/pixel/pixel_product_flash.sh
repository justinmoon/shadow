#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"
cd "$REPO_ROOT"

serial="${PIXEL_SERIAL:-}"
run_token="${RUN_TOKEN:-product-$(date -u +%Y%m%dT%H%M%SZ)}"
run_token_explicit=0
[[ -n "${RUN_TOKEN:-}" ]] && run_token_explicit=1
run_root="${OUTPUT_ROOT:-build/pixel/runs/product-flash}"
requested_slot="${PIXEL_PRODUCT_FLASH_SLOT:-inactive}"
wifi_enabled="${WIFI:-0}"
wifi_credentials_file="${WIFI_CREDENTIALS_FILE:-}"
wifi_assets_dir="${PIXEL_PRODUCT_WIFI_ASSETS_DIR:-${PIXEL_WIFI_BOOT_ASSETS_DIR:-}}"
wifi_linker_capsule_dir="${PIXEL_PRODUCT_WIFI_LINKER_CAPSULE_DIR:-${PIXEL_WIFI_LINKER_CAPSULE_DIR:-${PIXEL_CAMERA_LINKER_CAPSULE_DIR:-}}}"
wifi_dhcp_client_binary="${PIXEL_PRODUCT_WIFI_DHCP_CLIENT_BIN:-${PIXEL_BOOT_WIFI_DHCP_CLIENT_BIN:-}}"
wifi_helper_profile="${PIXEL_PRODUCT_WIFI_HELPER_PROFILE:-vnd-sm-core-binder-node}"
wifi_assets_dir_provided=0
wifi_linker_capsule_dir_provided=0
[[ -n "$wifi_assets_dir" ]] && wifi_assets_dir_provided=1
[[ -n "$wifi_linker_capsule_dir" ]] && wifi_linker_capsule_dir_provided=1
wifi_assets_auto_collect=0
wifi_linker_capsule_auto_collect=0
allow_active_slot=0
reuse_image=0
build_only=0
dry_run=0

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_product_flash.sh [--serial SERIAL]
                                            [--run-token TOKEN]
                                            [--output-root DIR]
                                            [--slot inactive|active|a|b]
                                            [--wifi]
                                            [--wifi-credentials FILE]
                                            [--wifi-assets DIR]
                                            [--wifi-linker-capsule DIR]
                                            [--wifi-dhcp-client BIN]
                                            [--allow-active-slot]
                                            [--reuse-image]
                                            [--build-only]
                                            [--dry-run]

Build and persistently flash a product-mode Shadow boot image:
  - product boot profile, no lab watchdog/proof reboot
  - shell home startup with all current demo apps staged
  - logical Shadow payload partition on the target slot
  - optional host-staged Wi-Fi credentials for the conference path
EOF
}

bool_true() {
  case "$1" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

validate_run_token() {
  if [[ ! "$run_token" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,62}$ ]]; then
    echo "pixel_product_flash: run token must be 8-63 safe characters and start with an alphanumeric character: $run_token" >&2
    exit 64
  fi
}

product_target_slot() {
  local requested current
  requested="${1:?product_target_slot requires requested slot}"
  current="${2:?product_target_slot requires current slot}"
  case "$requested" in
    inactive)
      pixel_other_slot_letter "$current"
      ;;
    active)
      printf '%s\n' "$current"
      ;;
    a|b)
      printf '%s\n' "$requested"
      ;;
    *)
      echo "pixel_product_flash: unsupported --slot $requested; expected inactive, active, a, or b" >&2
      return 1
      ;;
  esac
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
  local candidate file_output
  if [[ -n "$wifi_dhcp_client_binary" ]]; then
    printf '%s\n' "$wifi_dhcp_client_binary"
    return 0
  fi
  while IFS= read -r candidate; do
    file_output="$(file "$candidate" 2>/dev/null || true)"
    if [[ "$file_output" == *ELF* && "$file_output" == *"ARM aarch64"* && "$file_output" != *"dynamically linked"* ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(
    find /nix/store -maxdepth 4 -type f \
      -path '*/bin/busybox' \
      -perm -111 -print 2>/dev/null | sort
  )
}

validate_wifi_dhcp_client() {
  local binary_path file_output
  binary_path="${1:-}"
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)
      serial="${2:?missing value for --serial}"
      shift 2
      ;;
    --run-token)
      run_token="${2:?missing value for --run-token}"
      run_token_explicit=1
      shift 2
      ;;
    --output-root)
      run_root="${2:?missing value for --output-root}"
      shift 2
      ;;
    --slot)
      requested_slot="${2:?missing value for --slot}"
      shift 2
      ;;
    --wifi)
      wifi_enabled=1
      shift
      ;;
    --wifi-credentials)
      wifi_enabled=1
      wifi_credentials_file="${2:?missing value for --wifi-credentials}"
      shift 2
      ;;
    --wifi-assets)
      wifi_assets_dir="${2:?missing value for --wifi-assets}"
      wifi_assets_dir_provided=1
      shift 2
      ;;
    --wifi-linker-capsule)
      wifi_linker_capsule_dir="${2:?missing value for --wifi-linker-capsule}"
      wifi_linker_capsule_dir_provided=1
      shift 2
      ;;
    --wifi-dhcp-client)
      wifi_dhcp_client_binary="${2:?missing value for --wifi-dhcp-client}"
      shift 2
      ;;
    --allow-active-slot)
      allow_active_slot=1
      shift
      ;;
    --reuse-image)
      reuse_image=1
      shift
      ;;
    --build-only)
      build_only=1
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
      echo "pixel_product_flash: unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

validate_run_token
case "$requested_slot" in
  inactive|active|a|b) ;;
  *)
    echo "pixel_product_flash: unsupported --slot $requested_slot; expected inactive, active, a, or b" >&2
    exit 64
    ;;
esac

if bool_true "$wifi_enabled" && [[ "$reuse_image" == "1" && "$run_token_explicit" != "1" ]]; then
  echo "pixel_product_flash: --reuse-image with --wifi requires an explicit --run-token so credentials match the built image" >&2
  exit 64
fi

if [[ -z "$serial" && "$dry_run" != "1" && "$build_only" != "1" ]]; then
  serial="$(pixel_resolve_serial)"
fi

current_slot=""
target_slot="$requested_slot"
if [[ "$dry_run" != "1" && "$build_only" != "1" ]]; then
  current_slot="$(pixel_current_slot_letter_from_adb "$serial")"
  target_slot="$(product_target_slot "$requested_slot" "$current_slot")"
  if [[ "$target_slot" == "$current_slot" && "$allow_active_slot" != "1" ]]; then
    cat >&2 <<EOF
pixel_product_flash: target slot $target_slot is the current Android slot.

The product flash path stages the Shadow payload before flashing the boot image,
so it refuses active-slot writes unless --allow-active-slot is explicit.
Use --slot inactive for the conference path.
EOF
    exit 64
  fi
fi

run_dir="$run_root/$run_token"
image="$run_dir/product-shadow.img"
payload="$image.orange-gpu.tar.xz"
stage_dir="$run_dir/payload-stage-logical"
flash_metadata="$run_dir/product-flash.json"
wifi_assets_output_path="$run_dir/wifi-assets-output.txt"
wifi_linker_capsule_output_path="$run_dir/wifi-linker-capsule-output.txt"
all_apps="counter,camera,timeline,podcast,cashu,rust-demo,rust-timeline"
needs_build=0
if [[ "$reuse_image" != "1" || ! -f "$image" || ! -f "$payload" ]]; then
  needs_build=1
fi

firmware_dir="$(
  first_existing_dir \
    "${PIXEL_PRODUCT_FIRMWARE_DIR:-}" \
    "build/pixel/firmware/sunfish-gpu-touch" || true
)"
input_module_dir="$(
  first_existing_dir \
    "${PIXEL_PRODUCT_INPUT_MODULE_DIR:-}" \
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
  if [[ -z "$wifi_assets_dir" && "$wifi_assets_dir_provided" == "0" && "$dry_run" != "1" && "$build_only" != "1" ]]; then
    wifi_assets_dir="$run_dir/wifi-assets"
    wifi_assets_auto_collect=1
  fi
  if [[ -z "$wifi_linker_capsule_dir" && "$wifi_linker_capsule_dir_provided" == "0" && "$dry_run" != "1" && "$build_only" != "1" ]]; then
    wifi_linker_capsule_dir="$run_dir/wifi-linker-capsule"
    wifi_linker_capsule_auto_collect=1
  fi
  wifi_dhcp_client_binary="$(find_wifi_dhcp_client)"
  wifi_credentials_device_path="/metadata/shadow-wifi-credentials/by-token/$run_token.env"
  wifi_credentials_tmp_device_path="$wifi_credentials_device_path.tmp"
fi

if [[ "$dry_run" == "1" ]]; then
  firmware_dir="${firmware_dir:-\$PIXEL_PRODUCT_FIRMWARE_DIR}"
  input_module_dir="${input_module_dir:-\$PIXEL_PRODUCT_INPUT_MODULE_DIR}"
  if bool_true "$wifi_enabled"; then
    wifi_assets_dir="${wifi_assets_dir:-\$PIXEL_PRODUCT_WIFI_ASSETS_DIR}"
    wifi_linker_capsule_dir="${wifi_linker_capsule_dir:-\$PIXEL_PRODUCT_WIFI_LINKER_CAPSULE_DIR}"
    wifi_dhcp_client_binary="${wifi_dhcp_client_binary:-\$PIXEL_PRODUCT_WIFI_DHCP_CLIENT_BIN}"
  fi
elif [[ "$needs_build" == "1" && ( -z "$firmware_dir" || -z "$input_module_dir" ) ]]; then
  cat >&2 <<EOF
pixel_product_flash: missing sunfish touch firmware/modules.

Set:
  PIXEL_PRODUCT_FIRMWARE_DIR=/path/to/sunfish-gpu-touch
  PIXEL_PRODUCT_INPUT_MODULE_DIR=/path/to/sunfish-touch
or stage them in:
  build/pixel/firmware/sunfish-gpu-touch
  build/pixel/modules/sunfish-touch
EOF
  exit 66
fi
if bool_true "$wifi_enabled" && [[ "$dry_run" != "1" ]]; then
  if [[ -z "$wifi_credentials_file" || ! -r "$wifi_credentials_file" ]]; then
    echo "pixel_product_flash: --wifi requires --wifi-credentials FILE" >&2
    exit 66
  fi
  if [[ "$needs_build" == "1" && "$wifi_assets_auto_collect" != "1" && ( -z "$wifi_assets_dir" || ! -d "$wifi_assets_dir/modules" || ! -d "$wifi_assets_dir/firmware" ) ]]; then
    echo "pixel_product_flash: --wifi requires Wi-Fi assets with modules/ and firmware/" >&2
    exit 66
  fi
  if [[ "$needs_build" == "1" && "$wifi_linker_capsule_auto_collect" != "1" && ( -z "$wifi_linker_capsule_dir" || ! -d "$wifi_linker_capsule_dir" ) ]]; then
    echo "pixel_product_flash: --wifi requires a Wi-Fi linker capsule directory" >&2
    exit 66
  fi
  if ! validate_wifi_dhcp_client "$wifi_dhcp_client_binary"; then
    echo "pixel_product_flash: --wifi requires an executable static aarch64 busybox DHCP client" >&2
    exit 66
  fi
fi

mkdir -p "$run_dir"
if [[ "$dry_run" != "1" && "$build_only" != "1" ]]; then
  lease_args=(
    "$SCRIPT_DIR/shadowctl" lease acquire "$serial" \
    --owner "${USER:-codex}" \
    --lane product-flash \
    --ttl 7200
  )
  if bool_true "${SHADOW_DEVICE_LEASE_FORCE:-0}"; then
    lease_args+=(--force)
  fi
  "${lease_args[@]}"
fi

if bool_true "$wifi_enabled" && [[ "$needs_build" == "1" && "$dry_run" != "1" ]]; then
  if [[ "$wifi_assets_auto_collect" == "1" ]]; then
    echo
    echo "collecting Wi-Fi module/firmware assets..."
    rm -rf "$wifi_assets_dir"
    if ! PIXEL_SERIAL="$serial" "$SCRIPT_DIR/pixel/pixel_wifi_collect_boot_assets.sh" \
      --output "$wifi_assets_dir" \
      >"$wifi_assets_output_path" 2>&1; then
      cat "$wifi_assets_output_path" >&2 || true
      exit 66
    fi
  fi
  if [[ "$wifi_linker_capsule_auto_collect" == "1" ]]; then
    echo
    echo "collecting Wi-Fi linker capsule..."
    rm -rf "$wifi_linker_capsule_dir"
    if ! PIXEL_SERIAL="$serial" "$SCRIPT_DIR/pixel/pixel_wifi_collect_capsule.sh" \
      --output "$wifi_linker_capsule_dir" \
      >"$wifi_linker_capsule_output_path" 2>&1; then
      cat "$wifi_linker_capsule_output_path" >&2 || true
      exit 66
    fi
  fi
fi

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
  --boot-mode product
  --orange-gpu-mode shell-session
  --orange-gpu-firmware-helper true
  --orange-gpu-bundle-archive-source shadow-logical-partition
  --payload-probe-source shadow-logical-partition
  --payload-probe-root /shadow-payload
  --payload-probe-manifest-path /shadow-payload/manifest.env
  --hold-secs 0
  --dev-mount tmpfs
  --mount-dev true
  --mount-proc true
  --mount-sys true
  --dri-bootstrap sunfish-card0-renderD128-kgsl3d0
  --input-bootstrap sunfish-touch-event2
  --input-module-dir "$input_module_dir"
  --firmware-bootstrap ramdisk-lib-firmware
  --firmware-dir "$effective_firmware_dir"
  --shell-session-extra-app-ids "$all_apps"
  --run-token "$run_token"
)
if bool_true "$wifi_enabled"; then
  build_cmd+=(
    --wifi-bootstrap sunfish-wlan0
    --wifi-helper-profile "$wifi_helper_profile"
    --wifi-runtime-network true
    --wifi-runtime-clock-unix-secs "$(date +%s)"
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
  --slot "$target_slot"
  --extra-payload "$payload:orange-gpu.tar.xz"
  --output-dir "$stage_dir"
  --version "product-shadow-v1"
)

flash_cmd=(
  "$SCRIPT_DIR/pixel/pixel_boot_flash.sh"
  --experimental
  --slot "$target_slot"
  --activate-target
  --no-wait
  --image "$image"
)
if [[ "$allow_active_slot" == "1" ]]; then
  flash_cmd+=(--allow-active-slot)
fi

if [[ "$dry_run" == "1" ]]; then
  printf 'pixel_product_flash: dry-run\n'
  printf 'run_token=%s\nrun_dir=%s\nimage=%s\npayload=%s\nrequested_slot=%s\ntarget_slot=%s\nall_apps=%s\n' \
    "$run_token" "$run_dir" "$image" "$payload" "$requested_slot" "$target_slot" "$all_apps"
  printf 'firmware_dir=%s\ninput_module_dir=%s\n' "$effective_firmware_dir" "$input_module_dir"
  if bool_true "$wifi_enabled"; then
    printf 'wifi_enabled=true\nwifi_assets_dir=%s\nwifi_assets_auto_collect=%s\nwifi_linker_capsule_dir=%s\nwifi_linker_capsule_auto_collect=%s\nwifi_dhcp_client=%s\nwifi_credentials_device_path=%s\n' \
      "$wifi_assets_dir" \
      "$wifi_assets_auto_collect" \
      "$wifi_linker_capsule_dir" \
      "$wifi_linker_capsule_auto_collect" \
      "$wifi_dhcp_client_binary" \
      "$wifi_credentials_device_path"
  fi
  printf 'build_command=%q' env
  printf ' %q' \
    "PIXEL_GUEST_BUILD_SYSTEM=${PIXEL_GUEST_BUILD_SYSTEM:-aarch64-linux}" \
    "PIXEL_ORANGE_GPU_SHELL_SESSION_APP_PROFILE=pixel-shell" \
    "PIXEL_ORANGE_GPU_SHELL_START_APP_ID=shell"
  printf ' %q' "${build_cmd[@]}"
  printf '\n'
  printf 'stage_command=%q' env
  printf ' %q' "PIXEL_SERIAL=${serial:-SERIAL}" "SHADOW_DEVICE_LEASE_FORCE=1"
  printf ' %q' "${stage_cmd[@]}"
  printf '\n'
  printf 'flash_command=%q' env
  printf ' %q' "PIXEL_SERIAL=${serial:-SERIAL}" "PIXEL_BOOT_METADATA_PATH=$flash_metadata" "SHADOW_DEVICE_LEASE_FORCE=1"
  printf ' %q' "${flash_cmd[@]}"
  printf '\n'
  exit 0
fi

if [[ "$build_only" == "1" ]]; then
  printf 'pixel_product_flash: build-only\n'
  printf 'run_token=%s\nrun_dir=%s\nimage=%s\npayload=%s\n' "$run_token" "$run_dir" "$image" "$payload"
  if [[ "$needs_build" == "1" ]]; then
    env \
      PIXEL_GUEST_BUILD_SYSTEM="${PIXEL_GUEST_BUILD_SYSTEM:-aarch64-linux}" \
      PIXEL_ORANGE_GPU_SHELL_SESSION_APP_PROFILE=pixel-shell \
      PIXEL_ORANGE_GPU_SHELL_START_APP_ID=shell \
      "${build_cmd[@]}"
  else
    echo "reusing image: $image"
  fi
  exit 0
fi

echo "serial: $serial"
echo "run_token: $run_token"
echo "run_dir: $run_dir"
echo "shadow_slot_request: $requested_slot"
echo "shadow_target_slot: $target_slot"
echo "android_recovery_slot: $current_slot"
echo "all_apps: $all_apps"
if bool_true "$wifi_enabled"; then
  echo "wifi: enabled"
  echo "wifi_assets: $wifi_assets_dir"
  echo "wifi_linker_capsule: $wifi_linker_capsule_dir"
else
  echo "wifi: disabled"
fi
echo
if [[ "$needs_build" == "1" ]]; then
  echo
  echo "building product Shadow image..."
  env \
    PIXEL_GUEST_BUILD_SYSTEM="${PIXEL_GUEST_BUILD_SYSTEM:-aarch64-linux}" \
    PIXEL_ORANGE_GPU_SHELL_SESSION_APP_PROFILE=pixel-shell \
    PIXEL_ORANGE_GPU_SHELL_START_APP_ID=shell \
    "${build_cmd[@]}"
else
  echo "reusing image: $image"
fi

echo
echo "staging product logical payload..."
rm -rf "$stage_dir"
env PIXEL_SERIAL="$serial" SHADOW_DEVICE_LEASE_FORCE=1 "${stage_cmd[@]}"

if bool_true "$wifi_enabled"; then
  echo
  echo "staging Wi-Fi credentials..."
  stage_wifi_credentials
fi

echo
echo "flashing product Shadow boot image..."
env PIXEL_SERIAL="$serial" PIXEL_BOOT_METADATA_PATH="$flash_metadata" SHADOW_DEVICE_LEASE_FORCE=1 "${flash_cmd[@]}"

echo
echo "product flash complete"
echo "shadow boot metadata: $flash_metadata"
echo "android recovery slot: the slot printed as Known-good slot above"
echo "recovery path: hold volume-down at boot, enter fastboot, then switch back to the Android slot"
