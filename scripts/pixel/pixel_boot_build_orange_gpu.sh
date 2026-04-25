#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./pixel_runtime_session_common.sh
source "$SCRIPT_DIR/lib/pixel_runtime_session_common.sh"
# shellcheck source=./pixel_runtime_linux_bundle_common.sh
source "$SCRIPT_DIR/lib/pixel_runtime_linux_bundle_common.sh"
# shellcheck source=./bootimg_common.sh
source "$SCRIPT_DIR/lib/bootimg_common.sh"
ensure_bootimg_shell "$@"

INPUT_IMAGE="${PIXEL_BOOT_INPUT_IMAGE:-}"
HELLO_INIT_BINARY="${PIXEL_HELLO_INIT_BIN:-}"
HELLO_INIT_RUST_SHIM_BINARY="${PIXEL_HELLO_INIT_RUST_SHIM_BIN:-}"
HELLO_INIT_RUST_SHIM_MODE="${PIXEL_HELLO_INIT_RUST_SHIM_MODE:-exec}"
HELLO_INIT_RUST_CHILD_PROFILE="${PIXEL_HELLO_INIT_RUST_CHILD_PROFILE:-hello}"
HELLO_INIT_RUST_CHILD_ENTRY="${PIXEL_HELLO_INIT_RUST_CHILD_ENTRY:-hello-init-child}"
ORANGE_INIT_BINARY="${PIXEL_ORANGE_INIT_BIN:-}"
GPU_BUNDLE_DIR="${PIXEL_ORANGE_GPU_BUNDLE_DIR:-}"
SHADOW_SESSION_BINARY="${PIXEL_SHADOW_SESSION_BIN:-}"
SHADOW_COMPOSITOR_BINARY="${PIXEL_SHADOW_COMPOSITOR_GUEST_BIN:-}"
SHADOW_COMPOSITOR_DYNAMIC_BINARY="${PIXEL_SHADOW_COMPOSITOR_GUEST_DYNAMIC_BIN:-}"
APP_DIRECT_PRESENT_CLIENT_LAUNCHER_BINARY="${PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_LAUNCHER_BIN:-}"
KEY_PATH="${AVB_TEST_KEY_PATH:-}"
OUTPUT_IMAGE="${PIXEL_BOOT_ORANGE_GPU_IMAGE:-}"
HELLO_INIT_MODE="${PIXEL_HELLO_INIT_MODE:-direct}"
BOOT_MODE="${PIXEL_SHADOW_BOOT_MODE:-${PIXEL_HELLO_INIT_BOOT_MODE:-lab}}"
HOLD_SECS="${PIXEL_HELLO_INIT_HOLD_SECS:-3}"
PRELUDE="${PIXEL_ORANGE_GPU_PRELUDE:-none}"
PRELUDE_HOLD_SECS="${PIXEL_ORANGE_GPU_PRELUDE_HOLD_SECS:-0}"
ORANGE_GPU_MODE="${PIXEL_ORANGE_GPU_MODE:-gpu-render}"
ORANGE_GPU_LAUNCH_DELAY_SECS="${PIXEL_ORANGE_GPU_LAUNCH_DELAY_SECS:-0}"
ORANGE_GPU_PARENT_PROBE_ATTEMPTS="${PIXEL_ORANGE_GPU_PARENT_PROBE_ATTEMPTS:-0}"
ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS="${PIXEL_ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS:-0}"
ORANGE_GPU_METADATA_STAGE_BREADCRUMB="${PIXEL_ORANGE_GPU_METADATA_STAGE_BREADCRUMB:-false}"
ORANGE_GPU_METADATA_PRUNE_TOKEN_ROOT="${PIXEL_ORANGE_GPU_METADATA_PRUNE_TOKEN_ROOT:-false}"
ORANGE_GPU_FIRMWARE_HELPER="${PIXEL_ORANGE_GPU_FIRMWARE_HELPER:-false}"
ORANGE_GPU_TIMEOUT_ACTION="${PIXEL_ORANGE_GPU_TIMEOUT_ACTION:-reboot}"
ORANGE_GPU_WATCHDOG_TIMEOUT_SECS="${PIXEL_ORANGE_GPU_WATCHDOG_TIMEOUT_SECS:-0}"
REBOOT_TARGET="${PIXEL_HELLO_INIT_REBOOT_TARGET:-bootloader}"
DEV_MOUNT="${PIXEL_ORANGE_GPU_DEV_MOUNT:-tmpfs}"
MOUNT_DEV="${PIXEL_HELLO_INIT_MOUNT_DEV:-true}"
MOUNT_PROC="${PIXEL_HELLO_INIT_MOUNT_PROC:-true}"
MOUNT_SYS="${PIXEL_HELLO_INIT_MOUNT_SYS:-true}"
LOG_KMSG="${PIXEL_HELLO_INIT_LOG_KMSG:-true}"
LOG_PMSG="${PIXEL_HELLO_INIT_LOG_PMSG:-true}"
RUN_TOKEN="${PIXEL_HELLO_INIT_RUN_TOKEN:-${PIXEL_ORANGE_GPU_RUN_TOKEN:-}}"
DRI_BOOTSTRAP="${PIXEL_ORANGE_GPU_DRI_BOOTSTRAP:-}"
INPUT_BOOTSTRAP="${PIXEL_ORANGE_GPU_INPUT_BOOTSTRAP:-none}"
WIFI_BOOTSTRAP="${PIXEL_ORANGE_GPU_WIFI_BOOTSTRAP:-none}"
if [[ -n "${PIXEL_ORANGE_GPU_WIFI_HELPER_PROFILE+x}" ]]; then
  WIFI_HELPER_PROFILE_EXPLICIT=1
else
  WIFI_HELPER_PROFILE_EXPLICIT=0
fi
WIFI_HELPER_PROFILE="${PIXEL_ORANGE_GPU_WIFI_HELPER_PROFILE:-full}"
WIFI_SUPPLICANT_PROBE="${PIXEL_ORANGE_GPU_WIFI_SUPPLICANT_PROBE:-true}"
WIFI_ASSOCIATION_PROBE="${PIXEL_ORANGE_GPU_WIFI_ASSOCIATION_PROBE:-false}"
WIFI_IP_PROBE="${PIXEL_ORANGE_GPU_WIFI_IP_PROBE:-false}"
WIFI_RUNTIME_NETWORK="${PIXEL_ORANGE_GPU_WIFI_RUNTIME_NETWORK:-false}"
WIFI_RUNTIME_CLOCK_UNIX_SECS="${PIXEL_ORANGE_GPU_WIFI_RUNTIME_CLOCK_UNIX_SECS:-}"
WIFI_CREDENTIALS_PATH="${PIXEL_ORANGE_GPU_WIFI_CREDENTIALS_PATH:-}"
WIFI_DHCP_CLIENT_BINARY="${PIXEL_ORANGE_GPU_WIFI_DHCP_CLIENT_BIN:-}"
FIRMWARE_BOOTSTRAP="${PIXEL_ORANGE_GPU_FIRMWARE_BOOTSTRAP:-none}"
GPU_FIRMWARE_DIR="${PIXEL_ORANGE_GPU_FIRMWARE_DIR:-}"
INPUT_MODULE_DIR="${PIXEL_ORANGE_GPU_INPUT_MODULE_DIR:-}"
WIFI_MODULE_DIR="${PIXEL_ORANGE_GPU_WIFI_MODULE_DIR:-}"
CAMERA_LINKER_CAPSULE_DIR="${PIXEL_CAMERA_LINKER_CAPSULE_DIR:-${PIXEL_WIFI_LINKER_CAPSULE_DIR:-}}"
CAMERA_HAL_BIONIC_PROBE_BINARY="${PIXEL_CAMERA_HAL_BIONIC_PROBE_BINARY:-}"
SHADOW_PROPERTY_SHIM_BINARY="${PIXEL_SHADOW_PROPERTY_SHIM_BINARY:-}"
CAMERA_HAL_CAMERA_ID="${PIXEL_CAMERA_HAL_CAMERA_ID:-0}"
CAMERA_HAL_CALL_OPEN="${PIXEL_CAMERA_HAL_CALL_OPEN:-false}"
KEEP_WORK_DIR=0
WORK_DIR=""
STAGED_HELLO_INIT_BINARY=""
STAGED_HELLO_INIT_RUST_SHIM_BINARY=""
STAGED_CAMERA_LINKER_VENDOR_DIR=""
COMPOSITOR_SCENE_STARTUP_CONFIG=""
APP_DIRECT_PRESENT_STARTUP_CONFIG=""
SHELL_SESSION_STARTUP_CONFIG=""
CONFIG_ENTRY="shadow-init.cfg"
PAYLOAD_ROOT="orange-gpu"
PAYLOAD_IMAGE_PATH="/orange-gpu"
COMPOSITOR_SCENE_STARTUP_CONFIG_NAME="compositor-scene-startup.json"
COMPOSITOR_SCENE_STARTUP_CONFIG_PATH="/orange-gpu/compositor-scene-startup.json"
COMPOSITOR_SCENE_SESSION_PATH="/orange-gpu/shadow-session"
COMPOSITOR_SCENE_COMPOSITOR_PATH="/orange-gpu/shadow-compositor-guest"
COMPOSITOR_SCENE_DUMMY_CLIENT_PATH="/orange-gpu/shadow-shell-dummy-client"
COMPOSITOR_SCENE_RUNTIME_DIR="/shadow-runtime"
APP_DIRECT_PRESENT_STARTUP_CONFIG_NAME="app-direct-present-startup.json"
APP_DIRECT_PRESENT_STARTUP_CONFIG_PATH="/orange-gpu/app-direct-present-startup.json"
APP_DIRECT_PRESENT_RUNTIME_DIR="/shadow-runtime"
SHELL_SESSION_STARTUP_CONFIG_NAME="shell-session-startup.json"
SHELL_SESSION_STARTUP_CONFIG_PATH="/orange-gpu/shell-session-startup.json"
SHELL_SESSION_START_APP_ID="${PIXEL_ORANGE_GPU_SHELL_START_APP_ID:-${PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_APP_ID:-counter}}"
SHELL_SESSION_APP_PROFILE="${PIXEL_ORANGE_GPU_SHELL_SESSION_APP_PROFILE:-}"
if [[ -n "${PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_APP_ID+x}" ]]; then
  APP_DIRECT_PRESENT_APP_ID_EXPLICIT=1
else
  APP_DIRECT_PRESENT_APP_ID_EXPLICIT=0
fi
APP_DIRECT_PRESENT_APP_ID="${PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_APP_ID-rust-demo}"
APP_DIRECT_PRESENT_CLIENT_KIND=""
APP_DIRECT_PRESENT_BUNDLE_DIR_NAME="app-direct-present"
APP_DIRECT_PRESENT_BUNDLE_ROOT_PATH="/orange-gpu/app-direct-present"
APP_DIRECT_PRESENT_BINARY_NAME="shadow-rust-demo"
APP_DIRECT_PRESENT_BINARY_PATH="/orange-gpu/app-direct-present/shadow-rust-demo"
APP_DIRECT_PRESENT_CLIENT_LAUNCHER_NAME="run-shadow-rust-demo"
APP_DIRECT_PRESENT_CLIENT_PATH="/orange-gpu/app-direct-present/run-shadow-rust-demo"
APP_DIRECT_PRESENT_STAGE_LOADER_PATH="/orange-gpu/app-direct-present/lib/ld-linux-aarch64.so.1"
APP_DIRECT_PRESENT_STAGE_LIBRARY_PATH="/orange-gpu/app-direct-present/lib"
APP_DIRECT_PRESENT_SYSTEM_BINARY_NAME=""
APP_DIRECT_PRESENT_SYSTEM_BINARY_PATH=""
APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV=""
APP_DIRECT_PRESENT_RUNTIME_BUNDLE_NAME=""
APP_DIRECT_PRESENT_RUNTIME_BUNDLE_PATH=""
APP_DIRECT_PRESENT_TS_INPUT_PATH=""
APP_DIRECT_PRESENT_TS_CACHE_DIR=""
APP_DIRECT_PRESENT_TS_RENDERER="${PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_TS_RENDERER:-gpu}"
APP_DIRECT_PRESENT_MANUAL_TOUCH="${PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_MANUAL_TOUCH:-false}"
ORANGE_GPU_ENABLE_LINUX_AUDIO="${PIXEL_ORANGE_GPU_ENABLE_LINUX_AUDIO:-false}"
ORANGE_GPU_AUDIO_PACKAGE_REF="$(repo_root)#packages.${PIXEL_GUEST_BUILD_SYSTEM:-aarch64-linux}.shadow-audio-bridge-aarch64-linux-gnu"
ORANGE_GPU_AUDIO_OUT_LINK="$(pixel_dir)/shadow-audio-bridge-aarch64-linux-gnu-result"
ORANGE_GPU_AUDIO_BINARY_NAME="shadow-audio-bridge"
ORANGE_GPU_AUDIO_BINARY_PATH="$PAYLOAD_IMAGE_PATH/$ORANGE_GPU_AUDIO_BINARY_NAME"
SHELL_SESSION_EXTRA_APP_IDS="${PIXEL_ORANGE_GPU_SHELL_SESSION_EXTRA_APP_IDS:-}"
SHELL_SESSION_EXTRA_ENV_ASSIGNMENTS=()
ORANGE_GPU_BUNDLE_ARCHIVE_NAME="orange-gpu.tar.xz"
ORANGE_GPU_BUNDLE_ARCHIVE_PATH="/orange-gpu.tar.xz"
ORANGE_GPU_BUNDLE_ARCHIVE_SOURCE="${PIXEL_ORANGE_GPU_BUNDLE_ARCHIVE_SOURCE:-ramdisk}"
STAGED_GPU_BUNDLE_ARCHIVE=""
EXTERNAL_GPU_BUNDLE_ARCHIVE=""
STAGED_GPU_BUNDLE_DIR=""
PAYLOAD_PROBE_STRATEGY="metadata-shadow-payload-v1"
PAYLOAD_PROBE_SOURCE="${PIXEL_BOOT_PAYLOAD_SOURCE:-metadata}"
PAYLOAD_PROBE_ROOT="${PIXEL_BOOT_PAYLOAD_ROOT:-}"
PAYLOAD_PROBE_MANIFEST_PATH="${PIXEL_BOOT_PAYLOAD_MANIFEST_PATH:-}"
PAYLOAD_PROBE_FALLBACK_PATH="/orange-gpu"
METADATA_SUFFIX=".hello-init.json"
DEFAULT_RUST_CHILD_ENTRY="hello-init-child"

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_build_orange_gpu.sh [--input PATH] [--init PATH]
                                                    [--rust-shim PATH]
                                                    [--rust-shim-mode fork|exec]
                                                    [--rust-child-profile hello|std-probe|nostd-probe]
                                                    [--orange-init PATH]
                                                    [--gpu-bundle DIR] [--key PATH]
                                                    [--output PATH] [--hold-secs N]
                                                    [--hello-init-mode direct|rust-bridge]
                                                    [--boot-mode lab|product]
                                                    [--prelude none|orange-init]
                                                    [--prelude-hold-secs N]
                                                    [--orange-gpu-mode gpu-render|orange-gpu-loop|bundle-smoke|vulkan-instance-smoke|raw-vulkan-instance-smoke|firmware-probe-only|timeout-control-smoke|camera-hal-link-probe|wifi-linux-surface-probe|c-kgsl-open-readonly-smoke|c-kgsl-open-readonly-firmware-helper-smoke|c-kgsl-open-readonly-pid1-smoke|raw-kgsl-open-readonly-smoke|raw-kgsl-getproperties-smoke|raw-vulkan-physical-device-count-query-exit-smoke|raw-vulkan-physical-device-count-query-no-destroy-smoke|raw-vulkan-physical-device-count-query-smoke|raw-vulkan-physical-device-count-smoke|vulkan-enumerate-adapters-count-smoke|vulkan-enumerate-adapters-smoke|vulkan-adapter-smoke|vulkan-device-request-smoke|vulkan-device-smoke|vulkan-offscreen|compositor-scene|shell-session|shell-session-held|shell-session-runtime-touch-counter|app-direct-present|app-direct-present-touch-counter|app-direct-present-runtime-touch-counter|payload-partition-probe]
                                                    [--orange-gpu-launch-delay-secs N]
                                                    [--orange-gpu-parent-probe-attempts N]
                                                    [--orange-gpu-parent-probe-interval-secs N]
                                                    [--orange-gpu-metadata-stage-breadcrumb true|false]
                                                    [--orange-gpu-metadata-prune-token-root true|false]
                                                    [--orange-gpu-firmware-helper true|false]
                                                    [--orange-gpu-timeout-action reboot|panic|hold]
                                                    [--orange-gpu-watchdog-timeout-secs N]
                                                    [--orange-gpu-bundle-archive-source ramdisk|shadow-logical-partition]
                                                    [--payload-probe-source metadata|shadow-logical-partition]
                                                    [--payload-probe-root PATH]
                                                    [--payload-probe-manifest-path PATH]
                                                    [--camera-linker-capsule DIR]
                                                    [--wifi-linker-capsule DIR]
                                                    [--camera-hal-bionic-probe PATH]
                                                    [--camera-hal-camera-id ID]
                                                    [--camera-hal-call-open true|false]
                                                    [--reboot-target TARGET]
                                                    [--run-token TOKEN]
                                                    [--dev-mount devtmpfs|tmpfs]
                                                    [--mount-dev true|false]
                                                    [--mount-proc true|false]
                                                    [--mount-sys true|false]
                                                    [--log-kmsg true|false]
                                                    [--log-pmsg true|false]
                                                    [--dri-bootstrap none|sunfish-card0-renderD128|sunfish-card0-renderD128-kgsl3d0]
                                                    [--input-bootstrap none|sunfish-touch-event2]
                                                    [--input-module-dir DIR]
                                                    [--wifi-bootstrap none|sunfish-wlan0]
                                                    [--wifi-helper-profile full|no-service-managers|no-pm|no-modem-svc|no-rfs-storage|no-pd-mapper|no-cnss|qrtr-only|qrtr-pd|qrtr-pd-tftp|qrtr-pd-rfs|qrtr-pd-rfs-cnss|qrtr-pd-rfs-modem|qrtr-pd-rfs-modem-cnss|qrtr-pd-rfs-modem-pm|qrtr-pd-rfs-modem-pm-cnss|aidl-sm-core|vnd-sm-core|vnd-sm-core-binder-node|all-sm-core|none]
                                                    [--wifi-supplicant-probe true|false]
                                                    [--wifi-association-probe true|false]
                                                    [--wifi-ip-probe true|false]
                                                    [--wifi-runtime-network true|false]
                                                    [--wifi-runtime-clock-unix-secs SECONDS]
                                                    [--wifi-credentials-path DEVICE_PATH]
                                                    [--wifi-dhcp-client BIN]
                                                    [--wifi-module-dir DIR]
                                                    [--firmware-bootstrap none|ramdisk-lib-firmware]
                                                    [--firmware-dir DIR]
                                                    [--app-direct-present-manual-touch true|false]
                                                    [--shell-session-extra-app-ids IDS]
                                                    [--keep-work-dir]

Build a private stock-kernel sunfish boot.img whose real first-stage userspace is
hello-init PID 1 at system/bin/init and whose ramdisk contains a boot-owned
shadow-gpu-smoke bundle under /orange-gpu for one of the current boot rungs: the real GPU
render/present path, a strict Vulkan instance smoke, a strict raw Vulkan
instance smoke, a firmware preflight-only smoke, an intentional timeout-control
smoke, a direct C KGSL read-only open
smoke, a direct C PID1 KGSL
read-only open smoke, a strict raw KGSL read-only open smoke, a strict raw KGSL
getproperties smoke, a strict raw Vulkan
physical-device-count-query-exit smoke,
a strict raw Vulkan physical-device-count-query-no-destroy smoke, a strict raw
Vulkan physical-device-count-query smoke, a strict raw Vulkan physical-device-count
smoke, a strict Vulkan raw adapter-enumeration-count smoke, a strict Vulkan
adapter-enumeration smoke, a strict Vulkan adapter smoke, a strict Vulkan
device-request smoke, a strict Vulkan device/buffer smoke, a strict Vulkan
offscreen render path, a compositor-owned shell scene, a shell-owned app
session, a held shell/app session, an app-owned
direct-present scene with no shell, or the no-Vulkan bundle-exec smoke path.
EOF
}

default_output_image() {
  if [[ "$HELLO_INIT_MODE" == "rust-bridge" ]]; then
    local suffix=""
    if [[ "$HELLO_INIT_RUST_SHIM_MODE" != "exec" ]]; then
      suffix+="-${HELLO_INIT_RUST_SHIM_MODE}"
    fi
    if [[ "$HELLO_INIT_RUST_CHILD_PROFILE" != "hello" ]]; then
      suffix+="-${HELLO_INIT_RUST_CHILD_PROFILE}"
    fi
    printf '%s/shadow-boot-orange-gpu-rust-bridge%s.img\n' "$(pixel_boot_dir)" "$suffix"
  else
    printf '%s/shadow-boot-orange-gpu.img\n' "$(pixel_boot_dir)"
  fi
}

default_hello_init_binary() {
  printf '%s\n' "${PIXEL_HELLO_INIT_DEFAULT_BIN:-$(pixel_boot_dir)/hello-init}"
}

default_rust_hello_init_binary() {
  case "$HELLO_INIT_RUST_CHILD_PROFILE" in
    hello)
      printf '%s\n' "${PIXEL_HELLO_INIT_RUST_DEFAULT_BIN:-$(pixel_boot_dir)/hello-init-rust}"
      ;;
    std-probe)
      printf '%s\n' "${PIXEL_HELLO_INIT_RUST_STD_PROBE_DEFAULT_BIN:-$(pixel_boot_dir)/hello-init-rust-probe}"
      ;;
    nostd-probe)
      printf '%s\n' "${PIXEL_HELLO_INIT_RUST_NOSTD_PROBE_DEFAULT_BIN:-$(pixel_boot_dir)/hello-init-rust-nostd-probe}"
      ;;
  esac
}

default_rust_hello_init_shim_binary() {
  case "$HELLO_INIT_RUST_SHIM_MODE" in
    fork)
      printf '%s\n' "${PIXEL_HELLO_INIT_RUST_SHIM_DEFAULT_BIN:-$(pixel_boot_dir)/hello-init-rust-shim}"
      ;;
    exec)
      printf '%s\n' "${PIXEL_HELLO_INIT_RUST_SHIM_EXEC_DEFAULT_BIN:-$(pixel_boot_dir)/hello-init-rust-shim-exec}"
      ;;
  esac
}

default_rust_hello_init_package_ref() {
  case "$HELLO_INIT_RUST_CHILD_PROFILE" in
    hello)
      printf 'path:%s#hello-init-rust-device\n' "$(repo_root)"
      ;;
    std-probe)
      printf 'path:%s#hello-init-rust-probe-device\n' "$(repo_root)"
      ;;
    nostd-probe)
      printf 'path:%s#hello-init-rust-nostd-probe-device\n' "$(repo_root)"
      ;;
  esac
}

default_rust_hello_init_binary_name() {
  case "$HELLO_INIT_RUST_CHILD_PROFILE" in
    hello)
      printf 'hello-init\n'
      ;;
    std-probe)
      printf 'hello-init-probe\n'
      ;;
    nostd-probe)
      printf 'hello-init-nostd-probe\n'
      ;;
  esac
}

default_rust_hello_init_shim_package_ref() {
  case "$HELLO_INIT_RUST_SHIM_MODE" in
    fork)
      printf 'path:%s#hello-init-rust-shim-device\n' "$(repo_root)"
      ;;
    exec)
      printf 'path:%s#hello-init-rust-shim-exec-device\n' "$(repo_root)"
      ;;
  esac
}

default_rust_hello_init_shim_binary_name() {
  case "$HELLO_INIT_RUST_SHIM_MODE" in
    fork)
      printf 'hello-init-shim\n'
      ;;
    exec)
      printf 'hello-init-shim-exec\n'
      ;;
  esac
}

default_orange_init_binary() {
  printf '%s\n' "${PIXEL_ORANGE_INIT_DEFAULT_BIN:-$(pixel_boot_dir)/orange-init}"
}

default_gpu_bundle_dir() {
  printf '%s\n' "$(pixel_artifact_path shadow-gpu-smoke-gnu)"
}

default_camera_hal_bionic_probe_binary() {
  printf '%s\n' "$(pixel_artifact_path camera-hal-bionic-probe)"
}

default_shadow_property_shim_binary() {
  printf '%s\n' "$(pixel_artifact_path shadow-property-shim)"
}

default_app_direct_present_client_launcher_binary() {
  printf '%s\n' "${PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_LAUNCHER_DEFAULT_BIN:-$(pixel_artifact_path app-direct-present-launcher)}"
}

resolve_app_direct_present_metadata() {
  local app_metadata

  app_metadata="$(
    python3 - "$(repo_root)/runtime/apps.json" "$APP_DIRECT_PRESENT_APP_ID" <<'PY'
import json
import sys

manifest_path, requested_app_id = sys.argv[1:3]
with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

for app in manifest.get("apps", []):
    if app.get("id") != requested_app_id:
        continue
    model = app.get("model", "")
    runtime = app.get("runtime") or {}
    print(model)
    print(app.get("binaryName", ""))
    print(runtime.get("bundleEnv", ""))
    print(runtime.get("bundleFilename", ""))
    print(runtime.get("inputPath", ""))
    raise SystemExit(0)

raise SystemExit(f"unknown app-direct-present app id: {requested_app_id}")
PY
  )"
  APP_DIRECT_PRESENT_CLIENT_KIND="$(sed -n '1p' <<<"$app_metadata")"
  APP_DIRECT_PRESENT_BINARY_NAME="$(sed -n '2p' <<<"$app_metadata")"
  APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV="$(sed -n '3p' <<<"$app_metadata")"
  APP_DIRECT_PRESENT_RUNTIME_BUNDLE_NAME="$(sed -n '4p' <<<"$app_metadata")"
  APP_DIRECT_PRESENT_TS_INPUT_PATH="$(sed -n '5p' <<<"$app_metadata")"

  case "$APP_DIRECT_PRESENT_CLIENT_KIND" in
    rust)
      APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV=""
      APP_DIRECT_PRESENT_RUNTIME_BUNDLE_NAME=""
      APP_DIRECT_PRESENT_RUNTIME_BUNDLE_PATH=""
      APP_DIRECT_PRESENT_TS_INPUT_PATH=""
      APP_DIRECT_PRESENT_SYSTEM_BINARY_NAME=""
      APP_DIRECT_PRESENT_SYSTEM_BINARY_PATH=""
      ;;
    typescript)
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: unsupported app-direct-present app model for $APP_DIRECT_PRESENT_APP_ID: $APP_DIRECT_PRESENT_CLIENT_KIND" >&2
      exit 1
      ;;
  esac

  [[ -n "$APP_DIRECT_PRESENT_BINARY_NAME" ]] || {
    echo "pixel_boot_build_orange_gpu: missing app-direct-present binary name for $APP_DIRECT_PRESENT_APP_ID" >&2
    exit 1
  }

  APP_DIRECT_PRESENT_BINARY_PATH="$APP_DIRECT_PRESENT_BUNDLE_ROOT_PATH/$APP_DIRECT_PRESENT_BINARY_NAME"
  APP_DIRECT_PRESENT_CLIENT_LAUNCHER_NAME="run-$APP_DIRECT_PRESENT_BINARY_NAME"
  APP_DIRECT_PRESENT_CLIENT_PATH="$APP_DIRECT_PRESENT_BUNDLE_ROOT_PATH/$APP_DIRECT_PRESENT_CLIENT_LAUNCHER_NAME"

  if [[ "$APP_DIRECT_PRESENT_CLIENT_KIND" == "typescript" ]]; then
    case "$APP_DIRECT_PRESENT_TS_RENDERER" in
      cpu|gpu)
        ;;
      *)
        echo "pixel_boot_build_orange_gpu: unsupported app-direct-present TypeScript renderer: $APP_DIRECT_PRESENT_TS_RENDERER" >&2
        exit 1
        ;;
    esac
    [[ -n "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV" && -n "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_NAME" && -n "$APP_DIRECT_PRESENT_TS_INPUT_PATH" ]] || {
      echo "pixel_boot_build_orange_gpu: incomplete TypeScript app metadata for $APP_DIRECT_PRESENT_APP_ID" >&2
      exit 1
    }
    APP_DIRECT_PRESENT_SYSTEM_BINARY_NAME="shadow-system"
    APP_DIRECT_PRESENT_SYSTEM_BINARY_PATH="$APP_DIRECT_PRESENT_BUNDLE_ROOT_PATH/$APP_DIRECT_PRESENT_SYSTEM_BINARY_NAME"
    APP_DIRECT_PRESENT_RUNTIME_BUNDLE_PATH="$APP_DIRECT_PRESENT_BUNDLE_ROOT_PATH/$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_NAME"
    APP_DIRECT_PRESENT_TS_CACHE_DIR="${PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_TS_CACHE_DIR:-build/runtime/boot-app-direct-present-$APP_DIRECT_PRESENT_APP_ID}"
    APP_DIRECT_PRESENT_STAGE_LOADER_PATH="$PAYLOAD_IMAGE_PATH/lib/ld-linux-aarch64.so.1"
    APP_DIRECT_PRESENT_STAGE_LIBRARY_PATH="$PAYLOAD_IMAGE_PATH/lib"
  fi
}

app_direct_present_runtime_app_env_prefix() {
  python3 - "$APP_DIRECT_PRESENT_APP_ID" <<'PY'
import re
import sys

print(re.sub(r"[^A-Z0-9]+", "_", sys.argv[1].upper()))
PY
}

runtime_build_profile_for_shell_session() {
  if [[ -n "$SHELL_SESSION_APP_PROFILE" ]]; then
    printf '%s\n' "$SHELL_SESSION_APP_PROFILE"
  else
    printf 'pixel-shell\n'
  fi
}

runtime_cache_env_name_for_profile() {
  local profile app_env_prefix profile_env_prefix
  profile="${1:?runtime_cache_env_name_for_profile requires a profile}"
  app_env_prefix="${2:?runtime_cache_env_name_for_profile requires an app env prefix}"

  case "$profile" in
    pixel-shell)
      profile_env_prefix="PIXEL_SHELL"
      ;;
    boot-shell-demo)
      profile_env_prefix="BOOT_SHELL_DEMO"
      ;;
    vm-shell)
      profile_env_prefix="SHADOW_VM_SHELL"
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: unsupported shell runtime build profile: $profile" >&2
      exit 1
      ;;
  esac

  printf '%s_%s_CACHE_DIR\n' "$profile_env_prefix" "$app_env_prefix"
}

hello_init_metadata_path() {
  local image_path
  image_path="${1:?hello_init_metadata_path requires an image path}"
  printf '%s%s\n' "$image_path" "$METADATA_SUFFIX"
}

metadata_stage_path_for_token() {
  local run_token
  run_token="${1:?metadata_stage_path_for_token requires a run token}"
  printf '/metadata/shadow-hello-init/by-token/%s/stage.txt\n' "$run_token"
}

metadata_probe_stage_path_for_token() {
  local run_token
  run_token="${1:?metadata_probe_stage_path_for_token requires a run token}"
  printf '/metadata/shadow-hello-init/by-token/%s/probe-stage.txt\n' "$run_token"
}

metadata_probe_fingerprint_path_for_token() {
  local run_token
  run_token="${1:?metadata_probe_fingerprint_path_for_token requires a run token}"
  printf '/metadata/shadow-hello-init/by-token/%s/probe-fingerprint.txt\n' "$run_token"
}

metadata_probe_report_path_for_token() {
  local run_token
  run_token="${1:?metadata_probe_report_path_for_token requires a run token}"
  printf '/metadata/shadow-hello-init/by-token/%s/probe-report.txt\n' "$run_token"
}

metadata_probe_timeout_class_path_for_token() {
  local run_token
  run_token="${1:?metadata_probe_timeout_class_path_for_token requires a run token}"
  printf '/metadata/shadow-hello-init/by-token/%s/probe-timeout-class.txt\n' "$run_token"
}

metadata_probe_summary_path_for_token() {
  local run_token
  run_token="${1:?metadata_probe_summary_path_for_token requires a run token}"
  printf '/metadata/shadow-hello-init/by-token/%s/probe-summary.json\n' "$run_token"
}

metadata_compositor_frame_path_for_token() {
  local run_token
  run_token="${1:?metadata_compositor_frame_path_for_token requires a run token}"
  printf '/metadata/shadow-hello-init/by-token/%s/compositor-frame.ppm\n' "$run_token"
}

payload_partition_probe_mode() {
  [[ "$ORANGE_GPU_MODE" == "payload-partition-probe" ]]
}

orange_gpu_bundle_archive_from_shadow_logical() {
  [[ "$ORANGE_GPU_BUNDLE_ARCHIVE_SOURCE" == "shadow-logical-partition" ]]
}

payload_probe_config_enabled() {
  payload_partition_probe_mode || orange_gpu_bundle_archive_from_shadow_logical
}

payload_probe_root_for_token() {
  local run_token
  run_token="${1:?payload_probe_root_for_token requires a run token}"
  if [[ -n "$PAYLOAD_PROBE_ROOT" ]]; then
    printf '%s\n' "$PAYLOAD_PROBE_ROOT"
    return 0
  fi
  printf '/metadata/shadow-payload/by-token/%s\n' "$run_token"
}

payload_probe_manifest_path_for_token() {
  local run_token
  run_token="${1:?payload_probe_manifest_path_for_token requires a run token}"
  if [[ -n "$PAYLOAD_PROBE_MANIFEST_PATH" ]]; then
    printf '%s\n' "$PAYLOAD_PROBE_MANIFEST_PATH"
    return 0
  fi
  printf '%s/manifest.env\n' "$(payload_probe_root_for_token "$run_token")"
}

orange_gpu_mode_uses_ramdisk_gpu_bundle() {
  ! payload_partition_probe_mode
}

gpu_scene_value() {
  case "$ORANGE_GPU_MODE" in
    gpu-render)
      printf 'flat-orange\n'
      ;;
    orange-gpu-loop)
      printf 'orange-gpu-loop\n'
      ;;
    *)
      printf '\n'
      ;;
  esac
}

success_postlude_value() {
  if orange_gpu_mode_uses_success_postlude && [[ "$PRELUDE" == "orange-init" ]]; then
    printf 'orange-init\n'
  else
    printf 'none\n'
  fi
}

checkpoint_hold_seconds_value() {
  if orange_gpu_mode_uses_visible_checkpoints && [[ "$PRELUDE" == "orange-init" ]]; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

orange_gpu_mode_uses_success_postlude() {
  case "$ORANGE_GPU_MODE" in
    gpu-render|orange-gpu-loop|bundle-smoke|vulkan-instance-smoke|raw-vulkan-instance-smoke|raw-vulkan-physical-device-count-query-exit-smoke|raw-vulkan-physical-device-count-query-no-destroy-smoke|raw-vulkan-physical-device-count-query-smoke|raw-vulkan-physical-device-count-smoke|vulkan-enumerate-adapters-count-smoke|vulkan-enumerate-adapters-smoke|vulkan-adapter-smoke|vulkan-device-request-smoke|vulkan-device-smoke|vulkan-offscreen)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

orange_gpu_mode_uses_visible_checkpoints() {
  if orange_gpu_mode_uses_success_postlude; then
    return 0
  fi

  case "$ORANGE_GPU_MODE" in
    firmware-probe-only|timeout-control-smoke|camera-hal-link-probe|wifi-linux-surface-probe|c-kgsl-open-readonly-smoke|c-kgsl-open-readonly-firmware-helper-smoke|c-kgsl-open-readonly-pid1-smoke)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

generate_run_token() {
  python3 - <<'PY'
import secrets

print(secrets.token_hex(16))
PY
}

assert_input_matches_stock_boot() {
  local stock_image
  stock_image="$(pixel_resolve_stock_boot_img)"

  if ! cmp -s "$INPUT_IMAGE" "$stock_image"; then
    cat <<EOF >&2
pixel_boot_build_orange_gpu: input image must match the cached stock boot image exactly

Input image: $INPUT_IMAGE
Stock image: $stock_image
EOF
    exit 1
  fi
}

assert_stock_root_init_shape() {
  local unpack_dir ramdisk_cpio
  unpack_dir="$WORK_DIR/input-unpacked"
  ramdisk_cpio="$WORK_DIR/input-ramdisk.cpio"

  bootimg_unpack_to_dir "$INPUT_IMAGE" "$unpack_dir"
  bootimg_decompress_ramdisk "$unpack_dir/out/ramdisk" "$ramdisk_cpio" >/dev/null

  PYTHONPATH="$SCRIPT_DIR/lib" python3 - "$ramdisk_cpio" <<'PY'
from pathlib import Path
import stat
import sys

from cpio_edit import read_cpio

ramdisk_cpio = Path(sys.argv[1])
entries = {entry.name: entry for entry in read_cpio(ramdisk_cpio).without_trailer()}

init_entry = entries.get("init")
if init_entry is None:
    raise SystemExit(
        "pixel_boot_build_orange_gpu: missing root init entry in ramdisk"
    )
if not stat.S_ISLNK(init_entry.mode):
    raise SystemExit(
        "pixel_boot_build_orange_gpu: expected stock root /init symlink to "
        "/system/bin/init, found non-symlink entry"
    )

target = init_entry.data.decode("utf-8", errors="surrogateescape")
if target != "/system/bin/init":
    raise SystemExit(
        "pixel_boot_build_orange_gpu: expected stock root /init symlink target "
        f"/system/bin/init, found {target!r}"
    )

system_init_entry = entries.get("system/bin/init")
if system_init_entry is None:
    raise SystemExit(
        "pixel_boot_build_orange_gpu: missing system/bin/init entry in ramdisk"
    )
if stat.S_ISLNK(system_init_entry.mode):
    raise SystemExit(
        "pixel_boot_build_orange_gpu: expected stock system/bin/init to be a "
        "regular file, found a symlink"
    )
PY
}

assert_binary_sentinel() {
  local binary_path sentinel message
  binary_path="${1:?assert_binary_sentinel requires a binary path}"
  sentinel="${2:?assert_binary_sentinel requires a sentinel}"
  message="${3:?assert_binary_sentinel requires a message}"

  if ! grep -aFq -- "$sentinel" "$binary_path"; then
    echo "pixel_boot_build_orange_gpu: $message" >&2
    exit 1
  fi
}

assert_hello_variant() {
  local binary_path file_output
  binary_path="${1:?assert_hello_variant requires a binary path}"

  file_output="$(file "$binary_path")"
  if [[ "$file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_boot_build_orange_gpu: expected an arm64 hello-init binary, got: $file_output" >&2
    exit 1
  fi
  if [[ "$file_output" == *"dynamically linked"* ]]; then
    echo "pixel_boot_build_orange_gpu: expected a static hello-init binary, got a dynamic one: $file_output" >&2
    exit 1
  fi

  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-role:hello-init' \
    "binary is missing the hello-init role sentinel"
  if ! grep -aFq -- 'shadow-owned-init-impl:c-static' "$binary_path" && \
     ! grep -aFq -- 'shadow-owned-init-impl:rust-static' "$binary_path"; then
    echo "pixel_boot_build_orange_gpu: binary is missing a supported static hello-init implementation sentinel" >&2
    exit 1
  fi
  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-config:/shadow-init.cfg' \
    "binary is missing the expected config-path sentinel"
}

assert_rust_hello_variant() {
  local binary_path
  binary_path="${1:?assert_rust_hello_variant requires a binary path}"

  assert_hello_variant "$binary_path"
  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-impl:rust-static' \
    "binary is missing the rust-static implementation sentinel"
}

build_or_copy_rust_hello_init_binary() {
  local package_ref destination binary_name store_path
  package_ref="${1:?build_or_copy_rust_hello_init_binary requires a package ref}"
  destination="${2:?build_or_copy_rust_hello_init_binary requires a destination}"
  binary_name="${3:?build_or_copy_rust_hello_init_binary requires a binary name}"

  mkdir -p "$(dirname "$destination")"
  store_path="$(
    pixel_retry_nix_build_print_out_paths nix build --no-link --print-out-paths "$package_ref"
  )"
  cp "$store_path/bin/$binary_name" "$destination"
  chmod 0755 "$destination"
}

stage_boot_executable() {
  local source_path destination_path
  source_path="${1:?stage_boot_executable requires a source path}"
  destination_path="${2:?stage_boot_executable requires a destination path}"

  mkdir -p "$(dirname "$destination_path")"
  cp "$source_path" "$destination_path"
  chmod 0755 "$destination_path"
}

assert_static_device_binary() {
  local binary_path label file_output
  binary_path="${1:?assert_static_device_binary requires a binary path}"
  label="${2:?assert_static_device_binary requires a label}"

  file_output="$(file "$binary_path")"
  if [[ "$file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_boot_build_orange_gpu: expected an arm64 $label binary, got: $file_output" >&2
    exit 1
  fi
  if [[ "$file_output" == *"dynamically linked"* ]]; then
    echo "pixel_boot_build_orange_gpu: expected a static $label binary, got a dynamic one: $file_output" >&2
    exit 1
  fi
}

assert_dynamic_linux_device_binary() {
  local binary_path label file_output
  binary_path="${1:?assert_dynamic_linux_device_binary requires a binary path}"
  label="${2:?assert_dynamic_linux_device_binary requires a label}"

  file_output="$(file "$binary_path")"
  if [[ "$file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_boot_build_orange_gpu: expected an arm64 $label binary, got: $file_output" >&2
    exit 1
  fi
  if [[ "$file_output" != *"dynamically linked"* ]]; then
    echo "pixel_boot_build_orange_gpu: expected a dynamically linked $label binary, got: $file_output" >&2
    exit 1
  fi
}

assert_app_direct_present_client_launcher_variant() {
  local binary_path
  binary_path="${1:?assert_app_direct_present_client_launcher_variant requires a binary path}"

  assert_static_device_binary "$binary_path" "app-direct-present client launcher"
  assert_binary_sentinel \
    "$binary_path" \
    'shadow-app-direct-present-launcher-role:static-loader-exec' \
    "app-direct-present client launcher is missing the static-loader-exec role sentinel"
}

build_or_copy_static_device_binary() {
  local package_ref destination binary_name
  package_ref="${1:?build_or_copy_static_device_binary requires a package ref}"
  destination="${2:?build_or_copy_static_device_binary requires a destination}"
  binary_name="${3:?build_or_copy_static_device_binary requires a binary name}"

  build_or_copy_rust_hello_init_binary "$package_ref" "$destination" "$binary_name"
}

default_linux_build_system() {
  printf '%s\n' "${PIXEL_GUEST_BUILD_SYSTEM:-aarch64-linux}"
}

linux_device_package_ref_for_attr() {
  local attr
  attr="${1:?linux_device_package_ref_for_attr requires an attr}"
  printf '%s#packages.%s.%s\n' "$(repo_root)" "$(default_linux_build_system)" "$attr"
}

build_or_copy_linux_static_device_binary() {
  local attr destination binary_name
  attr="${1:?build_or_copy_linux_static_device_binary requires an attr}"
  destination="${2:?build_or_copy_linux_static_device_binary requires a destination}"
  binary_name="${3:?build_or_copy_linux_static_device_binary requires a binary name}"

  build_or_copy_static_device_binary \
    "$(linux_device_package_ref_for_attr "$attr")" \
    "$destination" \
    "$binary_name"
}

build_or_copy_linux_dynamic_device_binary() {
  local attr destination binary_name
  attr="${1:?build_or_copy_linux_dynamic_device_binary requires an attr}"
  destination="${2:?build_or_copy_linux_dynamic_device_binary requires a destination}"
  binary_name="${3:?build_or_copy_linux_dynamic_device_binary requires a binary name}"

  build_or_copy_rust_hello_init_binary \
    "$(linux_device_package_ref_for_attr "$attr")" \
    "$destination" \
    "$binary_name"
}

assert_orange_variant() {
  local binary_path file_output
  binary_path="${1:?assert_orange_variant requires a binary path}"

  file_output="$(file "$binary_path")"
  if [[ "$file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_boot_build_orange_gpu: expected an arm64 orange-init binary, got: $file_output" >&2
    exit 1
  fi
  if [[ "$file_output" == *"dynamically linked"* ]]; then
    echo "pixel_boot_build_orange_gpu: expected a static orange-init binary, got a dynamic one: $file_output" >&2
    exit 1
  fi

  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-role:orange-init' \
    "binary is missing the orange-init role sentinel"
  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-impl:drm-rect-device' \
    "binary is missing the drm-rect-device implementation sentinel"
  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-path:/orange-init' \
    "binary is missing the orange-init payload-path sentinel"
}

assert_gpu_bundle_variant() {
  local bundle_dir="$1"
  local loader_path binary_path loader_file_output binary_file_output

  [[ -d "$bundle_dir" ]] || {
    echo "pixel_boot_build_orange_gpu: gpu bundle dir not found: $bundle_dir" >&2
    exit 1
  }

  local required_path
  for required_path in \
    "$bundle_dir/shadow-gpu-smoke" \
    "$bundle_dir/lib" \
    "$bundle_dir/lib/ld-linux-aarch64.so.1" \
    "$bundle_dir/lib/libvulkan.so.1" \
    "$bundle_dir/lib/libvulkan_freedreno.so" \
    "$bundle_dir/share/vulkan/icd.d/freedreno_icd.aarch64.json"; do
    [[ -e "$required_path" ]] || {
      echo "pixel_boot_build_orange_gpu: missing gpu bundle path: $required_path" >&2
      exit 1
    }
  done

  loader_path="$bundle_dir/lib/ld-linux-aarch64.so.1"
  binary_path="$bundle_dir/shadow-gpu-smoke"

  [[ -x "$loader_path" ]] || {
    echo "pixel_boot_build_orange_gpu: gpu bundle loader is not executable: $loader_path" >&2
    exit 1
  }
  [[ -x "$binary_path" ]] || {
    echo "pixel_boot_build_orange_gpu: gpu bundle binary is not executable: $binary_path" >&2
    exit 1
  }

  loader_file_output="$(file "$loader_path")"
  if [[ "$loader_file_output" != *"ELF 64-bit"* || "$loader_file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_boot_build_orange_gpu: expected an aarch64 ELF loader, got: $loader_file_output" >&2
    exit 1
  fi

  binary_file_output="$(file "$binary_path")"
  if [[ "$binary_file_output" != *"ELF 64-bit"* || "$binary_file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_boot_build_orange_gpu: expected an aarch64 ELF gpu binary, got: $binary_file_output" >&2
    exit 1
  fi

}

assert_prelude_word() {
  local value
  value="${1:?assert_prelude_word requires a value}"

  case "$value" in
    none|orange-init)
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: prelude must be none or orange-init: $value" >&2
      exit 1
      ;;
  esac
}

assert_boot_mode_word() {
  local value
  value="${1:?assert_boot_mode_word requires a value}"

  case "$value" in
    lab|product)
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: boot mode must be lab or product: $value" >&2
      exit 1
      ;;
  esac
}

assert_orange_gpu_mode_word() {
  local value
  value="${1:?assert_orange_gpu_mode_word requires a value}"

  case "$value" in
    gpu-render|orange-gpu-loop|bundle-smoke|vulkan-instance-smoke|raw-vulkan-instance-smoke|firmware-probe-only|timeout-control-smoke|camera-hal-link-probe|wifi-linux-surface-probe|c-kgsl-open-readonly-smoke|c-kgsl-open-readonly-firmware-helper-smoke|c-kgsl-open-readonly-pid1-smoke|raw-kgsl-open-readonly-smoke|raw-kgsl-getproperties-smoke|raw-vulkan-physical-device-count-query-exit-smoke|raw-vulkan-physical-device-count-query-no-destroy-smoke|raw-vulkan-physical-device-count-query-smoke|raw-vulkan-physical-device-count-smoke|vulkan-enumerate-adapters-count-smoke|vulkan-enumerate-adapters-smoke|vulkan-adapter-smoke|vulkan-device-request-smoke|vulkan-device-smoke|vulkan-offscreen|compositor-scene|shell-session|shell-session-held|shell-session-runtime-touch-counter|app-direct-present|app-direct-present-touch-counter|app-direct-present-runtime-touch-counter|payload-partition-probe)
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: orange gpu mode must be gpu-render, orange-gpu-loop, bundle-smoke, vulkan-instance-smoke, raw-vulkan-instance-smoke, firmware-probe-only, timeout-control-smoke, camera-hal-link-probe, wifi-linux-surface-probe, c-kgsl-open-readonly-smoke, c-kgsl-open-readonly-firmware-helper-smoke, c-kgsl-open-readonly-pid1-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, vulkan-enumerate-adapters-count-smoke, vulkan-enumerate-adapters-smoke, vulkan-adapter-smoke, vulkan-device-request-smoke, vulkan-device-smoke, vulkan-offscreen, compositor-scene, shell-session, shell-session-held, shell-session-runtime-touch-counter, app-direct-present, app-direct-present-touch-counter, app-direct-present-runtime-touch-counter, or payload-partition-probe: $value" >&2
      exit 1
      ;;
  esac
}

assert_safe_word() {
  local label value max_length
  label="${1:?assert_safe_word requires a label}"
  value="${2:?assert_safe_word requires a value}"
  max_length="${3:?assert_safe_word requires a max length}"

  if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "pixel_boot_build_orange_gpu: unsupported $label value: $value" >&2
    exit 1
  fi
  if ((${#value} > max_length)); then
    echo "pixel_boot_build_orange_gpu: $label value exceeds max length $max_length: $value" >&2
    exit 1
  fi
}

assert_run_token() {
  local value
  value="${1:?assert_run_token requires a value}"

  if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,62}$ ]]; then
    echo "pixel_boot_build_orange_gpu: run token must be 8-63 safe characters and start with an alphanumeric character: $value" >&2
    exit 1
  fi
}

assert_config_path_value() {
  local label value
  label="${1:?assert_config_path_value requires a label}"
  value="${2:?assert_config_path_value requires a value}"

  if [[ "$value" != /* ]]; then
    echo "pixel_boot_build_orange_gpu: $label must be an absolute device path: $value" >&2
    exit 1
  fi
  python3 - "$label" "$value" <<'PY'
import sys

label, value = sys.argv[1:3]
if any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
    raise SystemExit(
        f"pixel_boot_build_orange_gpu: {label} contains control characters"
    )
parts = value.split("/")
if any(part in {"", "."} for part in parts[1:]) or ".." in parts:
    raise SystemExit(
        f"pixel_boot_build_orange_gpu: {label} must not contain empty, '.', or '..' path segments: {value}"
    )
PY
}

assert_bool_word() {
  local label value
  label="${1:?assert_bool_word requires a label}"
  value="${2:?assert_bool_word requires a value}"

  case "$value" in
    true|false)
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: $label must be true or false: $value" >&2
      exit 1
      ;;
  esac
}

assert_dev_mount_word() {
  local value
  value="${1:?assert_dev_mount_word requires a value}"

  case "$value" in
    devtmpfs|tmpfs)
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: dev-mount must be devtmpfs or tmpfs: $value" >&2
      exit 1
      ;;
  esac
}

assert_dri_bootstrap_word() {
  local value
  value="${1:?assert_dri_bootstrap_word requires a value}"

  case "$value" in
    none|sunfish-card0-renderD128|sunfish-card0-renderD128-kgsl3d0)
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: unsupported dri-bootstrap value: $value" >&2
      exit 1
      ;;
  esac
}

assert_input_bootstrap_word() {
  local value
  value="${1:?assert_input_bootstrap_word requires a value}"

  case "$value" in
    none|sunfish-touch-event2)
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: unsupported input-bootstrap value: $value" >&2
      exit 1
      ;;
  esac
}

assert_firmware_bootstrap_word() {
  local value
  value="${1:?assert_firmware_bootstrap_word requires a value}"

  case "$value" in
    none|ramdisk-lib-firmware)
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: unsupported firmware-bootstrap value: $value" >&2
      exit 1
      ;;
  esac
}

assert_timeout_action_word() {
  local value
  value="${1:?assert_timeout_action_word requires a value}"

  case "$value" in
    reboot|panic|hold)
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: unsupported orange-gpu-timeout-action value: $value" >&2
      exit 1
      ;;
  esac
}

assert_bundle_archive_source_word() {
  local value
  value="${1:?assert_bundle_archive_source_word requires a value}"

  case "$value" in
    ramdisk|shadow-logical-partition)
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: unsupported orange-gpu-bundle-archive-source value: $value" >&2
      exit 1
      ;;
  esac
}

assert_hello_init_mode_word() {
  local value
  value="${1:?assert_hello_init_mode_word requires a value}"

  case "$value" in
    direct|rust-bridge)
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: unsupported hello-init mode: $value" >&2
      exit 1
      ;;
  esac
}

assert_rust_shim_mode_word() {
  local value
  value="${1:?assert_rust_shim_mode_word requires a value}"

  case "$value" in
    fork|exec)
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: unsupported rust shim mode: $value" >&2
      exit 1
      ;;
  esac
}

assert_rust_child_profile_word() {
  local value
  value="${1:?assert_rust_child_profile_word requires a value}"

  case "$value" in
    hello|std-probe|nostd-probe)
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: unsupported rust child profile: $value" >&2
      exit 1
      ;;
  esac
}

rust_bridge_supports_orange_gpu_mode() {
  local value
  value="${1:?rust_bridge_supports_orange_gpu_mode requires a value}"

  case "$value" in
    gpu-render|orange-gpu-loop|bundle-smoke|vulkan-instance-smoke|raw-vulkan-instance-smoke|firmware-probe-only|timeout-control-smoke|camera-hal-link-probe|wifi-linux-surface-probe|c-kgsl-open-readonly-smoke|c-kgsl-open-readonly-firmware-helper-smoke|c-kgsl-open-readonly-pid1-smoke|raw-kgsl-open-readonly-smoke|raw-kgsl-getproperties-smoke|raw-vulkan-physical-device-count-query-exit-smoke|raw-vulkan-physical-device-count-query-no-destroy-smoke|raw-vulkan-physical-device-count-query-smoke|raw-vulkan-physical-device-count-smoke|vulkan-enumerate-adapters-count-smoke|vulkan-enumerate-adapters-smoke|vulkan-adapter-smoke|vulkan-device-request-smoke|vulkan-device-smoke|vulkan-offscreen|compositor-scene|shell-session|shell-session-held|shell-session-runtime-touch-counter|app-direct-present|app-direct-present-touch-counter|app-direct-present-runtime-touch-counter|payload-partition-probe)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

assert_rust_bridge_supported_config() {
  if [[ "$HELLO_INIT_MODE" != "rust-bridge" ]]; then
    return 0
  fi

  if ! rust_bridge_supports_orange_gpu_mode "$ORANGE_GPU_MODE"; then
    echo "pixel_boot_build_orange_gpu: --hello-init-mode rust-bridge does not support orange-gpu mode: $ORANGE_GPU_MODE" >&2
    exit 1
  fi
}

render_config() {
  local output_path
  output_path="${1:?render_config requires an output path}"

  cat >"$output_path" <<EOF
# Generated by pixel_boot_build_orange_gpu.sh
payload=orange-gpu
orange_gpu_mode=$ORANGE_GPU_MODE
hold_seconds=$HOLD_SECS
reboot_target=$REBOOT_TARGET
run_token=$RUN_TOKEN
EOF

  if [[ "$BOOT_MODE" != "lab" ]]; then
    printf 'boot_mode=%s\n' "$BOOT_MODE" >>"$output_path"
  fi
  if [[ "$ORANGE_GPU_LAUNCH_DELAY_SECS" != "0" ]]; then
    printf 'orange_gpu_launch_delay_secs=%s\n' "$ORANGE_GPU_LAUNCH_DELAY_SECS" >>"$output_path"
  fi
  if [[ "$ORANGE_GPU_PARENT_PROBE_ATTEMPTS" != "0" ]]; then
    printf 'orange_gpu_parent_probe_attempts=%s\n' "$ORANGE_GPU_PARENT_PROBE_ATTEMPTS" >>"$output_path"
  fi
  if [[ "$ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS" != "0" ]]; then
    printf 'orange_gpu_parent_probe_interval_secs=%s\n' "$ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS" >>"$output_path"
  fi
  if [[ "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB" == "true" ]]; then
    printf 'orange_gpu_metadata_stage_breadcrumb=%s\n' "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB" >>"$output_path"
  fi
  if [[ "$ORANGE_GPU_METADATA_PRUNE_TOKEN_ROOT" == "true" ]]; then
    printf 'orange_gpu_metadata_prune_token_root=%s\n' "$ORANGE_GPU_METADATA_PRUNE_TOKEN_ROOT" >>"$output_path"
  fi
  if payload_probe_config_enabled; then
    printf 'payload_probe_strategy=%s\n' "$PAYLOAD_PROBE_STRATEGY" >>"$output_path"
    printf 'payload_probe_source=%s\n' "$PAYLOAD_PROBE_SOURCE" >>"$output_path"
    printf 'payload_probe_root=%s\n' "$(payload_probe_root_for_token "$RUN_TOKEN")" >>"$output_path"
    printf 'payload_probe_manifest_path=%s\n' "$(payload_probe_manifest_path_for_token "$RUN_TOKEN")" >>"$output_path"
    printf 'payload_probe_fallback_path=%s\n' "$PAYLOAD_PROBE_FALLBACK_PATH" >>"$output_path"
  fi
  if [[ "$ORANGE_GPU_FIRMWARE_HELPER" == "true" ]]; then
    printf 'orange_gpu_firmware_helper=%s\n' "$ORANGE_GPU_FIRMWARE_HELPER" >>"$output_path"
  fi
  if [[ "$ORANGE_GPU_TIMEOUT_ACTION" != "reboot" ]]; then
    printf 'orange_gpu_timeout_action=%s\n' "$ORANGE_GPU_TIMEOUT_ACTION" >>"$output_path"
  fi
  if [[ "$ORANGE_GPU_WATCHDOG_TIMEOUT_SECS" != "0" ]]; then
    printf 'orange_gpu_watchdog_timeout_secs=%s\n' "$ORANGE_GPU_WATCHDOG_TIMEOUT_SECS" >>"$output_path"
  fi
  if [[ "$PRELUDE" != "none" ]]; then
    printf 'prelude=%s\n' "$PRELUDE" >>"$output_path"
    printf 'prelude_hold_seconds=%s\n' "$PRELUDE_HOLD_SECS" >>"$output_path"
  fi
  if [[ "$DEV_MOUNT" != "devtmpfs" ]]; then
    printf 'dev_mount=%s\n' "$DEV_MOUNT" >>"$output_path"
  fi
  if [[ "$MOUNT_DEV" != "true" ]]; then
    printf 'mount_dev=%s\n' "$MOUNT_DEV" >>"$output_path"
  fi
  if [[ "$MOUNT_PROC" != "true" ]]; then
    printf 'mount_proc=%s\n' "$MOUNT_PROC" >>"$output_path"
  fi
  if [[ "$MOUNT_SYS" != "true" ]]; then
    printf 'mount_sys=%s\n' "$MOUNT_SYS" >>"$output_path"
  fi
  if [[ "$LOG_KMSG" != "true" ]]; then
    printf 'log_kmsg=%s\n' "$LOG_KMSG" >>"$output_path"
  fi
  if [[ "$LOG_PMSG" != "true" ]]; then
    printf 'log_pmsg=%s\n' "$LOG_PMSG" >>"$output_path"
  fi
  if [[ "$FIRMWARE_BOOTSTRAP" != "none" ]]; then
    printf 'firmware_bootstrap=%s\n' "$FIRMWARE_BOOTSTRAP" >>"$output_path"
  fi
  if [[ "$INPUT_BOOTSTRAP" != "none" ]]; then
    printf 'input_bootstrap=%s\n' "$INPUT_BOOTSTRAP" >>"$output_path"
  fi
  if [[ "$WIFI_BOOTSTRAP" != "none" ]]; then
    printf 'wifi_bootstrap=%s\n' "$WIFI_BOOTSTRAP" >>"$output_path"
  fi
  if [[ "$WIFI_BOOTSTRAP" == "sunfish-wlan0" || "$WIFI_HELPER_PROFILE_EXPLICIT" == "1" ]]; then
    printf 'wifi_helper_profile=%s\n' "$WIFI_HELPER_PROFILE" >>"$output_path"
  fi
  if [[ "$WIFI_SUPPLICANT_PROBE" != "true" ]]; then
    printf 'wifi_supplicant_probe=%s\n' "$WIFI_SUPPLICANT_PROBE" >>"$output_path"
  fi
  if [[ "$WIFI_ASSOCIATION_PROBE" != "false" ]]; then
    printf 'wifi_association_probe=%s\n' "$WIFI_ASSOCIATION_PROBE" >>"$output_path"
  fi
  if [[ "$WIFI_IP_PROBE" != "false" ]]; then
    printf 'wifi_ip_probe=%s\n' "$WIFI_IP_PROBE" >>"$output_path"
  fi
  if [[ "$WIFI_RUNTIME_NETWORK" != "false" ]]; then
    printf 'wifi_runtime_network=%s\n' "$WIFI_RUNTIME_NETWORK" >>"$output_path"
  fi
  if [[ -n "$WIFI_RUNTIME_CLOCK_UNIX_SECS" ]]; then
    printf 'wifi_runtime_clock_unix_secs=%s\n' "$WIFI_RUNTIME_CLOCK_UNIX_SECS" >>"$output_path"
  fi
  if [[ -n "$WIFI_CREDENTIALS_PATH" ]]; then
    printf 'wifi_credentials_path=%s\n' "$WIFI_CREDENTIALS_PATH" >>"$output_path"
  fi
  if [[ "$WIFI_IP_PROBE" == "true" || "$WIFI_RUNTIME_NETWORK" == "true" ]]; then
    printf 'wifi_dhcp_client_path=/orange-gpu/busybox\n' >>"$output_path"
  fi
  if [[ -n "$STAGED_GPU_BUNDLE_ARCHIVE" ]]; then
    printf 'orange_gpu_bundle_archive_path=%s\n' "$ORANGE_GPU_BUNDLE_ARCHIVE_PATH" >>"$output_path"
  fi
  if [[ "$ORANGE_GPU_MODE" == "camera-hal-link-probe" ]]; then
    printf 'camera_hal_camera_id=%s\n' "$CAMERA_HAL_CAMERA_ID" >>"$output_path"
    printf 'camera_hal_call_open=%s\n' "$CAMERA_HAL_CALL_OPEN" >>"$output_path"
  fi
  if [[ "$ORANGE_GPU_MODE" == "shell-session" || "$ORANGE_GPU_MODE" == "shell-session-held" || "$ORANGE_GPU_MODE" == "shell-session-runtime-touch-counter" ]]; then
    printf 'shell_session_start_app_id=%s\n' "$SHELL_SESSION_START_APP_ID" >>"$output_path"
    if [[ -n "$SHELL_SESSION_APP_PROFILE" ]]; then
      printf 'shell_session_app_profile=%s\n' "$SHELL_SESSION_APP_PROFILE" >>"$output_path"
    fi
  fi
  if [[ "$ORANGE_GPU_MODE" == "shell-session" || "$ORANGE_GPU_MODE" == "shell-session-held" || "$ORANGE_GPU_MODE" == "shell-session-runtime-touch-counter" || "$ORANGE_GPU_MODE" == "app-direct-present" || "$ORANGE_GPU_MODE" == "app-direct-present-runtime-touch-counter" ]]; then
    printf 'app_direct_present_app_id=%s\n' "$APP_DIRECT_PRESENT_APP_ID" >>"$output_path"
    if [[ -n "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV" ]]; then
      printf 'app_direct_present_runtime_bundle_env=%s\n' "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV" >>"$output_path"
      printf 'app_direct_present_runtime_bundle_path=%s\n' "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_PATH" >>"$output_path"
    fi
  fi
  if [[ "$APP_DIRECT_PRESENT_MANUAL_TOUCH" == "true" && "$ORANGE_GPU_MODE" =~ ^(shell-session-held|shell-session-runtime-touch-counter|app-direct-present|app-direct-present-touch-counter|app-direct-present-runtime-touch-counter)$ ]]; then
    printf 'app_direct_present_manual_touch=%s\n' "$APP_DIRECT_PRESENT_MANUAL_TOUCH" >>"$output_path"
  fi
  printf 'dri_bootstrap=%s\n' "$DRI_BOOTSTRAP" >>"$output_path"
}

render_compositor_scene_startup_config() {
  local output_path
  output_path="${1:?render_compositor_scene_startup_config requires an output path}"

  python3 - \
    "$output_path" \
    "$COMPOSITOR_SCENE_RUNTIME_DIR" \
    "$COMPOSITOR_SCENE_DUMMY_CLIENT_PATH" \
    "$(metadata_compositor_frame_path_for_token "$RUN_TOKEN")" <<'PY'
import json
import sys
from pathlib import Path

output_path, runtime_dir, app_client_path, frame_artifact_path = sys.argv[1:5]
payload = {
    "schemaVersion": 1,
    "startup": {"mode": "shell"},
    "client": {
        "appClientPath": app_client_path,
        "runtimeDir": runtime_dir,
        "lingerMs": 500,
    },
    "compositor": {
        "transport": "direct",
        "enableDrm": True,
        "exitOnFirstFrame": True,
        "frameCapture": {
            "mode": "first-frame",
            "artifactPath": frame_artifact_path,
            "checksum": True,
        },
    },
}
Path(output_path).write_text(
    json.dumps(payload, indent=2, sort_keys=False) + "\n",
    encoding="utf-8",
)
PY
}

render_compositor_scene_dummy_client() {
  local output_path
  output_path="${1:?render_compositor_scene_dummy_client requires an output path}"

  cat >"$output_path" <<'EOF'
#!/system/bin/sh
exit 0
EOF
  chmod 0755 "$output_path"
}

render_shell_session_rust_app_launcher() {
  local output_path loader_path library_path app_binary_path
  output_path="${1:?render_shell_session_rust_app_launcher requires an output path}"
  loader_path="${2:?render_shell_session_rust_app_launcher requires a loader path}"
  library_path="${3:?render_shell_session_rust_app_launcher requires a library path}"
  app_binary_path="${4:?render_shell_session_rust_app_launcher requires an app binary path}"

  python3 - \
    "$output_path" \
    "$loader_path" \
    "$library_path" \
    "$app_binary_path" \
    "$APP_DIRECT_PRESENT_BUNDLE_ROOT_PATH" <<'PY'
import shlex
import sys
from pathlib import Path

output_path, loader_path, library_path, app_binary_path, bundle_root = sys.argv[1:6]
home = f"{bundle_root}/home"
cache_home = f"{home}/.cache"
config_home = f"{home}/.config"

script = f"""#!/system/bin/sh
set -eu
if [ -z "${{HOME:-}}" ]; then
  HOME={shlex.quote(home)}
  export HOME
fi
if [ -z "${{XDG_CACHE_HOME:-}}" ]; then
  XDG_CACHE_HOME={shlex.quote(cache_home)}
  export XDG_CACHE_HOME
fi
if [ -z "${{XDG_CONFIG_HOME:-}}" ]; then
  XDG_CONFIG_HOME={shlex.quote(config_home)}
  export XDG_CONFIG_HOME
fi
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" 2>/dev/null || true
if [ -z "${{SHADOW_RUNTIME_CAMERA_ALLOW_MOCK:-}}" ]; then
  SHADOW_RUNTIME_CAMERA_ALLOW_MOCK=1
  export SHADOW_RUNTIME_CAMERA_ALLOW_MOCK
fi
if [ -n "${{LD_LIBRARY_PATH:-}}" ]; then
  LD_LIBRARY_PATH={shlex.quote(library_path)}:"$LD_LIBRARY_PATH"
else
  LD_LIBRARY_PATH={shlex.quote(library_path)}
fi
case ":$LD_LIBRARY_PATH:" in
  *:/orange-gpu/lib:*) ;;
  *) LD_LIBRARY_PATH="$LD_LIBRARY_PATH":/orange-gpu/lib ;;
esac
export LD_LIBRARY_PATH
exec {shlex.quote(loader_path)} --library-path "$LD_LIBRARY_PATH" {shlex.quote(app_binary_path)} "$@"
"""

Path(output_path).write_text(script, encoding="utf-8")
PY
  chmod 0755 "$output_path"
}

render_shell_session_typescript_app_launcher() {
  local output_path launcher_path loader_path library_path app_binary_path system_binary_path
  output_path="${1:?render_shell_session_typescript_app_launcher requires an output path}"
  launcher_path="${2:?render_shell_session_typescript_app_launcher requires a launcher path}"
  loader_path="${3:?render_shell_session_typescript_app_launcher requires a loader path}"
  library_path="${4:?render_shell_session_typescript_app_launcher requires a library path}"
  app_binary_path="${5:?render_shell_session_typescript_app_launcher requires an app binary path}"
  system_binary_path="${6:?render_shell_session_typescript_app_launcher requires a system binary path}"

  python3 - \
    "$output_path" \
    "$launcher_path" \
    "$loader_path" \
    "$library_path" \
    "$app_binary_path" \
    "$system_binary_path" <<'PY'
import shlex
import sys
from pathlib import Path

(
    output_path,
    launcher_path,
    loader_path,
    library_path,
    app_binary_path,
    system_binary_path,
) = sys.argv[1:7]

script = f"""#!/system/bin/sh
set -eu
SHADOW_APP_DIRECT_PRESENT_BINARY_PATH={shlex.quote(app_binary_path)}
SHADOW_APP_DIRECT_PRESENT_LOADER_PATH={shlex.quote(loader_path)}
SHADOW_APP_DIRECT_PRESENT_LIBRARY_PATH={shlex.quote(library_path)}
SHADOW_SYSTEM_STAGE_LOADER_PATH={shlex.quote(loader_path)}
SHADOW_SYSTEM_STAGE_LIBRARY_PATH={shlex.quote(library_path)}
SHADOW_SYSTEM_BINARY_PATH={shlex.quote(system_binary_path)}
export SHADOW_APP_DIRECT_PRESENT_BINARY_PATH
export SHADOW_APP_DIRECT_PRESENT_LOADER_PATH
export SHADOW_APP_DIRECT_PRESENT_LIBRARY_PATH
export SHADOW_SYSTEM_STAGE_LOADER_PATH
export SHADOW_SYSTEM_STAGE_LIBRARY_PATH
export SHADOW_SYSTEM_BINARY_PATH
exec {shlex.quote(launcher_path)} "$@"
"""

Path(output_path).write_text(script, encoding="utf-8")
PY
  chmod 0755 "$output_path"
}

render_app_direct_present_startup_config() {
  local output_path
  output_path="${1:?render_app_direct_present_startup_config requires an output path}"

  python3 - \
    "$output_path" \
    "$APP_DIRECT_PRESENT_RUNTIME_DIR" \
    "$APP_DIRECT_PRESENT_CLIENT_PATH" \
    "$APP_DIRECT_PRESENT_APP_ID" \
    "$APP_DIRECT_PRESENT_CLIENT_KIND" \
    "$APP_DIRECT_PRESENT_BINARY_PATH" \
    "$APP_DIRECT_PRESENT_STAGE_LOADER_PATH" \
    "$APP_DIRECT_PRESENT_STAGE_LIBRARY_PATH" \
    "$APP_DIRECT_PRESENT_SYSTEM_BINARY_PATH" \
    "$ORANGE_GPU_ENABLE_LINUX_AUDIO" \
    "$ORANGE_GPU_AUDIO_BINARY_PATH" \
    "$APP_DIRECT_PRESENT_BUNDLE_ROOT_PATH" \
    "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV" \
    "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_PATH" \
    "$APP_DIRECT_PRESENT_STARTUP_CONFIG_PATH" \
    "$ORANGE_GPU_MODE" \
    "$(metadata_compositor_frame_path_for_token "$RUN_TOKEN")" \
    "$APP_DIRECT_PRESENT_MANUAL_TOUCH" <<'PY'
import json
import sys
from pathlib import Path

(
    output_path,
    runtime_dir,
    client_path,
    app_id,
    client_kind,
    app_binary_path,
    stage_loader_path,
    stage_library_path,
    system_binary_path,
    enable_audio_value,
    audio_bridge_binary_path,
    runtime_bundle_dir,
    runtime_bundle_env,
    runtime_bundle_path,
    runtime_session_config_path,
    orange_gpu_mode,
    frame_artifact_path,
    manual_touch_value,
) = sys.argv[1:19]
touch_counter_mode = orange_gpu_mode in {
    "app-direct-present-touch-counter",
    "app-direct-present-runtime-touch-counter",
}
manual_touch_mode = manual_touch_value.lower() in {"1", "true", "yes", "on"}
interactive_touch_mode = touch_counter_mode or manual_touch_mode
env_assignments = []
if client_kind == "rust":
    env_assignments.extend(
        [
            {
                "key": "SHADOW_APP_DIRECT_PRESENT_BINARY_PATH",
                "value": app_binary_path,
            },
            {
                "key": "SHADOW_APP_DIRECT_PRESENT_LOADER_PATH",
                "value": stage_loader_path,
            },
            {
                "key": "SHADOW_APP_DIRECT_PRESENT_LIBRARY_PATH",
                "value": stage_library_path,
            },
            {
                "key": "SHADOW_RUNTIME_SESSION_CONFIG",
                "value": runtime_session_config_path,
            },
        ]
    )
elif client_kind == "typescript":
    env_assignments.extend(
        [
            {
                "key": "SHADOW_APP_DIRECT_PRESENT_BINARY_PATH",
                "value": app_binary_path,
            },
            {
                "key": "SHADOW_APP_DIRECT_PRESENT_LOADER_PATH",
                "value": stage_loader_path,
            },
            {
                "key": "SHADOW_APP_DIRECT_PRESENT_LIBRARY_PATH",
                "value": stage_library_path,
            },
            {
                "key": "SHADOW_SYSTEM_STAGE_LOADER_PATH",
                "value": stage_loader_path,
            },
            {
                "key": "SHADOW_SYSTEM_STAGE_LIBRARY_PATH",
                "value": stage_library_path,
            },
            {
                "key": "SHADOW_RUNTIME_SESSION_CONFIG",
                "value": runtime_session_config_path,
            },
        ]
    )
    if runtime_bundle_env and runtime_bundle_path:
        env_assignments.append({"key": runtime_bundle_env, "value": runtime_bundle_path})
    if orange_gpu_mode == "app-direct-present-runtime-touch-counter":
        env_assignments.append(
            {
                "key": "SHADOW_BLITZ_TOUCH_ANYWHERE_TARGET",
                "value": app_id,
            }
        )
    if enable_audio_value == "true":
        env_assignments.extend(
            [
                {
                    "key": "SHADOW_RUNTIME_AUDIO_BRIDGE_BINARY",
                    "value": audio_bridge_binary_path,
                },
                {
                    "key": "SHADOW_RUNTIME_AUDIO_BRIDGE_STAGE_LOADER_PATH",
                    "value": stage_loader_path,
                },
                {
                    "key": "SHADOW_RUNTIME_AUDIO_BRIDGE_STAGE_LIBRARY_PATH",
                    "value": stage_library_path,
                },
                {"key": "SHADOW_RUNTIME_AUDIO_BACKEND", "value": "linux_bridge"},
                {"key": "ALSA_CONFIG_PATH", "value": "/orange-gpu/share/alsa/alsa.conf"},
                {"key": "ALSA_CONFIG_DIR", "value": "/orange-gpu/share/alsa"},
                {"key": "ALSA_CONFIG_UCM", "value": "/orange-gpu/share/alsa/ucm"},
                {"key": "ALSA_CONFIG_UCM2", "value": "/orange-gpu/share/alsa/ucm2"},
                {"key": "ALSA_PLUGIN_DIR", "value": "/orange-gpu/lib/alsa-lib"},
                {"key": "SHADOW_RUNTIME_BUNDLE_DIR", "value": runtime_bundle_dir},
            ]
        )
else:
    raise SystemExit(f"unsupported app-direct-present client kind: {client_kind}")
client = {
    "appClientPath": client_path,
    "runtimeDir": runtime_dir,
}
if system_binary_path:
    client["systemBinaryPath"] = system_binary_path
if env_assignments:
    client["envAssignments"] = env_assignments
client["lingerMs"] = 500
payload = {
    "schemaVersion": 1,
    "startup": {"mode": "app", "startAppId": app_id},
    "client": client,
    "compositor": {
        "transport": "direct",
        "enableDrm": True,
        "exitOnFirstFrame": not interactive_touch_mode,
        "frameCapture": {
            "mode": "every-frame" if interactive_touch_mode else "first-frame",
            "artifactPath": frame_artifact_path,
            "checksum": True,
        },
    },
}
if interactive_touch_mode:
    touch = {"latencyTrace": True}
    if touch_counter_mode and not manual_touch_mode:
        touch["syntheticTap"] = {
            "normalizedXMillis": 500,
            "normalizedYMillis": 500,
            "afterFirstFrameDelayMs": 250,
            "holdMs": 50,
        }
    if touch_counter_mode:
        touch["exitAfterPresent"] = True
    payload["touch"] = touch
services = {}
if enable_audio_value == "true":
    services["audioBackend"] = "linux_bridge"
if client_kind == "rust":
    services["camera"] = {"allowMock": True}
if client_kind in {"rust", "typescript"}:
    services.update(
        {
            "cashuDataDir": f"{runtime_dir}/runtime-cashu",
            "nostrDbPath": f"{runtime_dir}/runtime-nostr.sqlite3",
            "nostrServiceSocket": f"{runtime_dir}/runtime-nostr.sock",
        }
    )
if services:
    payload["services"] = services
Path(output_path).write_text(
    json.dumps(payload, indent=2, sort_keys=False) + "\n",
    encoding="utf-8",
)
PY
}

render_shell_session_startup_config() {
  local output_path extra_env_json
  output_path="${1:?render_shell_session_startup_config requires an output path}"
  extra_env_json="$(
    printf '%s\n' "${SHELL_SESSION_EXTRA_ENV_ASSIGNMENTS[@]}" | python3 -c '
import json
import sys

entries = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    key, _, value = line.partition("=")
    if key:
        entries.append({"key": key, "value": value})
print(json.dumps(entries, separators=(",", ":")))
'
  )"

  python3 - \
    "$output_path" \
    "$APP_DIRECT_PRESENT_RUNTIME_DIR" \
    "$APP_DIRECT_PRESENT_CLIENT_PATH" \
    "$SHELL_SESSION_START_APP_ID" \
    "$APP_DIRECT_PRESENT_CLIENT_KIND" \
    "$APP_DIRECT_PRESENT_BINARY_PATH" \
    "$APP_DIRECT_PRESENT_STAGE_LOADER_PATH" \
    "$APP_DIRECT_PRESENT_STAGE_LIBRARY_PATH" \
    "$APP_DIRECT_PRESENT_SYSTEM_BINARY_PATH" \
    "$ORANGE_GPU_ENABLE_LINUX_AUDIO" \
    "$ORANGE_GPU_AUDIO_BINARY_PATH" \
    "$APP_DIRECT_PRESENT_BUNDLE_ROOT_PATH" \
    "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV" \
    "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_PATH" \
    "$SHELL_SESSION_STARTUP_CONFIG_PATH" \
    "$(metadata_compositor_frame_path_for_token "$RUN_TOKEN")" \
    "$BOOT_MODE" \
    "$ORANGE_GPU_MODE" \
    "$APP_DIRECT_PRESENT_MANUAL_TOUCH" \
    "$SHELL_SESSION_APP_PROFILE" \
    "$SHELL_SESSION_STARTUP_CONFIG_PATH" \
    "$extra_env_json" <<'PY'
import json
import sys
from pathlib import Path

(
    output_path,
    runtime_dir,
    client_path,
    start_app_id,
    client_kind,
    app_binary_path,
    stage_loader_path,
    stage_library_path,
    system_binary_path,
    enable_audio_value,
    audio_bridge_binary_path,
    runtime_bundle_dir,
    runtime_bundle_env,
    runtime_bundle_path,
    runtime_session_config_path,
    frame_artifact_path,
    boot_mode,
    orange_gpu_mode,
    manual_touch_value,
    session_app_profile,
    session_config_path,
    extra_env_json,
) = sys.argv[1:23]
product_mode = boot_mode == "product"
touch_counter_mode = orange_gpu_mode == "shell-session-runtime-touch-counter"
held_mode = orange_gpu_mode == "shell-session-held"
manual_touch_mode = manual_touch_value.lower() in {"1", "true", "yes", "on"}
env_assignments = []
if client_kind == "rust":
    env_assignments.extend(
        [
            {
                "key": "SHADOW_APP_DIRECT_PRESENT_BINARY_PATH",
                "value": app_binary_path,
            },
            {
                "key": "SHADOW_APP_DIRECT_PRESENT_LOADER_PATH",
                "value": stage_loader_path,
            },
            {
                "key": "SHADOW_APP_DIRECT_PRESENT_LIBRARY_PATH",
                "value": stage_library_path,
            },
            {
                "key": "SHADOW_RUNTIME_SESSION_CONFIG",
                "value": session_config_path,
            },
        ]
    )
elif client_kind == "typescript":
    env_assignments.extend(
        [
            {
                "key": "SHADOW_APP_DIRECT_PRESENT_BINARY_PATH",
                "value": app_binary_path,
            },
            {
                "key": "SHADOW_APP_DIRECT_PRESENT_LOADER_PATH",
                "value": stage_loader_path,
            },
            {
                "key": "SHADOW_APP_DIRECT_PRESENT_LIBRARY_PATH",
                "value": stage_library_path,
            },
            {
                "key": "SHADOW_SYSTEM_STAGE_LOADER_PATH",
                "value": stage_loader_path,
            },
            {
                "key": "SHADOW_SYSTEM_STAGE_LIBRARY_PATH",
                "value": stage_library_path,
            },
            {
                "key": "SHADOW_RUNTIME_SESSION_CONFIG",
                "value": session_config_path,
            },
        ]
    )
    if runtime_bundle_env and runtime_bundle_path:
        env_assignments.append({"key": runtime_bundle_env, "value": runtime_bundle_path})
    if touch_counter_mode:
        env_assignments.append(
            {
                "key": "SHADOW_BLITZ_TOUCH_ANYWHERE_TARGET",
                "value": start_app_id,
            }
        )
    if enable_audio_value == "true":
        env_assignments.extend(
            [
                {
                    "key": "SHADOW_RUNTIME_AUDIO_BRIDGE_BINARY",
                    "value": audio_bridge_binary_path,
                },
                {
                    "key": "SHADOW_RUNTIME_AUDIO_BRIDGE_STAGE_LOADER_PATH",
                    "value": stage_loader_path,
                },
                {
                    "key": "SHADOW_RUNTIME_AUDIO_BRIDGE_STAGE_LIBRARY_PATH",
                    "value": stage_library_path,
                },
                {"key": "SHADOW_RUNTIME_AUDIO_BACKEND", "value": "linux_bridge"},
                {
                    "key": "SHADOW_RUNTIME_SESSION_CONFIG",
                    "value": runtime_session_config_path,
                },
                {"key": "ALSA_CONFIG_PATH", "value": "/orange-gpu/share/alsa/alsa.conf"},
                {"key": "ALSA_CONFIG_DIR", "value": "/orange-gpu/share/alsa"},
                {"key": "ALSA_CONFIG_UCM", "value": "/orange-gpu/share/alsa/ucm"},
                {"key": "ALSA_CONFIG_UCM2", "value": "/orange-gpu/share/alsa/ucm2"},
                {"key": "ALSA_PLUGIN_DIR", "value": "/orange-gpu/lib/alsa-lib"},
                {"key": "SHADOW_RUNTIME_BUNDLE_DIR", "value": runtime_bundle_dir},
            ]
        )
else:
    raise SystemExit(f"unsupported shell-session client kind: {client_kind}")
env_assignments.extend(json.loads(extra_env_json or "[]"))
client = {
    "appClientPath": client_path,
    "runtimeDir": runtime_dir,
}
if system_binary_path:
    client["systemBinaryPath"] = system_binary_path
if env_assignments:
    client["envAssignments"] = env_assignments
client["lingerMs"] = 500
payload = {
    "schemaVersion": 1,
    "startup": {"mode": "shell", "shellStartAppId": start_app_id},
    "client": client,
    "compositor": {
        "transport": "direct",
        "enableDrm": True,
        "gpuShell": True,
        "strictGpuResident": True,
        "dmabufGlobalEnabled": True,
        "dmabufFeedbackEnabled": True,
        "exitOnFirstFrame": False
        if product_mode
        else not touch_counter_mode and not held_mode,
    },
}
if not product_mode:
    payload["compositor"]["frameCapture"] = {
        "mode": "every-frame",
        "artifactPath": frame_artifact_path,
        "checksum": True,
    }
if session_app_profile:
    payload["session"] = {
        "launchEnvAssignments": [
            {
                "key": "SHADOW_SESSION_APP_PROFILE",
                "value": session_app_profile,
            }
        ]
    }
if touch_counter_mode or (
    held_mode and client_kind == "typescript" and start_app_id == "counter"
):
    touch = {"latencyTrace": True}
    if not manual_touch_mode:
        touch["syntheticTap"] = {
            "normalizedXMillis": 500,
            "normalizedYMillis": 500,
            "afterFirstFrameDelayMs": 250,
            "holdMs": 50,
            "afterAppId": start_app_id,
        }
    touch["exitAfterPresent"] = touch_counter_mode
    payload["touch"] = touch
if enable_audio_value == "true":
    services = {
        "audioBackend": "linux_bridge",
    }
else:
    services = {}
if session_app_profile == "boot-shell-demo":
    services["camera"] = {"allowMock": True}
services.update(
    {
        "cashuDataDir": f"{runtime_dir}/runtime-cashu",
        "nostrDbPath": f"{runtime_dir}/runtime-nostr.sqlite3",
        "nostrServiceSocket": f"{runtime_dir}/runtime-nostr.sock",
    }
)
payload["services"] = services
Path(output_path).write_text(
    json.dumps(payload, indent=2, sort_keys=False) + "\n",
    encoding="utf-8",
)
PY
}

assert_startup_client_paths_staged() {
  local bundle_dir startup_config
  bundle_dir="${1:?assert_startup_client_paths_staged requires a bundle dir}"
  startup_config="${2:?assert_startup_client_paths_staged requires a startup config}"

  python3 - "$bundle_dir" "$startup_config" "$PAYLOAD_IMAGE_PATH" <<'PY'
import json
import os
import sys
from pathlib import Path

bundle_dir = Path(sys.argv[1])
startup_config = Path(sys.argv[2])
payload_image_path = sys.argv[3].rstrip("/")
prefix = f"{payload_image_path}/"
payload = json.loads(startup_config.read_text(encoding="utf-8"))
client = payload.get("client") or {}
paths = []

def append_path(label, value):
    if isinstance(value, str) and value:
        paths.append((label, value))

append_path("client.appClientPath", client.get("appClientPath"))
for index, assignment in enumerate(client.get("envAssignments") or []):
    if not isinstance(assignment, dict):
        continue
    key = assignment.get("key")
    if isinstance(key, str) and key.startswith("SHADOW_APP_CLIENT_"):
        append_path(f"client.envAssignments[{index}].{key}", assignment.get("value"))

missing = []
for label, image_path in paths:
    if not image_path.startswith(prefix):
        continue
    candidate = bundle_dir / image_path[len(prefix):]
    if not candidate.is_file():
        missing.append(f"{label}={image_path} missing {candidate}")
    elif not os.access(candidate, os.X_OK):
        missing.append(f"{label}={image_path} not executable at {candidate}")

if missing:
    raise SystemExit(
        "pixel_boot_build_orange_gpu: startup client path is not staged:\n"
        + "\n".join(missing)
    )
PY
}

assert_built_boot_image_init_payload() {
  local unpack_dir ramdisk_cpio

  [[ "$HELLO_INIT_MODE" == "rust-bridge" ]] || return 0
  [[ -z "${MOCK_BOOT_RAMDISK:-}" ]] || return 0

  unpack_dir="$WORK_DIR/output-unpacked"
  ramdisk_cpio="$WORK_DIR/output-ramdisk.cpio"
  rm -rf "$unpack_dir"
  bootimg_unpack_to_dir "$OUTPUT_IMAGE" "$unpack_dir"
  bootimg_decompress_ramdisk "$unpack_dir/out/ramdisk" "$ramdisk_cpio" >/dev/null

  PYTHONPATH="$SCRIPT_DIR/lib" python3 - \
    "$ramdisk_cpio" \
    "system/bin/init=$HELLO_INIT_RUST_SHIM_BINARY" \
    "$HELLO_INIT_RUST_CHILD_ENTRY=$HELLO_INIT_BINARY" <<'PY'
import hashlib
import sys
from pathlib import Path

from cpio_edit import read_cpio

ramdisk_cpio = Path(sys.argv[1])
entries = {entry.name: entry for entry in read_cpio(ramdisk_cpio).without_trailer()}
errors = []

for spec in sys.argv[2:]:
    entry_name, _, source_raw = spec.partition("=")
    source_path = Path(source_raw)
    entry = entries.get(entry_name)
    if entry is None:
        errors.append(f"{entry_name}: missing from built ramdisk")
        continue
    source = source_path.read_bytes()
    if entry.data != source:
        entry_hash = hashlib.sha256(entry.data).hexdigest()
        source_hash = hashlib.sha256(source).hexdigest()
        errors.append(
            f"{entry_name}: built ramdisk content does not match {source_path} "
            f"(ramdisk size={len(entry.data)} sha256={entry_hash}; "
            f"source size={len(source)} sha256={source_hash})"
        )

if errors:
    raise SystemExit(
        "pixel_boot_build_orange_gpu: built rust-bridge init payload mismatch:\n"
        + "\n".join(errors)
    )
PY
}

stage_app_direct_present_runtime_libs() {
  local package_out_path output_dir bundle_lib_dir
  package_out_path="${1:?stage_app_direct_present_runtime_libs requires a package output path}"
  output_dir="${2:?stage_app_direct_present_runtime_libs requires an output dir}"
  bundle_lib_dir="$output_dir/lib"

  copy_runtime_named_libs_from_package_output \
    "$package_out_path" \
    "$bundle_lib_dir" \
    libwayland-client.so.0 \
    libwayland-cursor.so.0 \
    libwayland-egl.so.1 \
    libxkbcommon.so.0 \
    libffi.so.8
  fill_linux_bundle_runtime_deps "$output_dir"
}

stage_orange_gpu_audio_bridge_bundle() {
  local bundle_dir
  bundle_dir="${1:?stage_orange_gpu_audio_bridge_bundle requires a bundle dir}"

  [[ "$ORANGE_GPU_ENABLE_LINUX_AUDIO" == "true" ]] || return 0
  if [[ "$APP_DIRECT_PRESENT_CLIENT_KIND" != "typescript" ]]; then
    echo "pixel_boot_build_orange_gpu: Linux audio bridge boot packaging requires a TypeScript runtime app, got $APP_DIRECT_PRESENT_CLIENT_KIND" >&2
    exit 1
  fi

  pixel_retry_nix_build nix build --accept-flake-config "$ORANGE_GPU_AUDIO_PACKAGE_REF" --out-link "$ORANGE_GPU_AUDIO_OUT_LINK"
  cp "$ORANGE_GPU_AUDIO_OUT_LINK/bin/$ORANGE_GPU_AUDIO_BINARY_NAME" "$bundle_dir/$ORANGE_GPU_AUDIO_BINARY_NAME"
  chmod 0755 "$bundle_dir/$ORANGE_GPU_AUDIO_BINARY_NAME"
  append_runtime_closure_from_package_ref "$ORANGE_GPU_AUDIO_PACKAGE_REF"
  fill_linux_bundle_runtime_deps "$bundle_dir"
  copy_closure_dir_into_bundle "share/alsa" "$bundle_dir/share/alsa"
  mkdir -p "$bundle_dir/lib/alsa-lib"
  copy_closure_dir_into_bundle "lib/alsa-lib" "$bundle_dir/lib/alsa-lib" optional
}

stage_app_direct_present_rust_bundle() {
  local output_dir app_package_ref app_out_link
  output_dir="${1:?stage_app_direct_present_rust_bundle requires an output dir}"

  app_package_ref="$(repo_root)#packages.${PIXEL_GUEST_BUILD_SYSTEM:-aarch64-linux}.$APP_DIRECT_PRESENT_BINARY_NAME"
  app_out_link="$(pixel_dir)/$APP_DIRECT_PRESENT_BINARY_NAME-aarch64-linux-result"
  stage_system_linux_bundle \
    "$app_package_ref" \
    "$app_out_link" \
    "$output_dir" \
    "$APP_DIRECT_PRESENT_BINARY_NAME"
  stage_app_direct_present_runtime_libs "$app_out_link" "$output_dir"
}

strip_staged_elf_files() {
  local bundle_dir path
  bundle_dir="${1:?strip_staged_elf_files requires a bundle dir}"

  command -v llvm-strip >/dev/null 2>&1 || return 0
  while IFS= read -r path; do
    [[ -f "$path" ]] || continue
    is_elf_file "$path" || continue
    chmod u+w "$path" 2>/dev/null || true
    llvm-strip "$path" 2>/dev/null || true
  done < <(find "$bundle_dir" -type f -print)
}

strip_app_direct_present_elf_files() {
  strip_staged_elf_files "${1:?strip_app_direct_present_elf_files requires a bundle dir}"
}

merge_app_direct_present_typescript_runtime_libs() {
  local bundle_dir app_lib_dir root_lib_dir
  bundle_dir="${1:?merge_app_direct_present_typescript_runtime_libs requires a bundle dir}"

  [[ "$APP_DIRECT_PRESENT_CLIENT_KIND" == "typescript" ]] || return 0

  app_lib_dir="$bundle_dir/$APP_DIRECT_PRESENT_BUNDLE_DIR_NAME/lib"
  root_lib_dir="$bundle_dir/lib"
  if [[ ! -d "$app_lib_dir" ]] || [[ -z "$(find "$app_lib_dir" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
    echo "pixel_boot_build_orange_gpu: app-direct-present TypeScript library dir missing from staged bundle" >&2
    exit 1
  fi

  mkdir -p "$root_lib_dir"
  chmod -R u+w "$root_lib_dir" 2>/dev/null || true
  cp -R "$app_lib_dir"/. "$root_lib_dir"/
  chmod -R u+w "$app_lib_dir" 2>/dev/null || true
  rm -rf "$app_lib_dir"
}

prune_app_direct_present_diagnostic_payloads() {
  local bundle_dir
  bundle_dir="${1:?prune_app_direct_present_diagnostic_payloads requires a bundle dir}"

  rm -f "$bundle_dir/shadow-gpu-smoke"
}

archive_app_direct_present_gpu_bundle() {
  local bundle_dir archive_path
  bundle_dir="${1:?archive_app_direct_present_gpu_bundle requires a bundle dir}"
  archive_path="${2:?archive_app_direct_present_gpu_bundle requires an archive path}"

  mkdir -p "$(dirname "$archive_path")"
  tar -C "$bundle_dir" -cf - . | xz -9 -e -c >"$archive_path"
  chmod 0644 "$archive_path"
}

stage_app_direct_present_typescript_bundle() {
  local output_dir bundle_json bundle_source_path
  local bundle_source_dir
  local blitz_package_ref blitz_out_link blitz_stage_dir
  local system_package_ref system_out_link system_stage_dir
  local runtime_app_env_prefix cache_env_name runtime_profile
  output_dir="${1:?stage_app_direct_present_typescript_bundle requires an output dir}"
  runtime_app_env_prefix="$(app_direct_present_runtime_app_env_prefix)"
  runtime_profile="$(runtime_build_profile_for_shell_session)"
  cache_env_name="$(runtime_cache_env_name_for_profile "$runtime_profile" "$runtime_app_env_prefix")"

  bundle_json="$(
    env "$cache_env_name=$APP_DIRECT_PRESENT_TS_CACHE_DIR" \
      "$SCRIPT_DIR/runtime_build_artifacts.sh" \
        --profile "$runtime_profile" \
        --include-app "$APP_DIRECT_PRESENT_APP_ID"
  )"
  printf '%s\n' "$bundle_json"
  bundle_source_path="$(
    printf '%s\n' "$bundle_json" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
app_id = sys.argv[1]
print(data["apps"][app_id]["effectiveBundlePath"])
' "$APP_DIRECT_PRESENT_APP_ID"
  )"
  [[ -f "$bundle_source_path" ]] || {
    echo "pixel_boot_build_orange_gpu: TypeScript runtime bundle source not found: $bundle_source_path" >&2
    exit 1
  }
  bundle_source_dir="$(dirname "$bundle_source_path")"

  blitz_package_ref="$(repo_root)#packages.${PIXEL_GUEST_BUILD_SYSTEM:-aarch64-linux}.shadow-blitz-demo-aarch64-linux-gnu-$APP_DIRECT_PRESENT_TS_RENDERER"
  blitz_out_link="$(pixel_dir)/shadow-blitz-demo-aarch64-linux-gnu-$APP_DIRECT_PRESENT_TS_RENDERER-result"
  blitz_stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/shadow-app-direct-present-blitz.XXXXXX")"
  system_package_ref="$(repo_root)#packages.${PIXEL_GUEST_BUILD_SYSTEM:-aarch64-linux}.shadow-system"
  system_out_link="$(pixel_dir)/shadow-system-aarch64-linux-gnu-result"
  system_stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/shadow-app-direct-present-system.XXXXXX")"

  stage_system_linux_bundle \
    "$blitz_package_ref" \
    "$blitz_out_link" \
    "$blitz_stage_dir" \
    "$APP_DIRECT_PRESENT_BINARY_NAME"
  stage_app_direct_present_runtime_libs "$blitz_out_link" "$blitz_stage_dir"

  stage_system_linux_bundle \
    "$system_package_ref" \
    "$system_out_link" \
    "$system_stage_dir" \
    "$APP_DIRECT_PRESENT_SYSTEM_BINARY_NAME"

  rm -rf "$output_dir"
  mkdir -p "$output_dir"
  cp -R "$blitz_stage_dir"/. "$output_dir"/
  chmod -R u+w "$output_dir" 2>/dev/null || true
  cp "$system_stage_dir/$APP_DIRECT_PRESENT_SYSTEM_BINARY_NAME" "$output_dir/$APP_DIRECT_PRESENT_SYSTEM_BINARY_NAME"
  mkdir -p "$output_dir/lib" "$output_dir/etc"
  cp -R "$system_stage_dir/lib"/. "$output_dir/lib"/
  cp -R "$system_stage_dir/etc"/. "$output_dir/etc"/
  cp "$bundle_source_path" "$output_dir/$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_NAME"
  if [[ -d "$bundle_source_dir/assets" ]]; then
    mkdir -p "$output_dir/assets"
    cp -R "$bundle_source_dir/assets"/. "$output_dir/assets"/
  fi
  chmod 0644 "$output_dir/$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_NAME"
  strip_app_direct_present_elf_files "$output_dir"
  rm -rf "$blitz_stage_dir" "$system_stage_dir"
}

append_shell_session_env_assignment() {
  local key value
  key="${1:?append_shell_session_env_assignment requires a key}"
  value="${2:?append_shell_session_env_assignment requires a value}"
  SHELL_SESSION_EXTRA_ENV_ASSIGNMENTS+=("$key=$value")
}

append_shell_session_typescript_client_env_assignments() {
  append_shell_session_env_assignment \
    "SHADOW_APP_DIRECT_PRESENT_BINARY_PATH" \
    "$APP_DIRECT_PRESENT_BINARY_PATH"
  append_shell_session_env_assignment \
    "SHADOW_APP_DIRECT_PRESENT_LOADER_PATH" \
    "$APP_DIRECT_PRESENT_STAGE_LOADER_PATH"
  append_shell_session_env_assignment \
    "SHADOW_APP_DIRECT_PRESENT_LIBRARY_PATH" \
    "$APP_DIRECT_PRESENT_STAGE_LIBRARY_PATH"
  append_shell_session_env_assignment \
    "SHADOW_SYSTEM_STAGE_LOADER_PATH" \
    "$APP_DIRECT_PRESENT_STAGE_LOADER_PATH"
  append_shell_session_env_assignment \
    "SHADOW_SYSTEM_STAGE_LIBRARY_PATH" \
    "$APP_DIRECT_PRESENT_STAGE_LIBRARY_PATH"
  append_shell_session_env_assignment \
    "SHADOW_SYSTEM_BINARY_PATH" \
    "$APP_DIRECT_PRESENT_SYSTEM_BINARY_PATH"
}

runtime_app_metadata_for_id() {
  local app_id
  app_id="${1:?runtime_app_metadata_for_id requires an app id}"
  python3 - "$(repo_root)/runtime/apps.json" "$app_id" <<'PY'
import json
import sys

manifest_path, requested_app_id = sys.argv[1:3]
with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

for app in manifest.get("apps", []):
    if app.get("id") != requested_app_id:
        continue
    runtime = app.get("runtime") or {}
    print(app.get("model", ""))
    print(app.get("binaryName", ""))
    print(runtime.get("bundleEnv", ""))
    print(runtime.get("bundleFilename", ""))
    print(runtime.get("inputPath", ""))
    raise SystemExit(0)

raise SystemExit(f"unknown app id: {requested_app_id}")
PY
}

app_client_env_key_for_id() {
  local app_id suffix
  app_id="${1:?app_client_env_key_for_id requires an app id}"
  suffix="$(printf '%s\n' "$app_id" | tr '[:lower:]-.' '[:upper:]__')"
  printf 'SHADOW_APP_CLIENT_%s\n' "$suffix"
}

stage_shell_session_typescript_runtime_bundle() {
  local app_id output_dir app_metadata model bundle_env bundle_name input_path
  local runtime_app_env_prefix cache_env_name cache_dir bundle_json bundle_source_path
  local bundle_source_dir
  local runtime_profile
  app_id="${1:?stage_shell_session_typescript_runtime_bundle requires an app id}"
  output_dir="${2:?stage_shell_session_typescript_runtime_bundle requires an output dir}"

  app_metadata="$(runtime_app_metadata_for_id "$app_id")"
  model="$(sed -n '1p' <<<"$app_metadata")"
  bundle_env="$(sed -n '3p' <<<"$app_metadata")"
  bundle_name="$(sed -n '4p' <<<"$app_metadata")"
  input_path="$(sed -n '5p' <<<"$app_metadata")"
  if [[ "$model" != "typescript" || -z "$bundle_env" || -z "$bundle_name" || -z "$input_path" ]]; then
    echo "pixel_boot_build_orange_gpu: shell-session extra app must be TypeScript here: $app_id" >&2
    exit 1
  fi
  if [[ "$APP_DIRECT_PRESENT_CLIENT_KIND" == "rust" ]]; then
    stage_shell_session_typescript_client_bundle "$app_id" "$output_dir"
    return 0
  fi

  runtime_app_env_prefix="$(printf '%s\n' "$bundle_env" | sed -E 's/^SHADOW_RUNTIME_APP_//; s/_BUNDLE_PATH$//')"
  runtime_profile="$(runtime_build_profile_for_shell_session)"
  cache_env_name="$(runtime_cache_env_name_for_profile "$runtime_profile" "$runtime_app_env_prefix")"
  cache_dir="${PIXEL_ORANGE_GPU_SHELL_EXTRA_TS_CACHE_ROOT:-build/runtime/boot-shell-extra}/$app_id"
  bundle_json="$(
    env "$cache_env_name=$cache_dir" \
      "$SCRIPT_DIR/runtime_build_artifacts.sh" \
        --profile "$runtime_profile" \
        --include-app "$app_id"
  )"
  printf '%s\n' "$bundle_json"
  bundle_source_path="$(
    printf '%s\n' "$bundle_json" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
app_id = sys.argv[1]
print(data["apps"][app_id]["effectiveBundlePath"])
' "$app_id"
  )"
  [[ -f "$bundle_source_path" ]] || {
    echo "pixel_boot_build_orange_gpu: TypeScript runtime bundle source not found: $bundle_source_path" >&2
    exit 1
  }
  bundle_source_dir="$(dirname "$bundle_source_path")"
  cp "$bundle_source_path" "$output_dir/$bundle_name"
  if [[ -d "$bundle_source_dir/assets" ]]; then
    mkdir -p "$output_dir/assets"
    cp -R "$bundle_source_dir/assets"/. "$output_dir/assets"/
  fi
  chmod 0644 "$output_dir/$bundle_name"
  append_shell_session_env_assignment "$bundle_env" "$APP_DIRECT_PRESENT_BUNDLE_ROOT_PATH/$bundle_name"
}

stage_shell_session_typescript_client_bundle() {
  local app_id output_dir ts_stage_dir client_env_key app_lib_dir root_lib_dir typed_client_name
  local save_app_id save_client_kind save_binary_name save_runtime_env save_runtime_name
  local save_ts_input save_runtime_path save_binary_path save_launcher_name save_client_path
  local save_stage_loader_path save_stage_library_path save_system_binary_name save_system_binary_path
  local save_ts_cache_dir
  app_id="${1:?stage_shell_session_typescript_client_bundle requires an app id}"
  output_dir="${2:?stage_shell_session_typescript_client_bundle requires an output dir}"

  save_app_id="$APP_DIRECT_PRESENT_APP_ID"
  save_client_kind="$APP_DIRECT_PRESENT_CLIENT_KIND"
  save_binary_name="$APP_DIRECT_PRESENT_BINARY_NAME"
  save_runtime_env="$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV"
  save_runtime_name="$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_NAME"
  save_ts_input="$APP_DIRECT_PRESENT_TS_INPUT_PATH"
  save_runtime_path="$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_PATH"
  save_binary_path="$APP_DIRECT_PRESENT_BINARY_PATH"
  save_launcher_name="$APP_DIRECT_PRESENT_CLIENT_LAUNCHER_NAME"
  save_client_path="$APP_DIRECT_PRESENT_CLIENT_PATH"
  save_stage_loader_path="$APP_DIRECT_PRESENT_STAGE_LOADER_PATH"
  save_stage_library_path="$APP_DIRECT_PRESENT_STAGE_LIBRARY_PATH"
  save_system_binary_name="$APP_DIRECT_PRESENT_SYSTEM_BINARY_NAME"
  save_system_binary_path="$APP_DIRECT_PRESENT_SYSTEM_BINARY_PATH"
  save_ts_cache_dir="$APP_DIRECT_PRESENT_TS_CACHE_DIR"

  APP_DIRECT_PRESENT_APP_ID="$app_id"
  resolve_app_direct_present_metadata
  if [[ "$APP_DIRECT_PRESENT_CLIENT_KIND" != "typescript" ]]; then
    echo "pixel_boot_build_orange_gpu: shell-session extra app must be TypeScript here: $app_id" >&2
    exit 1
  fi
  APP_DIRECT_PRESENT_TS_CACHE_DIR="${PIXEL_ORANGE_GPU_SHELL_EXTRA_TS_CACHE_ROOT:-build/runtime/boot-shell-extra}/$app_id"

  ts_stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/shadow-shell-extra-ts.XXXXXX")"
  stage_app_direct_present_client_bundle "$ts_stage_dir"
  chmod -R u+w "$output_dir" 2>/dev/null || true
  cp -R "$ts_stage_dir"/. "$output_dir"/
  rm -rf "$ts_stage_dir"

  app_lib_dir="$output_dir/lib"
  root_lib_dir="$(dirname "$output_dir")/lib"
  if [[ -d "$app_lib_dir" ]]; then
    mkdir -p "$root_lib_dir"
    chmod -R u+w "$root_lib_dir" 2>/dev/null || true
    cp -R "$app_lib_dir"/. "$root_lib_dir"/
  fi

  append_shell_session_env_assignment \
    "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV" \
    "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_PATH"
  typed_client_name="$APP_DIRECT_PRESENT_CLIENT_LAUNCHER_NAME-$app_id"
  render_shell_session_typescript_app_launcher \
    "$output_dir/$typed_client_name" \
    "$APP_DIRECT_PRESENT_CLIENT_PATH" \
    "$APP_DIRECT_PRESENT_STAGE_LOADER_PATH" \
    "$APP_DIRECT_PRESENT_STAGE_LIBRARY_PATH" \
    "$APP_DIRECT_PRESENT_BINARY_PATH" \
    "$APP_DIRECT_PRESENT_SYSTEM_BINARY_PATH"
  client_env_key="$(app_client_env_key_for_id "$app_id")"
  append_shell_session_env_assignment "$client_env_key" "$APP_DIRECT_PRESENT_BUNDLE_ROOT_PATH/$typed_client_name"

  APP_DIRECT_PRESENT_APP_ID="$save_app_id"
  APP_DIRECT_PRESENT_CLIENT_KIND="$save_client_kind"
  APP_DIRECT_PRESENT_BINARY_NAME="$save_binary_name"
  APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV="$save_runtime_env"
  APP_DIRECT_PRESENT_RUNTIME_BUNDLE_NAME="$save_runtime_name"
  APP_DIRECT_PRESENT_TS_INPUT_PATH="$save_ts_input"
  APP_DIRECT_PRESENT_RUNTIME_BUNDLE_PATH="$save_runtime_path"
  APP_DIRECT_PRESENT_BINARY_PATH="$save_binary_path"
  APP_DIRECT_PRESENT_CLIENT_LAUNCHER_NAME="$save_launcher_name"
  APP_DIRECT_PRESENT_CLIENT_PATH="$save_client_path"
  APP_DIRECT_PRESENT_STAGE_LOADER_PATH="$save_stage_loader_path"
  APP_DIRECT_PRESENT_STAGE_LIBRARY_PATH="$save_stage_library_path"
  APP_DIRECT_PRESENT_SYSTEM_BINARY_NAME="$save_system_binary_name"
  APP_DIRECT_PRESENT_SYSTEM_BINARY_PATH="$save_system_binary_path"
  APP_DIRECT_PRESENT_TS_CACHE_DIR="$save_ts_cache_dir"
}

stage_shell_session_rust_app_bundle() {
  local app_id output_dir rust_stage_dir client_env_key
  local rust_binary_name rust_binary_path rust_launcher_name rust_client_path
  local rust_stage_loader_path rust_stage_library_path
  local save_app_id save_client_kind save_binary_name save_runtime_env save_runtime_name
  local save_ts_input save_runtime_path save_binary_path save_launcher_name save_client_path
  local save_stage_loader_path save_stage_library_path save_system_binary_name save_system_binary_path
  local save_ts_cache_dir
  app_id="${1:?stage_shell_session_rust_app_bundle requires an app id}"
  output_dir="${2:?stage_shell_session_rust_app_bundle requires an output dir}"

  save_app_id="$APP_DIRECT_PRESENT_APP_ID"
  save_client_kind="$APP_DIRECT_PRESENT_CLIENT_KIND"
  save_binary_name="$APP_DIRECT_PRESENT_BINARY_NAME"
  save_runtime_env="$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV"
  save_runtime_name="$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_NAME"
  save_ts_input="$APP_DIRECT_PRESENT_TS_INPUT_PATH"
  save_runtime_path="$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_PATH"
  save_binary_path="$APP_DIRECT_PRESENT_BINARY_PATH"
  save_launcher_name="$APP_DIRECT_PRESENT_CLIENT_LAUNCHER_NAME"
  save_client_path="$APP_DIRECT_PRESENT_CLIENT_PATH"
  save_stage_loader_path="$APP_DIRECT_PRESENT_STAGE_LOADER_PATH"
  save_stage_library_path="$APP_DIRECT_PRESENT_STAGE_LIBRARY_PATH"
  save_system_binary_name="$APP_DIRECT_PRESENT_SYSTEM_BINARY_NAME"
  save_system_binary_path="$APP_DIRECT_PRESENT_SYSTEM_BINARY_PATH"
  save_ts_cache_dir="$APP_DIRECT_PRESENT_TS_CACHE_DIR"

  APP_DIRECT_PRESENT_APP_ID="$app_id"
  resolve_app_direct_present_metadata
  if [[ "$APP_DIRECT_PRESENT_CLIENT_KIND" != "rust" ]]; then
    echo "pixel_boot_build_orange_gpu: shell-session extra app must be Rust here: $app_id" >&2
    exit 1
  fi
  rust_binary_name="$APP_DIRECT_PRESENT_BINARY_NAME"
  rust_binary_path="$APP_DIRECT_PRESENT_BINARY_PATH"
  rust_launcher_name="$APP_DIRECT_PRESENT_CLIENT_LAUNCHER_NAME"
  rust_client_path="$APP_DIRECT_PRESENT_CLIENT_PATH"
  rust_stage_loader_path="$APP_DIRECT_PRESENT_STAGE_LOADER_PATH"
  rust_stage_library_path="$APP_DIRECT_PRESENT_STAGE_LIBRARY_PATH"
  if [[ "$save_client_kind" == "typescript" ]]; then
    rust_stage_loader_path="$save_stage_loader_path"
    rust_stage_library_path="$save_stage_library_path"
  fi

  if [[ ! -f "$output_dir/$rust_binary_name" ]]; then
    rust_stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/shadow-shell-extra-rust.XXXXXX")"
    stage_app_direct_present_rust_bundle "$rust_stage_dir"
    chmod -R u+w "$output_dir" 2>/dev/null || true
    cp -R "$rust_stage_dir"/. "$output_dir"/
    rm -rf "$rust_stage_dir"
  fi
  [[ -f "$output_dir/$rust_binary_name" ]] || {
    echo "pixel_boot_build_orange_gpu: shell-session Rust app binary missing from staged bundle: $rust_binary_name" >&2
    exit 1
  }
  render_shell_session_rust_app_launcher \
    "$output_dir/$rust_launcher_name" \
    "$rust_stage_loader_path" \
    "$rust_stage_library_path" \
    "$rust_binary_path"
  client_env_key="$(app_client_env_key_for_id "$app_id")"
  append_shell_session_env_assignment "$client_env_key" "$rust_client_path"

  APP_DIRECT_PRESENT_APP_ID="$save_app_id"
  APP_DIRECT_PRESENT_CLIENT_KIND="$save_client_kind"
  APP_DIRECT_PRESENT_BINARY_NAME="$save_binary_name"
  APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV="$save_runtime_env"
  APP_DIRECT_PRESENT_RUNTIME_BUNDLE_NAME="$save_runtime_name"
  APP_DIRECT_PRESENT_TS_INPUT_PATH="$save_ts_input"
  APP_DIRECT_PRESENT_RUNTIME_BUNDLE_PATH="$save_runtime_path"
  APP_DIRECT_PRESENT_BINARY_PATH="$save_binary_path"
  APP_DIRECT_PRESENT_CLIENT_LAUNCHER_NAME="$save_launcher_name"
  APP_DIRECT_PRESENT_CLIENT_PATH="$save_client_path"
  APP_DIRECT_PRESENT_STAGE_LOADER_PATH="$save_stage_loader_path"
  APP_DIRECT_PRESENT_STAGE_LIBRARY_PATH="$save_stage_library_path"
  APP_DIRECT_PRESENT_SYSTEM_BINARY_NAME="$save_system_binary_name"
  APP_DIRECT_PRESENT_SYSTEM_BINARY_PATH="$save_system_binary_path"
  APP_DIRECT_PRESENT_TS_CACHE_DIR="$save_ts_cache_dir"
}

stage_shell_session_extra_app_bundles() {
  local output_dir csv app_id app_metadata model
  output_dir="${1:?stage_shell_session_extra_app_bundles requires an output dir}"
  csv="${SHELL_SESSION_EXTRA_APP_IDS//,/ }"
  for app_id in $csv; do
    [[ -n "$app_id" ]] || continue
    [[ "$app_id" != "$APP_DIRECT_PRESENT_APP_ID" ]] || continue
    app_metadata="$(runtime_app_metadata_for_id "$app_id")"
    model="$(sed -n '1p' <<<"$app_metadata")"
    case "$model" in
      typescript)
        stage_shell_session_typescript_runtime_bundle "$app_id" "$output_dir"
        ;;
      rust)
        stage_shell_session_rust_app_bundle "$app_id" "$output_dir"
        ;;
      *)
        echo "pixel_boot_build_orange_gpu: unsupported shell-session extra app model for $app_id: $model" >&2
        exit 1
        ;;
    esac
  done
}

boot_gpu_bundle_needs_curated_android_fonts() {
  local csv app_id app_metadata model

  if [[ "$APP_DIRECT_PRESENT_CLIENT_KIND" == "typescript" || "$APP_DIRECT_PRESENT_CLIENT_KIND" == "rust" ]]; then
    return 0
  fi

  case "$ORANGE_GPU_MODE" in
    shell-session|shell-session-held|shell-session-runtime-touch-counter)
      ;;
    *)
      return 1
      ;;
  esac

  csv="${SHELL_SESSION_EXTRA_APP_IDS//,/ }"
  for app_id in $csv; do
    [[ -n "$app_id" ]] || continue
    [[ "$app_id" != "$APP_DIRECT_PRESENT_APP_ID" ]] || continue
    app_metadata="$(runtime_app_metadata_for_id "$app_id")"
    model="$(sed -n '1p' <<<"$app_metadata")"
    if [[ "$model" == "typescript" || "$model" == "rust" ]]; then
      return 0
    fi
  done

  return 1
}

stage_boot_gpu_bundle_curated_android_fonts() {
  local bundle_dir
  bundle_dir="${1:?stage_boot_gpu_bundle_curated_android_fonts requires a bundle dir}"

  if boot_gpu_bundle_needs_curated_android_fonts; then
    stage_runtime_bundle_android_fonts "$bundle_dir"
  fi
}

stage_app_direct_present_client_bundle() {
  local output_dir
  local client_bundle_dir

  output_dir="${1:?stage_app_direct_present_client_bundle requires an output dir}"
  client_bundle_dir="${PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_BUNDLE_DIR:-}"

  if [[ -z "$client_bundle_dir" ]]; then
    if [[ "$APP_DIRECT_PRESENT_CLIENT_KIND" == "typescript" ]]; then
      stage_app_direct_present_typescript_bundle "$output_dir"
    else
      stage_app_direct_present_rust_bundle "$output_dir"
    fi
    client_bundle_dir="$output_dir"
  fi

  if [[ -z "$APP_DIRECT_PRESENT_CLIENT_LAUNCHER_BINARY" ]]; then
    APP_DIRECT_PRESENT_CLIENT_LAUNCHER_BINARY="$(default_app_direct_present_client_launcher_binary)"
    build_or_copy_linux_static_device_binary \
      "app-direct-present-launcher-device" \
      "$APP_DIRECT_PRESENT_CLIENT_LAUNCHER_BINARY" \
      "app-direct-present-launcher"
  fi

  [[ -d "$client_bundle_dir" ]] || {
    echo "pixel_boot_build_orange_gpu: app-direct-present client bundle dir not found: $client_bundle_dir" >&2
    exit 1
  }
  [[ -f "$APP_DIRECT_PRESENT_CLIENT_LAUNCHER_BINARY" ]] || {
    echo "pixel_boot_build_orange_gpu: app-direct-present client launcher binary not found: $APP_DIRECT_PRESENT_CLIENT_LAUNCHER_BINARY" >&2
    exit 1
  }
  assert_app_direct_present_client_launcher_variant "$APP_DIRECT_PRESENT_CLIENT_LAUNCHER_BINARY"

  if [[ "$client_bundle_dir" != "$output_dir" ]]; then
    rm -rf "$output_dir"
    mkdir -p "$output_dir"
    cp -R "$client_bundle_dir"/. "$output_dir"/
  fi
  cp "$APP_DIRECT_PRESENT_CLIENT_LAUNCHER_BINARY" "$output_dir/$APP_DIRECT_PRESENT_CLIENT_LAUNCHER_NAME"
  chmod 0755 "$output_dir/$APP_DIRECT_PRESENT_CLIENT_LAUNCHER_NAME"

  [[ -f "$output_dir/$APP_DIRECT_PRESENT_CLIENT_LAUNCHER_NAME" ]] || {
    echo "pixel_boot_build_orange_gpu: app-direct-present client launcher missing from staged bundle" >&2
    exit 1
  }
  [[ -f "$output_dir/$APP_DIRECT_PRESENT_BINARY_NAME" ]] || {
    echo "pixel_boot_build_orange_gpu: app-direct-present client binary missing from staged bundle" >&2
    exit 1
  }
  if [[ "$APP_DIRECT_PRESENT_CLIENT_KIND" == "typescript" ]]; then
    [[ -f "$output_dir/$APP_DIRECT_PRESENT_SYSTEM_BINARY_NAME" ]] || {
      echo "pixel_boot_build_orange_gpu: app-direct-present TypeScript system binary missing from staged bundle" >&2
      exit 1
    }
    [[ -f "$output_dir/$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_NAME" ]] || {
      echo "pixel_boot_build_orange_gpu: app-direct-present TypeScript runtime bundle missing from staged bundle" >&2
      exit 1
    }
  fi
  if [[ "$APP_DIRECT_PRESENT_STAGE_LOADER_PATH" == "$APP_DIRECT_PRESENT_BUNDLE_ROOT_PATH/"* ]]; then
    [[ -f "$output_dir/lib/$(basename "$APP_DIRECT_PRESENT_STAGE_LOADER_PATH")" ]] || {
      echo "pixel_boot_build_orange_gpu: app-direct-present stage loader missing from staged bundle" >&2
      exit 1
    }
    if [[ ! -d "$output_dir/lib" ]] || [[ -z "$(find "$output_dir/lib" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
      echo "pixel_boot_build_orange_gpu: app-direct-present library dir missing from staged bundle" >&2
      exit 1
    fi
  fi
}

hello_init_impl_value() {
  if [[ "$HELLO_INIT_MODE" == "rust-bridge" ]]; then
    printf 'rust-bridge\n'
  else
    printf '\n'
  fi
}

hello_init_child_path_value() {
  if [[ "$HELLO_INIT_MODE" == "rust-bridge" ]]; then
    printf '/%s\n' "$HELLO_INIT_RUST_CHILD_ENTRY"
  else
    printf '\n'
  fi
}

hello_init_shim_mode_value() {
  if [[ "$HELLO_INIT_MODE" == "rust-bridge" ]]; then
    printf '%s\n' "$HELLO_INIT_RUST_SHIM_MODE"
  else
    printf '\n'
  fi
}

hello_init_child_profile_value() {
  if [[ "$HELLO_INIT_MODE" == "rust-bridge" ]]; then
    printf '%s\n' "$HELLO_INIT_RUST_CHILD_PROFILE"
  else
    printf '\n'
  fi
}

write_metadata() {
  local metadata_path
  metadata_path="$(hello_init_metadata_path "$OUTPUT_IMAGE")"

  python3 - \
    "$metadata_path" \
    "$OUTPUT_IMAGE" \
    "$GPU_BUNDLE_DIR" \
    "$BOOT_MODE" \
    "$HOLD_SECS" \
    "$PRELUDE" \
    "$PRELUDE_HOLD_SECS" \
    "$ORANGE_GPU_MODE" \
    "$ORANGE_GPU_LAUNCH_DELAY_SECS" \
    "$ORANGE_GPU_PARENT_PROBE_ATTEMPTS" \
    "$ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS" \
    "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB" \
    "$ORANGE_GPU_METADATA_PRUNE_TOKEN_ROOT" \
    "$ORANGE_GPU_FIRMWARE_HELPER" \
    "$ORANGE_GPU_TIMEOUT_ACTION" \
    "$ORANGE_GPU_WATCHDOG_TIMEOUT_SECS" \
    "$REBOOT_TARGET" \
    "$RUN_TOKEN" \
    "$HELLO_INIT_MODE" \
    "$(hello_init_impl_value)" \
    "$(hello_init_child_path_value)" \
    "$(hello_init_shim_mode_value)" \
    "$(hello_init_child_profile_value)" \
    "$DEV_MOUNT" \
    "$MOUNT_DEV" \
    "$MOUNT_PROC" \
    "$MOUNT_SYS" \
    "$LOG_KMSG" \
    "$LOG_PMSG" \
    "$DRI_BOOTSTRAP" \
    "$INPUT_BOOTSTRAP" \
    "$INPUT_MODULE_DIR" \
    "${STAGED_INPUT_MODULE_DIR:-}" \
    "$WIFI_BOOTSTRAP" \
    "$WIFI_HELPER_PROFILE" \
    "$WIFI_SUPPLICANT_PROBE" \
    "$WIFI_MODULE_DIR" \
    "${STAGED_WIFI_MODULE_DIR:-}" \
    "$FIRMWARE_BOOTSTRAP" \
    "$WIFI_ASSOCIATION_PROBE" \
    "$WIFI_IP_PROBE" \
    "$WIFI_RUNTIME_NETWORK" \
    "$WIFI_RUNTIME_CLOCK_UNIX_SECS" \
    "$WIFI_CREDENTIALS_PATH" \
    "$WIFI_DHCP_CLIENT_BINARY" \
    "$GPU_FIRMWARE_DIR" \
    "${STAGED_GPU_FIRMWARE_DIR:-}" \
    "$(gpu_scene_value)" \
    "$(success_postlude_value)" \
    "$(checkpoint_hold_seconds_value)" \
    "$(metadata_probe_stage_path_for_token "$RUN_TOKEN")" \
    "$(metadata_probe_fingerprint_path_for_token "$RUN_TOKEN")" \
    "$(metadata_probe_report_path_for_token "$RUN_TOKEN")" \
    "$(metadata_probe_timeout_class_path_for_token "$RUN_TOKEN")" \
    "$(metadata_probe_summary_path_for_token "$RUN_TOKEN")" \
    "$(metadata_compositor_frame_path_for_token "$RUN_TOKEN")" \
    "$ORANGE_GPU_BUNDLE_ARCHIVE_PATH" \
    "$ORANGE_GPU_BUNDLE_ARCHIVE_SOURCE" \
    "$STAGED_GPU_BUNDLE_ARCHIVE" \
    "$EXTERNAL_GPU_BUNDLE_ARCHIVE" \
    "$SHELL_SESSION_START_APP_ID" \
    "$APP_DIRECT_PRESENT_APP_ID" \
    "$APP_DIRECT_PRESENT_CLIENT_KIND" \
    "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV" \
    "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_PATH" \
    "$APP_DIRECT_PRESENT_TS_RENDERER" \
    "$APP_DIRECT_PRESENT_MANUAL_TOUCH" \
    "$PAYLOAD_PROBE_SOURCE" \
    "$(payload_probe_root_for_token "$RUN_TOKEN")" \
    "$(payload_probe_manifest_path_for_token "$RUN_TOKEN")" <<'PY'
import json
import sys
from pathlib import Path

(
    metadata_path,
    image_path,
    bundle_dir,
    boot_mode,
    hold_seconds,
    prelude,
    prelude_hold_seconds,
    orange_gpu_mode,
    orange_gpu_launch_delay_secs,
    orange_gpu_parent_probe_attempts,
    orange_gpu_parent_probe_interval_secs,
    orange_gpu_metadata_stage_breadcrumb,
    orange_gpu_metadata_prune_token_root,
    orange_gpu_firmware_helper,
    orange_gpu_timeout_action,
    orange_gpu_watchdog_timeout_secs,
    reboot_target,
    run_token,
    hello_init_mode,
    hello_init_impl,
    hello_init_child_path,
    hello_init_shim_mode,
    hello_init_child_profile,
    dev_mount,
    mount_dev,
    mount_proc,
    mount_sys,
    log_kmsg,
    log_pmsg,
    dri_bootstrap,
    input_bootstrap,
    input_module_dir,
    input_module_staged_dir,
    wifi_bootstrap,
    wifi_helper_profile,
    wifi_supplicant_probe,
    wifi_module_dir,
    wifi_module_staged_dir,
    firmware_bootstrap,
    wifi_association_probe,
    wifi_ip_probe,
    wifi_runtime_network,
    wifi_runtime_clock_unix_secs,
    wifi_credentials_path,
    wifi_dhcp_client_path,
    gpu_firmware_dir,
    gpu_firmware_staged_dir,
    orange_gpu_scene,
    success_postlude,
    checkpoint_hold_seconds,
    metadata_probe_stage_path,
    metadata_probe_fingerprint_path,
    metadata_probe_report_path,
    metadata_probe_timeout_class_path,
    metadata_probe_summary_path,
    metadata_compositor_frame_path,
    orange_gpu_bundle_archive_path,
    orange_gpu_bundle_archive_source,
    staged_gpu_bundle_archive,
    external_gpu_bundle_archive,
    shell_session_start_app_id,
    app_direct_present_app_id,
    app_direct_present_client_kind,
    app_direct_present_runtime_bundle_env,
    app_direct_present_runtime_bundle_path,
    app_direct_present_typescript_renderer,
    app_direct_present_manual_touch,
    payload_probe_source,
    payload_probe_root,
    payload_probe_manifest_path,
) = sys.argv[1:]


def parse_bool(raw: str) -> bool:
    return raw == "true"


payload_json = {
    "kind": "orange_gpu_build",
    "image": image_path,
    "payload": "orange-gpu",
    "boot_mode": boot_mode,
    "orange_gpu_mode": orange_gpu_mode,
    "orange_gpu_launch_delay_secs": int(orange_gpu_launch_delay_secs),
    "orange_gpu_parent_probe_attempts": int(orange_gpu_parent_probe_attempts),
    "orange_gpu_parent_probe_interval_secs": int(orange_gpu_parent_probe_interval_secs),
    "orange_gpu_metadata_stage_breadcrumb": parse_bool(orange_gpu_metadata_stage_breadcrumb),
    "orange_gpu_metadata_prune_token_root": parse_bool(
        orange_gpu_metadata_prune_token_root
    ),
    "orange_gpu_firmware_helper": parse_bool(orange_gpu_firmware_helper),
    "orange_gpu_timeout_action": orange_gpu_timeout_action,
    "orange_gpu_watchdog_timeout_secs": int(orange_gpu_watchdog_timeout_secs),
    "gpu_bundle_dir": bundle_dir,
    "gpu_bundle_archive_path": (
        orange_gpu_bundle_archive_path if staged_gpu_bundle_archive else ""
    ),
    "gpu_bundle_archive_source": (
        orange_gpu_bundle_archive_source if staged_gpu_bundle_archive else ""
    ),
    "gpu_bundle_archive_host_path": external_gpu_bundle_archive,
    "hold_seconds": int(hold_seconds),
    "prelude": prelude,
    "prelude_hold_seconds": int(prelude_hold_seconds),
    "reboot_target": reboot_target,
    "run_token": run_token,
    "hello_init_mode": hello_init_mode,
    "hello_init_impl": hello_init_impl,
    "hello_init_child_path": hello_init_child_path,
    "hello_init_shim_mode": hello_init_shim_mode,
    "hello_init_child_profile": hello_init_child_profile,
    "dev_mount": dev_mount,
    "mount_dev": parse_bool(mount_dev),
    "mount_proc": parse_bool(mount_proc),
    "mount_sys": parse_bool(mount_sys),
    "log_kmsg": parse_bool(log_kmsg),
    "log_pmsg": parse_bool(log_pmsg),
    "dri_bootstrap": dri_bootstrap,
    "input_bootstrap": input_bootstrap,
    "input_module_dir": input_module_dir,
    "input_module_staged_dir": input_module_staged_dir,
    "wifi_bootstrap": wifi_bootstrap,
    "wifi_helper_profile": wifi_helper_profile,
    "wifi_supplicant_probe": parse_bool(wifi_supplicant_probe),
    "wifi_association_probe": parse_bool(wifi_association_probe),
    "wifi_ip_probe": parse_bool(wifi_ip_probe),
    "wifi_runtime_network": parse_bool(wifi_runtime_network),
    "wifi_runtime_clock_unix_secs_configured": bool(wifi_runtime_clock_unix_secs),
    "wifi_credentials_path_configured": bool(wifi_credentials_path),
    "wifi_dhcp_client_path_configured": bool(wifi_dhcp_client_path),
    "wifi_module_dir": wifi_module_dir,
    "wifi_module_staged_dir": wifi_module_staged_dir,
    "firmware_bootstrap": firmware_bootstrap,
    "gpu_firmware_dir": gpu_firmware_dir,
    "gpu_firmware_staged_dir": gpu_firmware_staged_dir,
    "orange_gpu_scene": orange_gpu_scene,
    "success_postlude": success_postlude,
    "checkpoint_hold_seconds": int(checkpoint_hold_seconds),
    "metadata_stage_path": (
        f"/metadata/shadow-hello-init/by-token/{run_token}/stage.txt"
        if parse_bool(orange_gpu_metadata_stage_breadcrumb)
        else ""
    ),
    "metadata_probe_stage_path": (
        metadata_probe_stage_path
        if parse_bool(orange_gpu_metadata_stage_breadcrumb)
        else ""
    ),
    "metadata_probe_fingerprint_path": (
        metadata_probe_fingerprint_path
        if parse_bool(orange_gpu_metadata_stage_breadcrumb)
        else ""
    ),
    "metadata_probe_report_path": (
        metadata_probe_report_path
        if parse_bool(orange_gpu_metadata_stage_breadcrumb)
        else ""
    ),
    "metadata_probe_timeout_class_path": (
        metadata_probe_timeout_class_path
        if parse_bool(orange_gpu_metadata_stage_breadcrumb)
        else ""
    ),
    "metadata_probe_summary_path": (
        metadata_probe_summary_path
        if parse_bool(orange_gpu_metadata_stage_breadcrumb)
        else ""
    ),
    "metadata_compositor_frame_path": (
        metadata_compositor_frame_path
        if parse_bool(orange_gpu_metadata_stage_breadcrumb)
        and orange_gpu_mode
        in {
            "compositor-scene",
            "shell-session",
            "shell-session-held",
            "shell-session-runtime-touch-counter",
            "app-direct-present",
            "app-direct-present-touch-counter",
            "app-direct-present-runtime-touch-counter",
        }
        else ""
    ),
}
if orange_gpu_mode in {"shell-session", "shell-session-held", "shell-session-runtime-touch-counter"}:
    payload_json["shell_session_start_app_id"] = shell_session_start_app_id
if orange_gpu_mode in {
    "shell-session",
    "shell-session-held",
    "shell-session-runtime-touch-counter",
    "app-direct-present",
    "app-direct-present-touch-counter",
    "app-direct-present-runtime-touch-counter",
}:
    payload_json["app_direct_present_app_id"] = app_direct_present_app_id
    payload_json["app_direct_present_client_kind"] = app_direct_present_client_kind
    payload_json["app_direct_present_runtime_bundle_env"] = app_direct_present_runtime_bundle_env
    payload_json["app_direct_present_runtime_bundle_path"] = app_direct_present_runtime_bundle_path
    payload_json["app_direct_present_manual_touch"] = parse_bool(
        app_direct_present_manual_touch
    )
    if app_direct_present_client_kind == "typescript":
        payload_json["app_direct_present_typescript_renderer"] = (
            app_direct_present_typescript_renderer
        )
if orange_gpu_mode == "payload-partition-probe" or orange_gpu_bundle_archive_source == "shadow-logical-partition":
    payload_json["payload_probe_strategy"] = "metadata-shadow-payload-v1"
    payload_json["payload_probe_source"] = payload_probe_source
    payload_json["payload_probe_root"] = payload_probe_root
    payload_json["payload_probe_manifest_path"] = payload_probe_manifest_path
    payload_json["payload_probe_fallback_path"] = "/orange-gpu"

Path(metadata_path).write_text(
    json.dumps(payload_json, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

append_array_values() {
  local array_name assignment value
  array_name="${1:?append_array_values requires an array name}"
  shift
  assignment="$array_name+=("
  for value in "$@"; do
    assignment+=" $(printf '%q' "$value")"
  done
  assignment+=" )"
  eval "$assignment"
}

append_tree_add_specs() {
  local host_root archive_root build_args_name
  host_root="${1:?append_tree_add_specs requires a host root}"
  archive_root="${2:?append_tree_add_specs requires an archive root}"
  build_args_name="${3:?append_tree_add_specs requires a build-args array name}"
  local relative_path

  append_array_values "$build_args_name" --add "$archive_root=$host_root"
  while IFS= read -r relative_path; do
    [[ -n "$relative_path" ]] || continue
    append_array_values "$build_args_name" --add "$archive_root/$relative_path=$host_root/$relative_path"
  done < <(
    cd "$host_root"
    find . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort
  )
}

append_tree_upsert_specs() {
  local host_root archive_root build_args_name
  host_root="${1:?append_tree_upsert_specs requires a host root}"
  archive_root="${2:?append_tree_upsert_specs requires an archive root}"
  build_args_name="${3:?append_tree_upsert_specs requires a build-args array name}"
  local relative_path

  append_array_values "$build_args_name" --upsert "$archive_root=$host_root"
  while IFS= read -r relative_path; do
    [[ -n "$relative_path" ]] || continue
    append_array_values "$build_args_name" --upsert "$archive_root/$relative_path=$host_root/$relative_path"
  done < <(
    cd "$host_root"
    find . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort
  )
}

stage_gpu_firmware_tree() {
  local source_dir staged_dir
  source_dir="${1:?stage_gpu_firmware_tree requires a source dir}"
  staged_dir="${2:?stage_gpu_firmware_tree requires a staged dir}"

  mkdir -p "$staged_dir"
  cp -R "$source_dir"/. "$staged_dir"/
}

stage_input_module_tree() {
  local source_dir staged_dir module
  source_dir="${1:?stage_input_module_tree requires a source dir}"
  staged_dir="${2:?stage_input_module_tree requires a staged dir}"

  mkdir -p "$staged_dir"
  for module in heatmap.ko ftm5.ko; do
    [[ -f "$source_dir/$module" ]] || {
      echo "pixel_boot_build_orange_gpu: input module dir missing $module: $source_dir" >&2
      exit 1
    }
    cp "$source_dir/$module" "$staged_dir/$module"
    chmod 0644 "$staged_dir/$module"
  done
}

stage_wifi_module_tree() {
  local source_dir staged_dir module
  source_dir="${1:?stage_wifi_module_tree requires a source dir}"
  staged_dir="${2:?stage_wifi_module_tree requires a staged dir}"

  mkdir -p "$staged_dir"
  for module in wlan.ko; do
    [[ -f "$source_dir/$module" ]] || {
      echo "pixel_boot_build_orange_gpu: wifi module dir missing $module: $source_dir" >&2
      exit 1
    }
    cp "$source_dir/$module" "$staged_dir/$module"
    chmod 0644 "$staged_dir/$module"
  done
}

stage_gpu_bundle() {
  local source_dir staged_dir manifest_path
  source_dir="${1:?stage_gpu_bundle requires a source dir}"
  staged_dir="${2:?stage_gpu_bundle requires a staged dir}"
  manifest_path="$staged_dir/share/vulkan/icd.d/freedreno_icd.aarch64.json"

  mkdir -p "$staged_dir"
  cp -R "$source_dir"/. "$staged_dir"/

  python3 - "$manifest_path" "$PAYLOAD_IMAGE_PATH" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
payload_root = sys.argv[2]
payload = json.loads(manifest_path.read_text(encoding="utf-8"))
payload.setdefault("ICD", {})
payload["ICD"]["library_path"] = f"{payload_root}/lib/libvulkan_freedreno.so"
manifest_path.write_text(json.dumps(payload, indent=4) + "\n", encoding="utf-8")
PY
}

cleanup() {
  if [[ "$KEEP_WORK_DIR" == "1" ]]; then
    return 0
  fi
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      INPUT_IMAGE="${2:?missing value for --input}"
      shift 2
      ;;
    --init)
      HELLO_INIT_BINARY="${2:?missing value for --init}"
      shift 2
      ;;
    --rust-shim)
      HELLO_INIT_RUST_SHIM_BINARY="${2:?missing value for --rust-shim}"
      shift 2
      ;;
    --rust-shim-mode)
      HELLO_INIT_RUST_SHIM_MODE="${2:?missing value for --rust-shim-mode}"
      shift 2
      ;;
    --rust-child-profile)
      HELLO_INIT_RUST_CHILD_PROFILE="${2:?missing value for --rust-child-profile}"
      shift 2
      ;;
    --orange-init)
      ORANGE_INIT_BINARY="${2:?missing value for --orange-init}"
      shift 2
      ;;
    --gpu-bundle)
      GPU_BUNDLE_DIR="${2:?missing value for --gpu-bundle}"
      shift 2
      ;;
    --key)
      KEY_PATH="${2:?missing value for --key}"
      shift 2
      ;;
    --output)
      OUTPUT_IMAGE="${2:?missing value for --output}"
      shift 2
      ;;
    --hold-secs)
      HOLD_SECS="${2:?missing value for --hold-secs}"
      shift 2
      ;;
    --hello-init-mode)
      HELLO_INIT_MODE="${2:?missing value for --hello-init-mode}"
      shift 2
      ;;
    --boot-mode)
      BOOT_MODE="${2:?missing value for --boot-mode}"
      shift 2
      ;;
    --prelude)
      PRELUDE="${2:?missing value for --prelude}"
      shift 2
      ;;
    --prelude-hold-secs)
      PRELUDE_HOLD_SECS="${2:?missing value for --prelude-hold-secs}"
      shift 2
      ;;
    --orange-gpu-mode)
      ORANGE_GPU_MODE="${2:?missing value for --orange-gpu-mode}"
      shift 2
      ;;
    --orange-gpu-launch-delay-secs)
      ORANGE_GPU_LAUNCH_DELAY_SECS="${2:?missing value for --orange-gpu-launch-delay-secs}"
      shift 2
      ;;
    --orange-gpu-parent-probe-attempts)
      ORANGE_GPU_PARENT_PROBE_ATTEMPTS="${2:?missing value for --orange-gpu-parent-probe-attempts}"
      shift 2
      ;;
    --orange-gpu-parent-probe-interval-secs)
      ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS="${2:?missing value for --orange-gpu-parent-probe-interval-secs}"
      shift 2
      ;;
    --orange-gpu-metadata-stage-breadcrumb)
      ORANGE_GPU_METADATA_STAGE_BREADCRUMB="${2:?missing value for --orange-gpu-metadata-stage-breadcrumb}"
      shift 2
      ;;
    --orange-gpu-metadata-prune-token-root)
      ORANGE_GPU_METADATA_PRUNE_TOKEN_ROOT="${2:?missing value for --orange-gpu-metadata-prune-token-root}"
      shift 2
      ;;
    --orange-gpu-firmware-helper)
      ORANGE_GPU_FIRMWARE_HELPER="${2:?missing value for --orange-gpu-firmware-helper}"
      shift 2
      ;;
    --orange-gpu-timeout-action)
      ORANGE_GPU_TIMEOUT_ACTION="${2:?missing value for --orange-gpu-timeout-action}"
      shift 2
      ;;
    --orange-gpu-watchdog-timeout-secs)
      ORANGE_GPU_WATCHDOG_TIMEOUT_SECS="${2:?missing value for --orange-gpu-watchdog-timeout-secs}"
      shift 2
      ;;
    --orange-gpu-bundle-archive-source)
      ORANGE_GPU_BUNDLE_ARCHIVE_SOURCE="${2:?missing value for --orange-gpu-bundle-archive-source}"
      shift 2
      ;;
    --payload-probe-root)
      PAYLOAD_PROBE_ROOT="${2:?missing value for --payload-probe-root}"
      shift 2
      ;;
    --payload-probe-source)
      PAYLOAD_PROBE_SOURCE="${2:?missing value for --payload-probe-source}"
      shift 2
      ;;
    --payload-probe-manifest-path)
      PAYLOAD_PROBE_MANIFEST_PATH="${2:?missing value for --payload-probe-manifest-path}"
      shift 2
      ;;
    --reboot-target)
      REBOOT_TARGET="${2:?missing value for --reboot-target}"
      shift 2
      ;;
    --run-token)
      RUN_TOKEN="${2:?missing value for --run-token}"
      shift 2
      ;;
    --dev-mount)
      DEV_MOUNT="${2:?missing value for --dev-mount}"
      shift 2
      ;;
    --mount-dev)
      MOUNT_DEV="${2:?missing value for --mount-dev}"
      shift 2
      ;;
    --mount-proc)
      MOUNT_PROC="${2:?missing value for --mount-proc}"
      shift 2
      ;;
    --mount-sys)
      MOUNT_SYS="${2:?missing value for --mount-sys}"
      shift 2
      ;;
    --log-kmsg)
      LOG_KMSG="${2:?missing value for --log-kmsg}"
      shift 2
      ;;
    --log-pmsg)
      LOG_PMSG="${2:?missing value for --log-pmsg}"
      shift 2
      ;;
    --dri-bootstrap)
      DRI_BOOTSTRAP="${2:?missing value for --dri-bootstrap}"
      shift 2
      ;;
    --input-bootstrap)
      INPUT_BOOTSTRAP="${2:?missing value for --input-bootstrap}"
      shift 2
      ;;
    --input-module-dir)
      INPUT_MODULE_DIR="${2:?missing value for --input-module-dir}"
      shift 2
      ;;
    --wifi-bootstrap)
      WIFI_BOOTSTRAP="${2:?missing value for --wifi-bootstrap}"
      shift 2
      ;;
    --wifi-helper-profile)
      WIFI_HELPER_PROFILE="${2:?missing value for --wifi-helper-profile}"
      WIFI_HELPER_PROFILE_EXPLICIT=1
      shift 2
      ;;
    --wifi-supplicant-probe)
      WIFI_SUPPLICANT_PROBE="${2:?missing value for --wifi-supplicant-probe}"
      shift 2
      ;;
    --wifi-association-probe)
      WIFI_ASSOCIATION_PROBE="${2:?missing value for --wifi-association-probe}"
      shift 2
      ;;
    --wifi-ip-probe)
      WIFI_IP_PROBE="${2:?missing value for --wifi-ip-probe}"
      shift 2
      ;;
    --wifi-runtime-network)
      WIFI_RUNTIME_NETWORK="${2:?missing value for --wifi-runtime-network}"
      shift 2
      ;;
    --wifi-runtime-clock-unix-secs)
      WIFI_RUNTIME_CLOCK_UNIX_SECS="${2:?missing value for --wifi-runtime-clock-unix-secs}"
      shift 2
      ;;
    --wifi-credentials-path)
      WIFI_CREDENTIALS_PATH="${2:?missing value for --wifi-credentials-path}"
      shift 2
      ;;
    --wifi-dhcp-client)
      WIFI_DHCP_CLIENT_BINARY="${2:?missing value for --wifi-dhcp-client}"
      shift 2
      ;;
    --wifi-module-dir)
      WIFI_MODULE_DIR="${2:?missing value for --wifi-module-dir}"
      shift 2
      ;;
    --firmware-bootstrap)
      FIRMWARE_BOOTSTRAP="${2:?missing value for --firmware-bootstrap}"
      shift 2
      ;;
    --firmware-dir)
      GPU_FIRMWARE_DIR="${2:?missing value for --firmware-dir}"
      shift 2
      ;;
    --camera-linker-capsule)
      CAMERA_LINKER_CAPSULE_DIR="${2:?missing value for --camera-linker-capsule}"
      shift 2
      ;;
    --wifi-linker-capsule)
      CAMERA_LINKER_CAPSULE_DIR="${2:?missing value for --wifi-linker-capsule}"
      shift 2
      ;;
    --camera-hal-bionic-probe)
      CAMERA_HAL_BIONIC_PROBE_BINARY="${2:?missing value for --camera-hal-bionic-probe}"
      shift 2
      ;;
    --camera-hal-camera-id)
      CAMERA_HAL_CAMERA_ID="${2:?missing value for --camera-hal-camera-id}"
      shift 2
      ;;
    --camera-hal-call-open)
      CAMERA_HAL_CALL_OPEN="${2:?missing value for --camera-hal-call-open}"
      shift 2
      ;;
    --app-direct-present-manual-touch)
      APP_DIRECT_PRESENT_MANUAL_TOUCH="${2:?missing value for --app-direct-present-manual-touch}"
      shift 2
      ;;
    --shell-session-extra-app-ids)
      if (($# < 2)); then
        echo "pixel_boot_build_orange_gpu: missing value for --shell-session-extra-app-ids" >&2
        exit 1
      fi
      SHELL_SESSION_EXTRA_APP_IDS="$2"
      shift 2
      ;;
    --keep-work-dir)
      KEEP_WORK_DIR=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$INPUT_IMAGE" ]]; then
  INPUT_IMAGE="$(pixel_resolve_stock_boot_img || true)"
fi

[[ -f "$INPUT_IMAGE" ]] || {
  cat <<EOF >&2
pixel_boot_build_orange_gpu: input image not found: $INPUT_IMAGE

Run 'sc root-prep' first to cache the stock sunfish boot.img.
EOF
  exit 1
}

if [[ -z "$RUN_TOKEN" ]]; then
  RUN_TOKEN="$(generate_run_token)"
fi
assert_run_token "$RUN_TOKEN"

if [[ ! "$HOLD_SECS" =~ ^[0-9]+$ ]]; then
  echo "pixel_boot_build_orange_gpu: hold seconds must be an integer: $HOLD_SECS" >&2
  exit 1
fi
if (( HOLD_SECS > 3600 )); then
  echo "pixel_boot_build_orange_gpu: hold seconds must be <= 3600: $HOLD_SECS" >&2
  exit 1
fi
if [[ ! "$ORANGE_GPU_LAUNCH_DELAY_SECS" =~ ^[0-9]+$ ]]; then
  echo "pixel_boot_build_orange_gpu: orange gpu launch delay seconds must be an integer: $ORANGE_GPU_LAUNCH_DELAY_SECS" >&2
  exit 1
fi
if (( ORANGE_GPU_LAUNCH_DELAY_SECS > 3600 )); then
  echo "pixel_boot_build_orange_gpu: orange gpu launch delay seconds must be <= 3600: $ORANGE_GPU_LAUNCH_DELAY_SECS" >&2
  exit 1
fi
if [[ ! "$ORANGE_GPU_PARENT_PROBE_ATTEMPTS" =~ ^[0-9]+$ ]]; then
  echo "pixel_boot_build_orange_gpu: orange gpu parent probe attempts must be an integer: $ORANGE_GPU_PARENT_PROBE_ATTEMPTS" >&2
  exit 1
fi
if (( ORANGE_GPU_PARENT_PROBE_ATTEMPTS > 3600 )); then
  echo "pixel_boot_build_orange_gpu: orange gpu parent probe attempts must be <= 3600: $ORANGE_GPU_PARENT_PROBE_ATTEMPTS" >&2
  exit 1
fi
if [[ ! "$ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS" =~ ^[0-9]+$ ]]; then
  echo "pixel_boot_build_orange_gpu: orange gpu parent probe interval seconds must be an integer: $ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS" >&2
  exit 1
fi
if (( ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS > 3600 )); then
  echo "pixel_boot_build_orange_gpu: orange gpu parent probe interval seconds must be <= 3600: $ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS" >&2
  exit 1
fi
if [[ ! "$ORANGE_GPU_WATCHDOG_TIMEOUT_SECS" =~ ^[0-9]+$ ]]; then
  echo "pixel_boot_build_orange_gpu: orange gpu watchdog timeout seconds must be an integer: $ORANGE_GPU_WATCHDOG_TIMEOUT_SECS" >&2
  exit 1
fi
if (( ORANGE_GPU_WATCHDOG_TIMEOUT_SECS > 3600 )); then
  echo "pixel_boot_build_orange_gpu: orange gpu watchdog timeout seconds must be <= 3600: $ORANGE_GPU_WATCHDOG_TIMEOUT_SECS" >&2
  exit 1
fi
if [[ ! "$PRELUDE_HOLD_SECS" =~ ^[0-9]+$ ]]; then
  echo "pixel_boot_build_orange_gpu: prelude hold seconds must be an integer: $PRELUDE_HOLD_SECS" >&2
  exit 1
fi
if (( PRELUDE_HOLD_SECS > 3600 )); then
  echo "pixel_boot_build_orange_gpu: prelude hold seconds must be <= 3600: $PRELUDE_HOLD_SECS" >&2
  exit 1
fi
assert_safe_word reboot-target "$REBOOT_TARGET" 31
assert_boot_mode_word "$BOOT_MODE"
assert_prelude_word "$PRELUDE"
assert_orange_gpu_mode_word "$ORANGE_GPU_MODE"
if [[ "$ORANGE_GPU_MODE" =~ ^(shell-session-runtime-touch-counter|app-direct-present-runtime-touch-counter)$ && "$APP_DIRECT_PRESENT_APP_ID_EXPLICIT" == "0" ]]; then
  APP_DIRECT_PRESENT_APP_ID=counter
fi
if [[ "$ORANGE_GPU_MODE" == "shell-session" || "$ORANGE_GPU_MODE" == "shell-session-held" || "$ORANGE_GPU_MODE" == "shell-session-runtime-touch-counter" ]]; then
  assert_safe_word shell-session-start-app-id "$SHELL_SESSION_START_APP_ID" 64
  if [[ "$SHELL_SESSION_START_APP_ID" != "shell" ]]; then
    APP_DIRECT_PRESENT_APP_ID="$SHELL_SESSION_START_APP_ID"
  elif [[ "$APP_DIRECT_PRESENT_APP_ID_EXPLICIT" == "0" ]]; then
    APP_DIRECT_PRESENT_APP_ID="rust-demo"
  fi
fi
if [[ "$ORANGE_GPU_MODE" == "shell-session" || "$ORANGE_GPU_MODE" == "shell-session-held" || "$ORANGE_GPU_MODE" == "shell-session-runtime-touch-counter" || "$ORANGE_GPU_MODE" == "app-direct-present" || "$ORANGE_GPU_MODE" == "app-direct-present-touch-counter" || "$ORANGE_GPU_MODE" == "app-direct-present-runtime-touch-counter" ]]; then
  assert_safe_word app-direct-present-app-id "$APP_DIRECT_PRESENT_APP_ID" 64
  if [[ "$ORANGE_GPU_MODE" == "app-direct-present-touch-counter" && "$APP_DIRECT_PRESENT_APP_ID" != "rust-demo" ]]; then
    echo "pixel_boot_build_orange_gpu: app-direct-present-touch-counter requires app-direct-present app id rust-demo" >&2
    exit 1
  fi
  if [[ "$ORANGE_GPU_MODE" == "app-direct-present-runtime-touch-counter" && "$APP_DIRECT_PRESENT_APP_ID" != "counter" ]]; then
    echo "pixel_boot_build_orange_gpu: app-direct-present-runtime-touch-counter requires app-direct-present app id counter" >&2
    exit 1
  fi
  if [[ "$ORANGE_GPU_MODE" == "shell-session-runtime-touch-counter" && "$APP_DIRECT_PRESENT_APP_ID" != "counter" ]]; then
    echo "pixel_boot_build_orange_gpu: shell-session-runtime-touch-counter requires shell-session start app id counter" >&2
    exit 1
  fi
  resolve_app_direct_present_metadata
  if [[ "$ORANGE_GPU_MODE" == "shell-session-runtime-touch-counter" && "$APP_DIRECT_PRESENT_CLIENT_KIND" != "typescript" ]]; then
    echo "pixel_boot_build_orange_gpu: shell-session-runtime-touch-counter requires a hosted TypeScript app id, got $APP_DIRECT_PRESENT_APP_ID ($APP_DIRECT_PRESENT_CLIENT_KIND)" >&2
    exit 1
  fi
fi
if [[ "$PRELUDE" == "none" && "$PRELUDE_HOLD_SECS" != "0" ]]; then
  echo "pixel_boot_build_orange_gpu: prelude hold seconds must be 0 when prelude is none" >&2
  exit 1
fi
if [[ "$PRELUDE" != "none" && "$PRELUDE_HOLD_SECS" == "0" ]]; then
  echo "pixel_boot_build_orange_gpu: prelude hold seconds must be > 0 when prelude is enabled" >&2
  exit 1
fi
if [[ "$ORANGE_GPU_PARENT_PROBE_ATTEMPTS" == "0" && "$ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS" != "0" ]]; then
  echo "pixel_boot_build_orange_gpu: orange gpu parent probe interval seconds must be 0 when parent probe attempts are 0" >&2
  exit 1
fi
assert_dev_mount_word "$DEV_MOUNT"
assert_bool_word mount-dev "$MOUNT_DEV"
assert_bool_word mount-proc "$MOUNT_PROC"
assert_bool_word mount-sys "$MOUNT_SYS"
assert_bool_word log-kmsg "$LOG_KMSG"
assert_bool_word log-pmsg "$LOG_PMSG"
assert_bool_word camera-hal-call-open "$CAMERA_HAL_CALL_OPEN"
if [[ ! "$CAMERA_HAL_CAMERA_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "pixel_boot_build_orange_gpu: camera HAL camera id must be a non-empty safe token: $CAMERA_HAL_CAMERA_ID" >&2
  exit 1
fi
assert_bool_word app-direct-present-manual-touch "$APP_DIRECT_PRESENT_MANUAL_TOUCH"
assert_bool_word orange-gpu-enable-linux-audio "$ORANGE_GPU_ENABLE_LINUX_AUDIO"
assert_bool_word orange-gpu-metadata-prune-token-root "$ORANGE_GPU_METADATA_PRUNE_TOKEN_ROOT"
assert_bundle_archive_source_word "$ORANGE_GPU_BUNDLE_ARCHIVE_SOURCE"
assert_bool_word wifi-supplicant-probe "$WIFI_SUPPLICANT_PROBE"
assert_bool_word wifi-association-probe "$WIFI_ASSOCIATION_PROBE"
assert_bool_word wifi-ip-probe "$WIFI_IP_PROBE"
assert_bool_word wifi-runtime-network "$WIFI_RUNTIME_NETWORK"
if [[ -n "$WIFI_CREDENTIALS_PATH" ]]; then
  assert_config_path_value wifi-credentials-path "$WIFI_CREDENTIALS_PATH"
fi
if [[ -n "$WIFI_RUNTIME_CLOCK_UNIX_SECS" && ! "$WIFI_RUNTIME_CLOCK_UNIX_SECS" =~ ^[0-9]+$ ]]; then
  echo "pixel_boot_build_orange_gpu: wifi runtime clock unix seconds must be an unsigned integer" >&2
  exit 1
fi

if [[ "$ORANGE_GPU_MODE" == "c-kgsl-open-readonly-firmware-helper-smoke" && "$MOUNT_SYS" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: c-kgsl-open-readonly-firmware-helper-smoke requires --mount-sys true so hello-init can service /sys/class/firmware requests" >&2
  exit 1
fi
if [[ "$ORANGE_GPU_MODE" == "c-kgsl-open-readonly-firmware-helper-smoke" && "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: c-kgsl-open-readonly-firmware-helper-smoke requires --orange-gpu-metadata-stage-breadcrumb true so helper progress survives recovery" >&2
  exit 1
fi
if [[ "$ORANGE_GPU_MODE" == "camera-hal-link-probe" && "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: camera-hal-link-probe requires --orange-gpu-metadata-stage-breadcrumb true so HAL link evidence survives recovery" >&2
  exit 1
fi
if [[ "$ORANGE_GPU_MODE" == "payload-partition-probe" && "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: payload-partition-probe requires --orange-gpu-metadata-stage-breadcrumb true so mounted payload evidence survives recovery" >&2
  exit 1
fi
if [[ "$ORANGE_GPU_MODE" == "wifi-linux-surface-probe" && "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: wifi-linux-surface-probe requires --orange-gpu-metadata-stage-breadcrumb true so Linux Wi-Fi surface evidence survives recovery" >&2
  exit 1
fi
if [[ -n "$CAMERA_LINKER_CAPSULE_DIR" ]]; then
  if [[ "$ORANGE_GPU_MODE" != "camera-hal-link-probe" && "$ORANGE_GPU_MODE" != "wifi-linux-surface-probe" && "$WIFI_RUNTIME_NETWORK" != "true" ]]; then
    echo "pixel_boot_build_orange_gpu: linker capsule is only supported with camera-hal-link-probe, wifi-linux-surface-probe, or wifi runtime network" >&2
    exit 1
  fi
  if [[ ! -d "$CAMERA_LINKER_CAPSULE_DIR" ]]; then
    echo "pixel_boot_build_orange_gpu: linker capsule dir not found: $CAMERA_LINKER_CAPSULE_DIR" >&2
    exit 1
  fi
fi
if [[ "$BOOT_MODE" != "product" && "$ORANGE_GPU_MODE" =~ ^(compositor-scene|shell-session|shell-session-held|shell-session-runtime-touch-counter|app-direct-present|app-direct-present-touch-counter|app-direct-present-runtime-touch-counter)$ && "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: $ORANGE_GPU_MODE requires --orange-gpu-metadata-stage-breadcrumb true so the captured frame survives recovery" >&2
  exit 1
fi
if [[ "$BOOT_MODE" != "product" && "$ORANGE_GPU_MODE" =~ ^(compositor-scene|shell-session|shell-session-held|shell-session-runtime-touch-counter|app-direct-present|app-direct-present-touch-counter|app-direct-present-runtime-touch-counter)$ && "$ORANGE_GPU_FIRMWARE_HELPER" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: $ORANGE_GPU_MODE requires --orange-gpu-firmware-helper true so the session stays on the signed-off GPU seam" >&2
  exit 1
fi
assert_bool_word orange-gpu-metadata-stage-breadcrumb "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB"
assert_bool_word orange-gpu-firmware-helper "$ORANGE_GPU_FIRMWARE_HELPER"
assert_timeout_action_word "$ORANGE_GPU_TIMEOUT_ACTION"
if [[ "$ORANGE_GPU_TIMEOUT_ACTION" == "hold" && "$HELLO_INIT_MODE" != "rust-bridge" ]]; then
  echo "pixel_boot_build_orange_gpu: --orange-gpu-timeout-action hold requires --hello-init-mode rust-bridge" >&2
  exit 1
fi
assert_hello_init_mode_word "$HELLO_INIT_MODE"
if [[ "$BOOT_MODE" == "product" && "$HELLO_INIT_MODE" != "rust-bridge" ]]; then
  echo "pixel_boot_build_orange_gpu: --boot-mode product requires --hello-init-mode rust-bridge so Rust hello-init owns product profile validation" >&2
  exit 1
fi
if payload_partition_probe_mode && [[ "$HELLO_INIT_MODE" != "rust-bridge" ]]; then
  echo "pixel_boot_build_orange_gpu: payload-partition-probe requires --hello-init-mode rust-bridge because the payload verifier is implemented in Rust hello-init" >&2
  exit 1
fi
assert_rust_shim_mode_word "$HELLO_INIT_RUST_SHIM_MODE"
assert_rust_child_profile_word "$HELLO_INIT_RUST_CHILD_PROFILE"
assert_rust_bridge_supported_config
if [[ "$HELLO_INIT_MODE" == "rust-bridge" && "$HELLO_INIT_RUST_CHILD_ENTRY" != "$DEFAULT_RUST_CHILD_ENTRY" ]]; then
  echo "pixel_boot_build_orange_gpu: rust-bridge mode only supports /$DEFAULT_RUST_CHILD_ENTRY as the child path" >&2
  exit 1
fi
if [[ "$HELLO_INIT_MODE" == "rust-bridge" && "$HELLO_INIT_RUST_CHILD_PROFILE" != "hello" ]]; then
  echo "pixel_boot_build_orange_gpu: rust-bridge orange-gpu images currently require --rust-child-profile hello" >&2
  echo "pixel_boot_build_orange_gpu: use pixel_boot_build_rust_bridge.sh for std-probe or nostd-probe child variants" >&2
  exit 1
fi
assert_firmware_bootstrap_word "$FIRMWARE_BOOTSTRAP"
case "$WIFI_BOOTSTRAP" in
  none|sunfish-wlan0) ;;
  *)
    echo "pixel_boot_build_orange_gpu: wifi bootstrap must be none or sunfish-wlan0: $WIFI_BOOTSTRAP" >&2
    exit 1
    ;;
esac
if [[ "$WIFI_BOOTSTRAP" == "sunfish-wlan0" && "$WIFI_HELPER_PROFILE_EXPLICIT" == "0" ]]; then
  WIFI_HELPER_PROFILE="vnd-sm-core-binder-node"
fi
if [[ "$WIFI_ASSOCIATION_PROBE" == "true" && "$WIFI_SUPPLICANT_PROBE" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: wifi association probe requires --wifi-supplicant-probe true" >&2
  exit 1
fi
expected_wifi_credentials_path="/metadata/shadow-wifi-credentials/by-token/$RUN_TOKEN.env"
if [[ "$WIFI_ASSOCIATION_PROBE" == "true" && "$WIFI_CREDENTIALS_PATH" != "$expected_wifi_credentials_path" ]]; then
  echo "pixel_boot_build_orange_gpu: wifi association probe requires credentials at $expected_wifi_credentials_path" >&2
  exit 1
fi
if [[ "$WIFI_IP_PROBE" == "true" && "$WIFI_SUPPLICANT_PROBE" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: wifi IP probe requires --wifi-supplicant-probe true" >&2
  exit 1
fi
if [[ "$WIFI_IP_PROBE" == "true" && "$WIFI_CREDENTIALS_PATH" != "$expected_wifi_credentials_path" ]]; then
  echo "pixel_boot_build_orange_gpu: wifi IP probe requires credentials at $expected_wifi_credentials_path" >&2
  exit 1
fi
if [[ "$WIFI_IP_PROBE" == "true" ]]; then
  if [[ ! -x "$WIFI_DHCP_CLIENT_BINARY" ]]; then
    echo "pixel_boot_build_orange_gpu: wifi IP probe requires --wifi-dhcp-client with an executable static busybox" >&2
    exit 1
  fi
  assert_static_device_binary "$WIFI_DHCP_CLIENT_BINARY" "wifi DHCP client"
fi
if [[ "$WIFI_RUNTIME_NETWORK" == "true" && "$WIFI_BOOTSTRAP" != "sunfish-wlan0" ]]; then
  echo "pixel_boot_build_orange_gpu: wifi runtime network requires --wifi-bootstrap sunfish-wlan0" >&2
  exit 1
fi
if [[ "$WIFI_RUNTIME_NETWORK" == "true" && "$WIFI_CREDENTIALS_PATH" != "$expected_wifi_credentials_path" ]]; then
  echo "pixel_boot_build_orange_gpu: wifi runtime network requires credentials at $expected_wifi_credentials_path" >&2
  exit 1
fi
if [[ "$WIFI_RUNTIME_NETWORK" == "true" ]]; then
  if [[ ! -x "$WIFI_DHCP_CLIENT_BINARY" ]]; then
    echo "pixel_boot_build_orange_gpu: wifi runtime network requires --wifi-dhcp-client with an executable static busybox" >&2
    exit 1
  fi
  assert_static_device_binary "$WIFI_DHCP_CLIENT_BINARY" "wifi runtime DHCP client"
  if [[ -z "$WIFI_RUNTIME_CLOCK_UNIX_SECS" ]]; then
    WIFI_RUNTIME_CLOCK_UNIX_SECS="$(date +%s)"
  fi
fi
case "$WIFI_HELPER_PROFILE" in
  full|no-service-managers|no-pm|no-modem-svc|no-rfs-storage|no-pd-mapper|no-cnss|qrtr-only|qrtr-pd|qrtr-pd-tftp|qrtr-pd-rfs|qrtr-pd-rfs-cnss|qrtr-pd-rfs-modem|qrtr-pd-rfs-modem-cnss|qrtr-pd-rfs-modem-pm|qrtr-pd-rfs-modem-pm-cnss|aidl-sm-core|vnd-sm-core|vnd-sm-core-binder-node|all-sm-core|none) ;;
  *)
    echo "pixel_boot_build_orange_gpu: wifi helper profile is not recognized: $WIFI_HELPER_PROFILE" >&2
    exit 1
    ;;
esac
if [[ "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB" == "true" && "$MOUNT_DEV" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: orange gpu metadata stage breadcrumb requires mount-dev=true" >&2
  exit 1
fi
if [[ "$ORANGE_GPU_FIRMWARE_HELPER" == "true" && "$MOUNT_SYS" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: orange-gpu-firmware-helper requires --mount-sys true" >&2
  exit 1
fi
if [[ "$INPUT_BOOTSTRAP" != "none" && "$MOUNT_SYS" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: input-bootstrap requires --mount-sys true so hello-init can discover /sys/class/input devices" >&2
  exit 1
fi
if [[ "$ORANGE_GPU_BUNDLE_ARCHIVE_SOURCE" == "shadow-logical-partition" ]]; then
  PAYLOAD_PROBE_SOURCE="shadow-logical-partition"
  PAYLOAD_PROBE_ROOT="${PAYLOAD_PROBE_ROOT:-/shadow-payload}"
  PAYLOAD_PROBE_MANIFEST_PATH="${PAYLOAD_PROBE_MANIFEST_PATH:-/shadow-payload/manifest.env}"
  ORANGE_GPU_BUNDLE_ARCHIVE_PATH="/shadow-payload/extra-payloads/$ORANGE_GPU_BUNDLE_ARCHIVE_NAME"
fi
if [[ "$ORANGE_GPU_BUNDLE_ARCHIVE_SOURCE" == "shadow-logical-partition" && "$HELLO_INIT_MODE" != "rust-bridge" ]]; then
  echo "pixel_boot_build_orange_gpu: orange-gpu-bundle-archive-source shadow-logical-partition requires --hello-init-mode rust-bridge because logical payload mounting is implemented in Rust hello-init" >&2
  exit 1
fi
if [[ "$ORANGE_GPU_BUNDLE_ARCHIVE_SOURCE" == "shadow-logical-partition" && "$ORANGE_GPU_MODE" != "shell-session" && "$ORANGE_GPU_MODE" != "shell-session-held" && "$ORANGE_GPU_MODE" != "shell-session-runtime-touch-counter" && "$ORANGE_GPU_MODE" != "app-direct-present" && "$ORANGE_GPU_MODE" != "app-direct-present-runtime-touch-counter" ]]; then
  echo "pixel_boot_build_orange_gpu: orange-gpu-bundle-archive-source shadow-logical-partition currently requires an archived shell/app mode" >&2
  exit 1
fi
if [[ "$PAYLOAD_PROBE_SOURCE" == "shadow-logical-partition" && "$MOUNT_SYS" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: payload-probe-source shadow-logical-partition requires --mount-sys true so hello-init can discover the super block device" >&2
  exit 1
fi
if [[ "$PAYLOAD_PROBE_SOURCE" == "shadow-logical-partition" ]]; then
  if [[ "$(payload_probe_root_for_token "$RUN_TOKEN")" != "/shadow-payload" || "$(payload_probe_manifest_path_for_token "$RUN_TOKEN")" != "/shadow-payload/manifest.env" ]]; then
    echo "pixel_boot_build_orange_gpu: payload-probe-source shadow-logical-partition requires --payload-probe-root /shadow-payload and --payload-probe-manifest-path /shadow-payload/manifest.env" >&2
    exit 1
  fi
fi
if [[ "$PAYLOAD_PROBE_SOURCE" == "metadata" && "$(payload_probe_root_for_token "$RUN_TOKEN")" == "/shadow-payload" ]]; then
  echo "pixel_boot_build_orange_gpu: /shadow-payload requires --payload-probe-source shadow-logical-partition" >&2
  exit 1
fi
if payload_probe_config_enabled; then
  payload_probe_root_value="$(payload_probe_root_for_token "$RUN_TOKEN")"
  payload_probe_manifest_path_value="$(payload_probe_manifest_path_for_token "$RUN_TOKEN")"
  assert_config_path_value payload-probe-root "$payload_probe_root_value"
  assert_config_path_value payload-probe-manifest-path "$payload_probe_manifest_path_value"
  assert_config_path_value payload-probe-fallback-path "$PAYLOAD_PROBE_FALLBACK_PATH"
  case "$PAYLOAD_PROBE_SOURCE:$payload_probe_root_value:$payload_probe_manifest_path_value" in
    "metadata:/metadata/shadow-payload/by-token/$RUN_TOKEN:/metadata/shadow-payload/by-token/$RUN_TOKEN/manifest.env"|"metadata:/data/local/tmp/shadow-payload/by-token/$RUN_TOKEN:/metadata/shadow-payload/by-token/$RUN_TOKEN/manifest.env"|"shadow-logical-partition:/shadow-payload:/shadow-payload/manifest.env")
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: payload probe paths must use the active run token and source-specific roots" >&2
      exit 1
      ;;
  esac
fi
if [[ "$INPUT_BOOTSTRAP" == "sunfish-touch-event2" && "$MOUNT_DEV" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: input-bootstrap sunfish-touch-event2 requires --mount-dev true so hello-init can create /dev/input/event* from sysfs" >&2
  exit 1
fi
if [[ "$INPUT_BOOTSTRAP" == "sunfish-touch-event2" && "$DEV_MOUNT" != "tmpfs" ]]; then
  echo "pixel_boot_build_orange_gpu: input-bootstrap sunfish-touch-event2 requires --dev-mount tmpfs so hello-init owns /dev/input/event* creation" >&2
  exit 1
fi
if [[ "$INPUT_BOOTSTRAP" == "sunfish-touch-event2" && "$FIRMWARE_BOOTSTRAP" != "ramdisk-lib-firmware" ]]; then
  echo "pixel_boot_build_orange_gpu: input-bootstrap sunfish-touch-event2 requires --firmware-bootstrap ramdisk-lib-firmware so hello-init can service touch firmware" >&2
  exit 1
fi
if [[ "$INPUT_BOOTSTRAP" == "sunfish-touch-event2" && -z "$INPUT_MODULE_DIR" ]]; then
  echo "pixel_boot_build_orange_gpu: input-bootstrap sunfish-touch-event2 requires --input-module-dir with heatmap.ko and ftm5.ko" >&2
  exit 1
fi
if [[ "$INPUT_BOOTSTRAP" == "none" && -n "$INPUT_MODULE_DIR" ]]; then
  echo "pixel_boot_build_orange_gpu: input-module-dir requires --input-bootstrap sunfish-touch-event2" >&2
  exit 1
fi
if [[ "$WIFI_BOOTSTRAP" != "none" && "$MOUNT_SYS" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: wifi-bootstrap requires --mount-sys true so hello-init can discover /sys/class/net/wlan0" >&2
  exit 1
fi
if [[ "$WIFI_BOOTSTRAP" == "sunfish-wlan0" && "$MOUNT_DEV" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: wifi-bootstrap sunfish-wlan0 requires --mount-dev true so hello-init can create /dev/wlan" >&2
  exit 1
fi
if [[ "$WIFI_BOOTSTRAP" == "sunfish-wlan0" && "$DEV_MOUNT" != "tmpfs" ]]; then
  echo "pixel_boot_build_orange_gpu: wifi-bootstrap sunfish-wlan0 requires --dev-mount tmpfs so hello-init owns /dev/wlan creation" >&2
  exit 1
fi
if [[ "$WIFI_BOOTSTRAP" == "sunfish-wlan0" && "$FIRMWARE_BOOTSTRAP" != "ramdisk-lib-firmware" ]]; then
  echo "pixel_boot_build_orange_gpu: wifi-bootstrap sunfish-wlan0 requires --firmware-bootstrap ramdisk-lib-firmware so hello-init can service WLAN firmware" >&2
  exit 1
fi
if [[ "$WIFI_BOOTSTRAP" == "sunfish-wlan0" && -z "$WIFI_MODULE_DIR" ]]; then
  echo "pixel_boot_build_orange_gpu: wifi-bootstrap sunfish-wlan0 requires --wifi-module-dir with wlan.ko" >&2
  exit 1
fi
if [[ "$WIFI_BOOTSTRAP" == "none" && -n "$WIFI_MODULE_DIR" ]]; then
  echo "pixel_boot_build_orange_gpu: wifi-module-dir requires --wifi-bootstrap sunfish-wlan0" >&2
  exit 1
fi
if [[ "$ORANGE_GPU_FIRMWARE_HELPER" == "true" && "$FIRMWARE_BOOTSTRAP" != "ramdisk-lib-firmware" ]]; then
  echo "pixel_boot_build_orange_gpu: orange-gpu-firmware-helper requires --firmware-bootstrap ramdisk-lib-firmware" >&2
  exit 1
fi
if [[ "$FIRMWARE_BOOTSTRAP" == "none" && -n "$GPU_FIRMWARE_DIR" ]]; then
  echo "pixel_boot_build_orange_gpu: firmware-dir requires firmware-bootstrap to be enabled" >&2
  exit 1
fi
if [[ "$FIRMWARE_BOOTSTRAP" != "none" && -z "$GPU_FIRMWARE_DIR" ]]; then
  echo "pixel_boot_build_orange_gpu: firmware-bootstrap requires --firmware-dir" >&2
  exit 1
fi
if [[ "$INPUT_BOOTSTRAP" == "sunfish-touch-event2" && -n "$GPU_FIRMWARE_DIR" && ! -f "$GPU_FIRMWARE_DIR/ftm5_fw.ftb" ]]; then
  echo "pixel_boot_build_orange_gpu: input-bootstrap sunfish-touch-event2 requires ftm5_fw.ftb in --firmware-dir" >&2
  exit 1
fi
if [[ -z "$DRI_BOOTSTRAP" ]]; then
  if [[ "$PRELUDE" == "orange-init" && "$ORANGE_GPU_MODE" == "bundle-smoke" ]]; then
    DRI_BOOTSTRAP="sunfish-card0-renderD128"
  elif [[ "$ORANGE_GPU_MODE" == "bundle-smoke" ]]; then
    DRI_BOOTSTRAP="none"
  elif payload_partition_probe_mode; then
    DRI_BOOTSTRAP="none"
  else
    DRI_BOOTSTRAP="sunfish-card0-renderD128-kgsl3d0"
  fi
fi
assert_dri_bootstrap_word "$DRI_BOOTSTRAP"
assert_input_bootstrap_word "$INPUT_BOOTSTRAP"
if [[ -z "$KEY_PATH" ]]; then
  KEY_PATH="$(ensure_cached_avb_testkey)"
fi

pixel_prepare_dirs
if [[ -z "$OUTPUT_IMAGE" ]]; then
  OUTPUT_IMAGE="$(default_output_image)"
fi
mkdir -p "$(dirname "$OUTPUT_IMAGE")"
WORK_DIR="$(bootimg_prepare_work_dir shadow-pixel-boot-orange-gpu)"
assert_input_matches_stock_boot
assert_stock_root_init_shape

if [[ "$HELLO_INIT_MODE" == "rust-bridge" ]]; then
  if [[ -z "$HELLO_INIT_BINARY" ]]; then
    HELLO_INIT_BINARY="$(default_rust_hello_init_binary)"
    build_or_copy_rust_hello_init_binary \
      "$(default_rust_hello_init_package_ref)" \
      "$HELLO_INIT_BINARY" \
      "$(default_rust_hello_init_binary_name)"
  fi
  if [[ -z "$HELLO_INIT_RUST_SHIM_BINARY" ]]; then
    HELLO_INIT_RUST_SHIM_BINARY="$(default_rust_hello_init_shim_binary)"
    build_or_copy_rust_hello_init_binary \
      "$(default_rust_hello_init_shim_package_ref)" \
      "$HELLO_INIT_RUST_SHIM_BINARY" \
      "$(default_rust_hello_init_shim_binary_name)"
  fi
else
  if [[ -z "$HELLO_INIT_BINARY" ]]; then
    if [[ "$ORANGE_GPU_MODE" == "camera-hal-link-probe" || "$ORANGE_GPU_MODE" == "wifi-linux-surface-probe" || "$WIFI_RUNTIME_NETWORK" == "true" ]]; then
      HELLO_INIT_BINARY="$(default_rust_hello_init_binary)"
      build_or_copy_rust_hello_init_binary \
        "$(default_rust_hello_init_package_ref)" \
        "$HELLO_INIT_BINARY" \
        "$(default_rust_hello_init_binary_name)"
    else
      HELLO_INIT_BINARY="$(default_hello_init_binary)"
      "$SCRIPT_DIR/pixel/pixel_build_hello_init.sh" --output "$HELLO_INIT_BINARY"
    fi
  fi
fi

[[ -f "$HELLO_INIT_BINARY" ]] || {
  echo "pixel_boot_build_orange_gpu: hello-init binary not found: $HELLO_INIT_BINARY" >&2
  exit 1
}

if [[ "$HELLO_INIT_MODE" == "rust-bridge" ]]; then
  [[ -f "$HELLO_INIT_RUST_SHIM_BINARY" ]] || {
    echo "pixel_boot_build_orange_gpu: rust shim binary not found: $HELLO_INIT_RUST_SHIM_BINARY" >&2
    exit 1
  }
  assert_rust_hello_variant "$HELLO_INIT_BINARY"
  assert_rust_hello_variant "$HELLO_INIT_RUST_SHIM_BINARY"
else
  if [[ "$ORANGE_GPU_MODE" == "camera-hal-link-probe" || "$ORANGE_GPU_MODE" == "wifi-linux-surface-probe" || "$WIFI_RUNTIME_NETWORK" == "true" ]]; then
    assert_rust_hello_variant "$HELLO_INIT_BINARY"
  else
    assert_hello_variant "$HELLO_INIT_BINARY"
  fi
fi

STAGED_HELLO_INIT_BINARY="$WORK_DIR/hello-init"
stage_boot_executable "$HELLO_INIT_BINARY" "$STAGED_HELLO_INIT_BINARY"
if [[ "$HELLO_INIT_MODE" == "rust-bridge" ]]; then
  STAGED_HELLO_INIT_RUST_SHIM_BINARY="$WORK_DIR/hello-init-rust-shim"
  stage_boot_executable "$HELLO_INIT_RUST_SHIM_BINARY" "$STAGED_HELLO_INIT_RUST_SHIM_BINARY"
fi

if [[ "$ORANGE_GPU_MODE" == "camera-hal-link-probe" ]]; then
  if [[ -z "$CAMERA_HAL_BIONIC_PROBE_BINARY" && -z "${MOCK_BOOT_RAMDISK:-}" ]]; then
    CAMERA_HAL_BIONIC_PROBE_BINARY="$(default_camera_hal_bionic_probe_binary)"
    "$SCRIPT_DIR/pixel/pixel_build_camera_hal_bionic_probe.sh" \
      --output "$CAMERA_HAL_BIONIC_PROBE_BINARY"
  fi
  if [[ -n "$CAMERA_HAL_BIONIC_PROBE_BINARY" ]]; then
    [[ -f "$CAMERA_HAL_BIONIC_PROBE_BINARY" ]] || {
      echo "pixel_boot_build_orange_gpu: camera HAL bionic probe binary not found: $CAMERA_HAL_BIONIC_PROBE_BINARY" >&2
      exit 1
    }
    chmod 0755 "$CAMERA_HAL_BIONIC_PROBE_BINARY" 2>/dev/null || true
  fi
fi
if [[ ( "$ORANGE_GPU_MODE" == "wifi-linux-surface-probe" || "$WIFI_RUNTIME_NETWORK" == "true" ) && -n "$CAMERA_LINKER_CAPSULE_DIR" ]]; then
  if [[ -z "$SHADOW_PROPERTY_SHIM_BINARY" && -z "${MOCK_BOOT_RAMDISK:-}" ]]; then
    SHADOW_PROPERTY_SHIM_BINARY="$(default_shadow_property_shim_binary)"
    "$SCRIPT_DIR/pixel/pixel_build_shadow_property_shim.sh" \
      --output "$SHADOW_PROPERTY_SHIM_BINARY"
  fi
  if [[ -n "$SHADOW_PROPERTY_SHIM_BINARY" ]]; then
    [[ -f "$SHADOW_PROPERTY_SHIM_BINARY" ]] || {
      echo "pixel_boot_build_orange_gpu: shadow property shim not found: $SHADOW_PROPERTY_SHIM_BINARY" >&2
      exit 1
    }
    chmod 0755 "$SHADOW_PROPERTY_SHIM_BINARY" 2>/dev/null || true
  fi
fi

if [[ "$ORANGE_GPU_MODE" == "compositor-scene" || "$ORANGE_GPU_MODE" == "shell-session" || "$ORANGE_GPU_MODE" == "shell-session-held" || "$ORANGE_GPU_MODE" == "shell-session-runtime-touch-counter" || "$ORANGE_GPU_MODE" == "app-direct-present" || "$ORANGE_GPU_MODE" == "app-direct-present-touch-counter" || "$ORANGE_GPU_MODE" == "app-direct-present-runtime-touch-counter" ]]; then
  if [[ -z "$SHADOW_SESSION_BINARY" ]]; then
    SHADOW_SESSION_BINARY="$(pixel_artifact_path shadow-session)"
    build_or_copy_linux_static_device_binary \
      "shadow-session-device" \
      "$SHADOW_SESSION_BINARY" \
      "shadow-session"
  fi
  [[ -f "$SHADOW_SESSION_BINARY" ]] || {
    echo "pixel_boot_build_orange_gpu: shadow-session binary not found: $SHADOW_SESSION_BINARY" >&2
    exit 1
  }
  assert_static_device_binary "$SHADOW_SESSION_BINARY" "shadow-session"
  if [[ "$ORANGE_GPU_MODE" == "shell-session" || "$ORANGE_GPU_MODE" == "shell-session-held" || "$ORANGE_GPU_MODE" == "shell-session-runtime-touch-counter" ]]; then
    if [[ -z "$SHADOW_COMPOSITOR_DYNAMIC_BINARY" ]]; then
      SHADOW_COMPOSITOR_DYNAMIC_BINARY="$(pixel_artifact_path shadow-compositor-guest-gnu)"
      build_or_copy_linux_dynamic_device_binary \
        "shadow-compositor-guest-aarch64-linux-gnu" \
        "$SHADOW_COMPOSITOR_DYNAMIC_BINARY" \
        "shadow-compositor-guest"
    fi
    [[ -f "$SHADOW_COMPOSITOR_DYNAMIC_BINARY" ]] || {
      echo "pixel_boot_build_orange_gpu: dynamic shadow-compositor-guest binary not found: $SHADOW_COMPOSITOR_DYNAMIC_BINARY" >&2
      exit 1
    }
    assert_dynamic_linux_device_binary "$SHADOW_COMPOSITOR_DYNAMIC_BINARY" "shadow-compositor-guest"
  else
    if [[ -z "$SHADOW_COMPOSITOR_BINARY" ]]; then
      SHADOW_COMPOSITOR_BINARY="$(pixel_artifact_path shadow-compositor-guest)"
      build_or_copy_linux_static_device_binary \
        "shadow-compositor-guest-device" \
        "$SHADOW_COMPOSITOR_BINARY" \
        "shadow-compositor-guest"
    fi
    [[ -f "$SHADOW_COMPOSITOR_BINARY" ]] || {
      echo "pixel_boot_build_orange_gpu: shadow-compositor-guest binary not found: $SHADOW_COMPOSITOR_BINARY" >&2
      exit 1
    }
    assert_static_device_binary "$SHADOW_COMPOSITOR_BINARY" "shadow-compositor-guest"
  fi
fi

if [[ "$PRELUDE" == "orange-init" ]]; then
  if [[ -z "$ORANGE_INIT_BINARY" ]]; then
    ORANGE_INIT_BINARY="$(default_orange_init_binary)"
    "$SCRIPT_DIR/pixel/pixel_build_orange_init.sh" --output "$ORANGE_INIT_BINARY"
  fi

  [[ -f "$ORANGE_INIT_BINARY" ]] || {
    echo "pixel_boot_build_orange_gpu: orange-init binary not found: $ORANGE_INIT_BINARY" >&2
    exit 1
  }

  assert_orange_variant "$ORANGE_INIT_BINARY"
fi

STAGED_LIB_PARENT_DIR=""
if orange_gpu_mode_uses_ramdisk_gpu_bundle; then
  if [[ -z "$GPU_BUNDLE_DIR" ]]; then
    GPU_BUNDLE_DIR="$(default_gpu_bundle_dir)"
    "$SCRIPT_DIR/pixel/pixel_prepare_gpu_smoke_bundle.sh" >/dev/null
  fi

  assert_gpu_bundle_variant "$GPU_BUNDLE_DIR"
  STAGED_GPU_BUNDLE_DIR="$WORK_DIR/orange-gpu-bundle"
  stage_gpu_bundle "$GPU_BUNDLE_DIR" "$STAGED_GPU_BUNDLE_DIR"
  assert_gpu_bundle_variant "$STAGED_GPU_BUNDLE_DIR"
  if [[ "$ORANGE_GPU_MODE" == "compositor-scene" ]]; then
    COMPOSITOR_SCENE_DUMMY_CLIENT="$WORK_DIR/$(basename "$COMPOSITOR_SCENE_DUMMY_CLIENT_PATH")"
    COMPOSITOR_SCENE_STARTUP_CONFIG="$WORK_DIR/$COMPOSITOR_SCENE_STARTUP_CONFIG_NAME"
    render_compositor_scene_startup_config "$COMPOSITOR_SCENE_STARTUP_CONFIG"
    render_compositor_scene_dummy_client "$COMPOSITOR_SCENE_DUMMY_CLIENT"
    cp "$SHADOW_SESSION_BINARY" "$STAGED_GPU_BUNDLE_DIR/shadow-session"
    chmod 0755 "$STAGED_GPU_BUNDLE_DIR/shadow-session"
    cp "$SHADOW_COMPOSITOR_BINARY" "$STAGED_GPU_BUNDLE_DIR/shadow-compositor-guest"
    chmod 0755 "$STAGED_GPU_BUNDLE_DIR/shadow-compositor-guest"
    cp "$COMPOSITOR_SCENE_DUMMY_CLIENT" "$STAGED_GPU_BUNDLE_DIR/$(basename "$COMPOSITOR_SCENE_DUMMY_CLIENT_PATH")"
    chmod 0755 "$STAGED_GPU_BUNDLE_DIR/$(basename "$COMPOSITOR_SCENE_DUMMY_CLIENT_PATH")"
    cp "$COMPOSITOR_SCENE_STARTUP_CONFIG" "$STAGED_GPU_BUNDLE_DIR/$COMPOSITOR_SCENE_STARTUP_CONFIG_NAME"
  elif [[ "$ORANGE_GPU_MODE" == "app-direct-present" || "$ORANGE_GPU_MODE" == "app-direct-present-touch-counter" || "$ORANGE_GPU_MODE" == "app-direct-present-runtime-touch-counter" ]]; then
    APP_DIRECT_PRESENT_STARTUP_CONFIG="$WORK_DIR/$APP_DIRECT_PRESENT_STARTUP_CONFIG_NAME"
    stage_app_direct_present_client_bundle "$STAGED_GPU_BUNDLE_DIR/$APP_DIRECT_PRESENT_BUNDLE_DIR_NAME"
    merge_app_direct_present_typescript_runtime_libs "$STAGED_GPU_BUNDLE_DIR"
    stage_orange_gpu_audio_bridge_bundle "$STAGED_GPU_BUNDLE_DIR"
    prune_app_direct_present_diagnostic_payloads "$STAGED_GPU_BUNDLE_DIR"
    stage_boot_gpu_bundle_curated_android_fonts "$STAGED_GPU_BUNDLE_DIR"
    render_app_direct_present_startup_config "$APP_DIRECT_PRESENT_STARTUP_CONFIG"
    cp "$SHADOW_SESSION_BINARY" "$STAGED_GPU_BUNDLE_DIR/shadow-session"
    chmod 0755 "$STAGED_GPU_BUNDLE_DIR/shadow-session"
    cp "$SHADOW_COMPOSITOR_BINARY" "$STAGED_GPU_BUNDLE_DIR/shadow-compositor-guest"
    chmod 0755 "$STAGED_GPU_BUNDLE_DIR/shadow-compositor-guest"
    cp "$APP_DIRECT_PRESENT_STARTUP_CONFIG" "$STAGED_GPU_BUNDLE_DIR/$APP_DIRECT_PRESENT_STARTUP_CONFIG_NAME"
    assert_startup_client_paths_staged "$STAGED_GPU_BUNDLE_DIR" "$APP_DIRECT_PRESENT_STARTUP_CONFIG"
  elif [[ "$ORANGE_GPU_MODE" == "shell-session" || "$ORANGE_GPU_MODE" == "shell-session-held" || "$ORANGE_GPU_MODE" == "shell-session-runtime-touch-counter" ]]; then
    SHELL_SESSION_STARTUP_CONFIG="$WORK_DIR/$SHELL_SESSION_STARTUP_CONFIG_NAME"
    stage_app_direct_present_client_bundle "$STAGED_GPU_BUNDLE_DIR/$APP_DIRECT_PRESENT_BUNDLE_DIR_NAME"
    stage_shell_session_extra_app_bundles "$STAGED_GPU_BUNDLE_DIR/$APP_DIRECT_PRESENT_BUNDLE_DIR_NAME"
    merge_app_direct_present_typescript_runtime_libs "$STAGED_GPU_BUNDLE_DIR"
    stage_orange_gpu_audio_bridge_bundle "$STAGED_GPU_BUNDLE_DIR"
    prune_app_direct_present_diagnostic_payloads "$STAGED_GPU_BUNDLE_DIR"
    stage_boot_gpu_bundle_curated_android_fonts "$STAGED_GPU_BUNDLE_DIR"
    render_shell_session_startup_config "$SHELL_SESSION_STARTUP_CONFIG"
    cp "$SHADOW_SESSION_BINARY" "$STAGED_GPU_BUNDLE_DIR/shadow-session"
    chmod 0755 "$STAGED_GPU_BUNDLE_DIR/shadow-session"
    cp "$SHADOW_COMPOSITOR_DYNAMIC_BINARY" "$STAGED_GPU_BUNDLE_DIR/shadow-compositor-guest"
    chmod 0755 "$STAGED_GPU_BUNDLE_DIR/shadow-compositor-guest"
    cp "$SHELL_SESSION_STARTUP_CONFIG" "$STAGED_GPU_BUNDLE_DIR/$SHELL_SESSION_STARTUP_CONFIG_NAME"
    assert_startup_client_paths_staged "$STAGED_GPU_BUNDLE_DIR" "$SHELL_SESSION_STARTUP_CONFIG"
  fi
  if [[ "$ORANGE_GPU_MODE" == "camera-hal-link-probe" && -n "$CAMERA_HAL_BIONIC_PROBE_BINARY" ]]; then
    cp "$CAMERA_HAL_BIONIC_PROBE_BINARY" "$STAGED_GPU_BUNDLE_DIR/camera-hal-bionic-probe"
    chmod 0755 "$STAGED_GPU_BUNDLE_DIR/camera-hal-bionic-probe"
  fi
  if [[ "$WIFI_IP_PROBE" == "true" || "$WIFI_RUNTIME_NETWORK" == "true" ]]; then
    cp "$WIFI_DHCP_CLIENT_BINARY" "$STAGED_GPU_BUNDLE_DIR/busybox"
    chmod 0755 "$STAGED_GPU_BUNDLE_DIR/busybox"
  fi

  strip_staged_elf_files "$STAGED_GPU_BUNDLE_DIR"
  if [[ "$ORANGE_GPU_MODE" == "shell-session" || "$ORANGE_GPU_MODE" == "shell-session-held" || "$ORANGE_GPU_MODE" == "shell-session-runtime-touch-counter" || "$ORANGE_GPU_MODE" == "app-direct-present" || "$ORANGE_GPU_MODE" == "app-direct-present-runtime-touch-counter" ]]; then
    STAGED_GPU_BUNDLE_ARCHIVE="$WORK_DIR/$ORANGE_GPU_BUNDLE_ARCHIVE_NAME"
    archive_app_direct_present_gpu_bundle "$STAGED_GPU_BUNDLE_DIR" "$STAGED_GPU_BUNDLE_ARCHIVE"
    if orange_gpu_bundle_archive_from_shadow_logical; then
      EXTERNAL_GPU_BUNDLE_ARCHIVE="$OUTPUT_IMAGE.$ORANGE_GPU_BUNDLE_ARCHIVE_NAME"
      cp "$STAGED_GPU_BUNDLE_ARCHIVE" "$EXTERNAL_GPU_BUNDLE_ARCHIVE"
      chmod 0644 "$EXTERNAL_GPU_BUNDLE_ARCHIVE"
    fi
  fi
fi

STAGED_GPU_FIRMWARE_DIR=""
STAGED_INPUT_MODULE_DIR=""
STAGED_WIFI_MODULE_DIR=""
if [[ "$FIRMWARE_BOOTSTRAP" == "ramdisk-lib-firmware" ]]; then
  [[ -d "$GPU_FIRMWARE_DIR" ]] || {
    echo "pixel_boot_build_orange_gpu: firmware dir not found: $GPU_FIRMWARE_DIR" >&2
    exit 1
  }
  if [[ -z "$(find "$GPU_FIRMWARE_DIR" -mindepth 1 -print -quit)" ]]; then
    echo "pixel_boot_build_orange_gpu: firmware dir is empty: $GPU_FIRMWARE_DIR" >&2
    exit 1
  fi
  STAGED_LIB_PARENT_DIR="$WORK_DIR/lib-dir"
  STAGED_GPU_FIRMWARE_DIR="$STAGED_LIB_PARENT_DIR/firmware"
  mkdir -p "$STAGED_LIB_PARENT_DIR"
  stage_gpu_firmware_tree "$GPU_FIRMWARE_DIR" "$STAGED_GPU_FIRMWARE_DIR"
fi
if [[ "$INPUT_BOOTSTRAP" == "sunfish-touch-event2" ]]; then
  [[ -d "$INPUT_MODULE_DIR" ]] || {
    echo "pixel_boot_build_orange_gpu: input module dir not found: $INPUT_MODULE_DIR" >&2
    exit 1
  }
  STAGED_LIB_PARENT_DIR="${STAGED_LIB_PARENT_DIR:-$WORK_DIR/lib-dir}"
  STAGED_INPUT_MODULE_DIR="$STAGED_LIB_PARENT_DIR/modules"
  mkdir -p "$STAGED_LIB_PARENT_DIR"
  stage_input_module_tree "$INPUT_MODULE_DIR" "$STAGED_INPUT_MODULE_DIR"
fi
if [[ "$WIFI_BOOTSTRAP" == "sunfish-wlan0" ]]; then
  [[ -d "$WIFI_MODULE_DIR" ]] || {
    echo "pixel_boot_build_orange_gpu: wifi module dir not found: $WIFI_MODULE_DIR" >&2
    exit 1
  }
  STAGED_LIB_PARENT_DIR="${STAGED_LIB_PARENT_DIR:-$WORK_DIR/lib-dir}"
  STAGED_WIFI_MODULE_DIR="$STAGED_LIB_PARENT_DIR/modules"
  mkdir -p "$STAGED_LIB_PARENT_DIR"
  stage_wifi_module_tree "$WIFI_MODULE_DIR" "$STAGED_WIFI_MODULE_DIR"
fi

CONFIG_PATH="$WORK_DIR/$CONFIG_ENTRY"
render_config "$CONFIG_PATH"

build_args=(
  --stock-init
  --input "$INPUT_IMAGE"
  --key "$KEY_PATH"
  --output "$OUTPUT_IMAGE"
  --add "$CONFIG_ENTRY=$CONFIG_PATH"
)

if [[ "$HELLO_INIT_MODE" == "rust-bridge" ]]; then
  build_args+=(--replace "system/bin/init=$STAGED_HELLO_INIT_RUST_SHIM_BINARY")
  build_args+=(--add "$HELLO_INIT_RUST_CHILD_ENTRY=$STAGED_HELLO_INIT_BINARY")
else
  build_args+=(--replace "system/bin/init=$STAGED_HELLO_INIT_BINARY")
fi

if [[ "$PRELUDE" == "orange-init" ]]; then
  build_args+=(--add "orange-init=$ORANGE_INIT_BINARY")
fi

if [[ -n "$STAGED_GPU_BUNDLE_ARCHIVE" ]]; then
  if [[ "$ORANGE_GPU_BUNDLE_ARCHIVE_SOURCE" == "ramdisk" ]]; then
    build_args+=(--add "$ORANGE_GPU_BUNDLE_ARCHIVE_NAME=$STAGED_GPU_BUNDLE_ARCHIVE")
  fi
elif [[ -n "$STAGED_GPU_BUNDLE_DIR" ]]; then
  append_tree_add_specs "$STAGED_GPU_BUNDLE_DIR" "$PAYLOAD_ROOT" build_args
fi
if [[ -n "$STAGED_LIB_PARENT_DIR" ]]; then
  build_args+=(--add "lib=$STAGED_LIB_PARENT_DIR")
fi
if [[ "$FIRMWARE_BOOTSTRAP" == "ramdisk-lib-firmware" ]]; then
  append_tree_add_specs "$STAGED_GPU_FIRMWARE_DIR" "lib/firmware" build_args
fi
if [[ -n "$CAMERA_LINKER_CAPSULE_DIR" ]]; then
  for capsule_root in vendor system system_ext apex linkerconfig; do
    if [[ -e "$CAMERA_LINKER_CAPSULE_DIR/$capsule_root" ]]; then
      capsule_root_dir="$CAMERA_LINKER_CAPSULE_DIR/$capsule_root"
      if [[ "$capsule_root" == "vendor" && -n "$SHADOW_PROPERTY_SHIM_BINARY" ]]; then
        STAGED_CAMERA_LINKER_VENDOR_DIR="$WORK_DIR/camera-linker-vendor"
        rm -rf "$STAGED_CAMERA_LINKER_VENDOR_DIR"
        mkdir -p "$STAGED_CAMERA_LINKER_VENDOR_DIR"
        cp -Rp "$capsule_root_dir"/. "$STAGED_CAMERA_LINKER_VENDOR_DIR"/
        mkdir -p "$STAGED_CAMERA_LINKER_VENDOR_DIR/lib64"
        cp "$SHADOW_PROPERTY_SHIM_BINARY" "$STAGED_CAMERA_LINKER_VENDOR_DIR/lib64/libshadowprop.so"
        chmod 0755 "$STAGED_CAMERA_LINKER_VENDOR_DIR/lib64/libshadowprop.so" 2>/dev/null || true
        capsule_root_dir="$STAGED_CAMERA_LINKER_VENDOR_DIR"
      fi
      append_tree_upsert_specs "$capsule_root_dir" "$capsule_root" build_args
    fi
  done
fi
if [[ -n "${STAGED_INPUT_MODULE_DIR:-}" || -n "${STAGED_WIFI_MODULE_DIR:-}" ]]; then
  append_tree_add_specs "${STAGED_INPUT_MODULE_DIR:-$STAGED_WIFI_MODULE_DIR}" "lib/modules" build_args
fi

if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  build_args+=(--keep-work-dir)
fi

"$SCRIPT_DIR/pixel/pixel_boot_build.sh" "${build_args[@]}"
assert_built_boot_image_init_payload
write_metadata

printf 'Owned userspace mode: orange-gpu\n'
printf 'Shadow boot mode: %s\n' "$BOOT_MODE"
printf 'Root init path: preserve stock /init -> /system/bin/init symlink\n'
if [[ "$HELLO_INIT_MODE" == "rust-bridge" ]]; then
  printf 'System init mutation: replace system/bin/init with rust no_std PID1 shim\n'
else
  printf 'System init mutation: replace system/bin/init with hello-init PID 1\n'
fi
if [[ "$ORANGE_GPU_MODE" == "bundle-smoke" ]]; then
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in bundle-smoke mode from %s\n' "$PAYLOAD_IMAGE_PATH"
elif [[ "$ORANGE_GPU_MODE" == "orange-gpu-loop" ]]; then
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in repeated Vulkan render/present loop mode from %s\n' "$PAYLOAD_IMAGE_PATH"
elif [[ "$ORANGE_GPU_MODE" == "vulkan-instance-smoke" ]]; then
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict Vulkan instance mode from %s\n' "$PAYLOAD_IMAGE_PATH"
elif [[ "$ORANGE_GPU_MODE" == "raw-vulkan-instance-smoke" ]]; then
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict raw Vulkan instance-lifecycle mode from %s\n' "$PAYLOAD_IMAGE_PATH"
elif [[ "$ORANGE_GPU_MODE" == "firmware-probe-only" ]]; then
  printf 'Payload contract: hello-init runs the owned userspace firmware preflight only, paints a firmware checkpoint pattern, and exits before any KGSL open\n'
elif [[ "$ORANGE_GPU_MODE" == "timeout-control-smoke" ]]; then
  printf 'Payload contract: hello-init proves the timeout-classifier repaint path by painting the firmware checkpoint, then intentionally hanging before any KGSL open\n'
elif [[ "$ORANGE_GPU_MODE" == "camera-hal-link-probe" ]]; then
  printf 'Payload contract: rust hello-init directly probes /vendor/lib64/hw/camera.sm6150.so from Shadow boot userspace and persists link/HMI/module/open blockers under %s\n' "$(metadata_probe_summary_path_for_token "$RUN_TOKEN")"
elif [[ "$ORANGE_GPU_MODE" == "payload-partition-probe" ]]; then
  printf 'Payload contract: hello-init mounts /metadata and probes Shadow-owned payload manifest at %s\n' "$(payload_probe_manifest_path_for_token "$RUN_TOKEN")"
elif [[ "$ORANGE_GPU_MODE" == "wifi-linux-surface-probe" ]]; then
  printf 'Payload contract: rust hello-init directly inventories the Linux wlan0/nl80211/vendor-node surface from Shadow boot userspace and persists blockers under %s\n' "$(metadata_probe_summary_path_for_token "$RUN_TOKEN")"
elif [[ "$ORANGE_GPU_MODE" == "c-kgsl-open-readonly-smoke" ]]; then
  printf 'Payload contract: hello-init directly opens /dev/kgsl-3d0 read-only in the owned child process before any staged Rust bundle exec\n'
elif [[ "$ORANGE_GPU_MODE" == "c-kgsl-open-readonly-firmware-helper-smoke" ]]; then
  printf 'Payload contract: hello-init runs a minimal firmware sysfs helper loop while directly opening /dev/kgsl-3d0 read-only in the owned child process\n'
elif [[ "$ORANGE_GPU_MODE" == "c-kgsl-open-readonly-pid1-smoke" ]]; then
  printf 'Payload contract: hello-init directly opens /dev/kgsl-3d0 read-only in PID 1 before any fork or staged Rust bundle exec\n'
elif [[ "$ORANGE_GPU_MODE" == "compositor-scene" ]]; then
  printf 'Payload contract: hello-init launches /orange-gpu/shadow-session in shell-only compositor mode and requires a durable captured frame under %s\n' "$(metadata_compositor_frame_path_for_token "$RUN_TOKEN")"
elif [[ "$ORANGE_GPU_MODE" == "shell-session" ]]; then
  if [[ "$BOOT_MODE" == "product" ]]; then
    printf 'Payload contract: hello-init launches /orange-gpu/shadow-session in product shell-session mode, starts %s from the shell, and supervises it without lab watchdog reboot\n' "$SHELL_SESSION_START_APP_ID"
  else
    printf 'Payload contract: hello-init launches /orange-gpu/shadow-session in shell-session mode, starts %s from the shell, and requires a durable captured app frame under %s\n' "$SHELL_SESSION_START_APP_ID" "$(metadata_compositor_frame_path_for_token "$RUN_TOKEN")"
  fi
elif [[ "$ORANGE_GPU_MODE" == "shell-session-held" ]]; then
  printf 'Payload contract: hello-init launches /orange-gpu/shadow-session in held shell-session mode, starts %s from the shell, and treats watchdog recovery as success only after durable shell/app frame proof under %s\n' "$SHELL_SESSION_START_APP_ID" "$(metadata_compositor_frame_path_for_token "$RUN_TOKEN")"
elif [[ "$ORANGE_GPU_MODE" == "shell-session-runtime-touch-counter" ]]; then
  printf 'Payload contract: hello-init launches /orange-gpu/shadow-session in shell-session runtime touch-counter mode for counter and requires durable shell launch, runtime state-change evidence, and a post-touch frame under %s\n' "$(metadata_compositor_frame_path_for_token "$RUN_TOKEN")"
elif [[ "$ORANGE_GPU_MODE" == "app-direct-present" ]]; then
  printf 'Payload contract: hello-init launches /orange-gpu/shadow-session in app-only direct-present mode for %s and requires a durable captured frame under %s\n' "$APP_DIRECT_PRESENT_APP_ID" "$(metadata_compositor_frame_path_for_token "$RUN_TOKEN")"
elif [[ "$ORANGE_GPU_MODE" == "app-direct-present-touch-counter" ]]; then
  printf 'Payload contract: hello-init launches /orange-gpu/shadow-session in app-only direct-present touch-counter mode for rust-demo and requires a durable post-touch frame under %s\n' "$(metadata_compositor_frame_path_for_token "$RUN_TOKEN")"
elif [[ "$ORANGE_GPU_MODE" == "app-direct-present-runtime-touch-counter" ]]; then
  printf 'Payload contract: hello-init launches /orange-gpu/shadow-session in app-only direct-present runtime touch-counter mode for counter and requires durable runtime state-change evidence plus a post-touch frame under %s\n' "$(metadata_compositor_frame_path_for_token "$RUN_TOKEN")"
elif [[ "$ORANGE_GPU_MODE" == "raw-kgsl-open-readonly-smoke" ]]; then
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict raw KGSL read-only open mode from %s\n' "$PAYLOAD_IMAGE_PATH"
elif [[ "$ORANGE_GPU_MODE" == "raw-kgsl-getproperties-smoke" ]]; then
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict raw KGSL getproperties mode from %s\n' "$PAYLOAD_IMAGE_PATH"
elif [[ "$ORANGE_GPU_MODE" == "raw-vulkan-physical-device-count-query-exit-smoke" ]]; then
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict raw Vulkan physical-device-count-query-exit mode from %s\n' "$PAYLOAD_IMAGE_PATH"
elif [[ "$ORANGE_GPU_MODE" == "raw-vulkan-physical-device-count-query-no-destroy-smoke" ]]; then
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict raw Vulkan physical-device-count-query-no-destroy mode from %s\n' "$PAYLOAD_IMAGE_PATH"
elif [[ "$ORANGE_GPU_MODE" == "raw-vulkan-physical-device-count-query-smoke" ]]; then
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict raw Vulkan physical-device-count-query mode from %s\n' "$PAYLOAD_IMAGE_PATH"
elif [[ "$ORANGE_GPU_MODE" == "raw-vulkan-physical-device-count-smoke" ]]; then
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict raw Vulkan physical-device-count mode from %s\n' "$PAYLOAD_IMAGE_PATH"
elif [[ "$ORANGE_GPU_MODE" == "vulkan-enumerate-adapters-count-smoke" ]]; then
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict Vulkan raw adapter-enumeration-count mode from %s\n' "$PAYLOAD_IMAGE_PATH"
elif [[ "$ORANGE_GPU_MODE" == "vulkan-enumerate-adapters-smoke" ]]; then
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict Vulkan adapter-enumeration mode from %s\n' "$PAYLOAD_IMAGE_PATH"
elif [[ "$ORANGE_GPU_MODE" == "vulkan-adapter-smoke" ]]; then
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict Vulkan adapter mode from %s\n' "$PAYLOAD_IMAGE_PATH"
elif [[ "$ORANGE_GPU_MODE" == "vulkan-device-request-smoke" ]]; then
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict Vulkan device-request mode from %s\n' "$PAYLOAD_IMAGE_PATH"
elif [[ "$ORANGE_GPU_MODE" == "vulkan-device-smoke" ]]; then
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict Vulkan device/buffer mode from %s\n' "$PAYLOAD_IMAGE_PATH"
elif [[ "$ORANGE_GPU_MODE" == "vulkan-offscreen" ]]; then
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict Vulkan offscreen mode from %s\n' "$PAYLOAD_IMAGE_PATH"
else
  printf 'Payload contract: hello-init executes the staged shadow-gpu-smoke bundle from %s\n' "$PAYLOAD_IMAGE_PATH"
fi
if payload_partition_probe_mode; then
  printf 'Payload root: %s\n' "$(payload_probe_root_for_token "$RUN_TOKEN")"
  printf 'Metadata payload strategy: %s\n' "$PAYLOAD_PROBE_STRATEGY"
  printf 'Payload source: %s\n' "$PAYLOAD_PROBE_SOURCE"
  printf 'Metadata payload manifest path: %s\n' "$(payload_probe_manifest_path_for_token "$RUN_TOKEN")"
  printf 'Payload fallback path: %s\n' "$PAYLOAD_PROBE_FALLBACK_PATH"
else
  printf 'Payload root: %s\n' "$PAYLOAD_IMAGE_PATH"
  printf 'GPU bundle dir: %s\n' "$GPU_BUNDLE_DIR"
  printf 'GPU bundle staged dir: %s\n' "$STAGED_GPU_BUNDLE_DIR"
fi
if [[ -n "$STAGED_GPU_BUNDLE_ARCHIVE" ]]; then
  printf 'GPU bundle archive source: %s\n' "$ORANGE_GPU_BUNDLE_ARCHIVE_SOURCE"
  printf 'GPU bundle archive path: %s\n' "$ORANGE_GPU_BUNDLE_ARCHIVE_PATH"
  printf 'GPU bundle staged archive: %s\n' "$STAGED_GPU_BUNDLE_ARCHIVE"
  if [[ -n "$EXTERNAL_GPU_BUNDLE_ARCHIVE" ]]; then
    printf 'GPU bundle external archive: %s\n' "$EXTERNAL_GPU_BUNDLE_ARCHIVE"
  fi
fi
printf 'Hello-init mode: %s\n' "$HELLO_INIT_MODE"
if [[ "$HELLO_INIT_MODE" == "rust-bridge" ]]; then
  printf 'Rust shim path: /system/bin/init\n'
  printf 'Rust shim mode: %s\n' "$HELLO_INIT_RUST_SHIM_MODE"
  printf 'Rust shim binary: %s\n' "$HELLO_INIT_RUST_SHIM_BINARY"
  printf 'Rust child profile: %s\n' "$HELLO_INIT_RUST_CHILD_PROFILE"
  printf 'Rust child path: /%s\n' "$HELLO_INIT_RUST_CHILD_ENTRY"
  printf 'Rust child binary: %s\n' "$HELLO_INIT_BINARY"
fi
if [[ "$ORANGE_GPU_MODE" != "compositor-scene" && "$ORANGE_GPU_MODE" != "shell-session" && "$ORANGE_GPU_MODE" != "shell-session-held" && "$ORANGE_GPU_MODE" != "shell-session-runtime-touch-counter" && "$ORANGE_GPU_MODE" != "app-direct-present" && "$ORANGE_GPU_MODE" != "app-direct-present-touch-counter" && "$ORANGE_GPU_MODE" != "app-direct-present-runtime-touch-counter" && "$ORANGE_GPU_MODE" != "payload-partition-probe" ]]; then
  printf 'GPU exec path: %s/shadow-gpu-smoke\n' "$PAYLOAD_IMAGE_PATH"
fi
if ! payload_partition_probe_mode; then
  printf 'GPU loader path: %s/lib/ld-linux-aarch64.so.1\n' "$PAYLOAD_IMAGE_PATH"
fi
if [[ -n "$CAMERA_LINKER_CAPSULE_DIR" ]]; then
  if [[ "$ORANGE_GPU_MODE" == "wifi-linux-surface-probe" || "$WIFI_RUNTIME_NETWORK" == "true" ]]; then
    printf 'Wi-Fi linker capsule dir: %s\n' "$CAMERA_LINKER_CAPSULE_DIR"
  else
    printf 'Camera linker capsule dir: %s\n' "$CAMERA_LINKER_CAPSULE_DIR"
  fi
fi
if [[ -n "$CAMERA_HAL_BIONIC_PROBE_BINARY" ]]; then
  printf 'Camera HAL bionic probe: %s\n' "$CAMERA_HAL_BIONIC_PROBE_BINARY"
fi
if [[ "$ORANGE_GPU_MODE" == "camera-hal-link-probe" ]]; then
  printf 'Camera HAL camera id: %s\n' "$CAMERA_HAL_CAMERA_ID"
  printf 'Camera HAL call open: %s\n' "$CAMERA_HAL_CALL_OPEN"
fi
printf 'Orange GPU mode: %s\n' "$ORANGE_GPU_MODE"
if [[ "$ORANGE_GPU_MODE" == "bundle-smoke" ]]; then
  printf 'Bundle exec mode: bundle-smoke\n'
elif [[ "$ORANGE_GPU_MODE" == "orange-gpu-loop" ]]; then
  printf 'GPU proof: repeated Vulkan render/present updates with durable loop summary evidence\n'
elif [[ "$ORANGE_GPU_MODE" == "vulkan-instance-smoke" ]]; then
  printf 'GPU proof: strict Vulkan instance creation\n'
elif [[ "$ORANGE_GPU_MODE" == "raw-vulkan-instance-smoke" ]]; then
  printf 'GPU proof: strict raw Vulkan loader plus vkCreateInstance/vkDestroyInstance\n'
elif [[ "$ORANGE_GPU_MODE" == "firmware-probe-only" ]]; then
  printf 'GPU proof: owned userspace firmware preflight without any KGSL open\n'
elif [[ "$ORANGE_GPU_MODE" == "c-kgsl-open-readonly-smoke" ]]; then
  printf 'GPU proof: direct C-owned read-only open of /dev/kgsl-3d0 before any staged Rust bundle exec\n'
elif [[ "$ORANGE_GPU_MODE" == "c-kgsl-open-readonly-firmware-helper-smoke" ]]; then
  printf 'GPU proof: direct C-owned read-only open of /dev/kgsl-3d0 with a minimal userspace firmware-helper loop servicing /sys/class/firmware requests\n'
elif [[ "$ORANGE_GPU_MODE" == "c-kgsl-open-readonly-pid1-smoke" ]]; then
  printf 'GPU proof: direct C-owned read-only open of /dev/kgsl-3d0 in PID 1 before any fork or staged Rust bundle exec\n'
elif [[ "$ORANGE_GPU_MODE" == "raw-kgsl-open-readonly-smoke" ]]; then
  printf 'GPU proof: strict raw KGSL read-only open\n'
elif [[ "$ORANGE_GPU_MODE" == "raw-kgsl-getproperties-smoke" ]]; then
  printf 'GPU proof: strict raw KGSL device getproperty sequence\n'
elif [[ "$ORANGE_GPU_MODE" == "raw-vulkan-physical-device-count-query-exit-smoke" ]]; then
  printf 'GPU proof: strict raw Vulkan physical-device count query plus immediate exit 0 before summary\n'
elif [[ "$ORANGE_GPU_MODE" == "raw-vulkan-physical-device-count-query-no-destroy-smoke" ]]; then
  printf 'GPU proof: strict raw Vulkan physical-device count query without explicit destroy\n'
elif [[ "$ORANGE_GPU_MODE" == "raw-vulkan-physical-device-count-query-smoke" ]]; then
  printf 'GPU proof: strict raw Vulkan physical-device count query plus explicit destroy\n'
elif [[ "$ORANGE_GPU_MODE" == "raw-vulkan-physical-device-count-smoke" ]]; then
  printf 'GPU proof: strict raw Vulkan physical-device enumeration count\n'
elif [[ "$ORANGE_GPU_MODE" == "vulkan-enumerate-adapters-count-smoke" ]]; then
  printf 'GPU proof: strict Vulkan raw adapter enumeration count\n'
elif [[ "$ORANGE_GPU_MODE" == "vulkan-enumerate-adapters-smoke" ]]; then
  printf 'GPU proof: strict Vulkan adapter enumeration\n'
elif [[ "$ORANGE_GPU_MODE" == "vulkan-adapter-smoke" ]]; then
  printf 'GPU proof: strict Vulkan adapter selection\n'
elif [[ "$ORANGE_GPU_MODE" == "vulkan-device-request-smoke" ]]; then
  printf 'GPU proof: strict Vulkan device request\n'
elif [[ "$ORANGE_GPU_MODE" == "vulkan-device-smoke" ]]; then
  printf 'GPU proof: strict Vulkan buffer renderer bring-up\n'
elif [[ "$ORANGE_GPU_MODE" == "vulkan-offscreen" ]]; then
  printf 'GPU proof: strict Vulkan offscreen render\n'
elif [[ "$ORANGE_GPU_MODE" == "compositor-scene" ]]; then
  printf 'GPU proof: compositor-owned shell home frame captured durably through the Rust boot seam\n'
elif [[ "$ORANGE_GPU_MODE" == "shell-session" ]]; then
  printf 'GPU proof: shell-owned %s app launch frame captured durably through the Rust boot seam\n' "$SHELL_SESSION_START_APP_ID"
elif [[ "$ORANGE_GPU_MODE" == "shell-session-held" ]]; then
  if [[ "$ORANGE_GPU_TIMEOUT_ACTION" == "hold" ]]; then
    printf 'GPU proof: shell-owned %s app launch remains live after watchdog proof for the configured observation window and leaves durable shell/app frame evidence through the Rust boot seam\n' "$SHELL_SESSION_START_APP_ID"
  else
    printf 'GPU proof: shell-owned %s app launch remains live until watchdog recovery and leaves durable shell/app frame evidence through the Rust boot seam\n' "$SHELL_SESSION_START_APP_ID"
  fi
elif [[ "$ORANGE_GPU_MODE" == "shell-session-runtime-touch-counter" ]]; then
  if [[ "$APP_DIRECT_PRESENT_MANUAL_TOUCH" == "true" ]]; then
    printf 'GPU proof: shell-owned TypeScript counter launch increments from physical touch and presents a post-touch frame through the Rust boot seam\n'
  else
    printf 'GPU proof: shell-owned TypeScript counter launch increments from injected touch and presents a post-touch frame through the Rust boot seam\n'
  fi
elif [[ "$ORANGE_GPU_MODE" == "app-direct-present" ]]; then
  printf 'GPU proof: app-owned %s surface imported and presented with no shell through the Rust boot seam\n' "$APP_DIRECT_PRESENT_APP_ID"
elif [[ "$ORANGE_GPU_MODE" == "app-direct-present-touch-counter" ]]; then
  if [[ "$APP_DIRECT_PRESENT_MANUAL_TOUCH" == "true" ]]; then
    printf 'GPU proof: app-owned rust-demo surface increments from physical touch and presents a post-touch frame through the Rust boot seam\n'
  else
    printf 'GPU proof: app-owned rust-demo surface increments from injected touch and presents a post-touch frame through the Rust boot seam\n'
  fi
elif [[ "$ORANGE_GPU_MODE" == "app-direct-present-runtime-touch-counter" ]]; then
  if [[ "$APP_DIRECT_PRESENT_MANUAL_TOUCH" == "true" ]]; then
    printf 'GPU proof: app-owned TypeScript counter surface increments from physical touch and presents a post-touch frame through the Rust boot seam\n'
  else
    printf 'GPU proof: app-owned TypeScript counter surface increments from injected touch and presents a post-touch frame through the Rust boot seam\n'
  fi
elif payload_partition_probe_mode; then
  printf 'GPU scene: none\n'
else
  printf 'GPU scene: %s\n' "$(gpu_scene_value)"
fi
printf 'Prelude: %s\n' "$PRELUDE"
printf 'Prelude hold seconds: %s\n' "$PRELUDE_HOLD_SECS"
printf 'Orange GPU launch delay seconds: %s\n' "$ORANGE_GPU_LAUNCH_DELAY_SECS"
printf 'Orange GPU parent probe attempts: %s\n' "$ORANGE_GPU_PARENT_PROBE_ATTEMPTS"
printf 'Orange GPU parent probe interval seconds: %s\n' "$ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS"
printf 'Orange GPU metadata stage breadcrumb: %s\n' "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB"
printf 'Orange GPU metadata prune token root: %s\n' "$ORANGE_GPU_METADATA_PRUNE_TOKEN_ROOT"
printf 'Orange GPU firmware helper: %s\n' "$ORANGE_GPU_FIRMWARE_HELPER"
printf 'Orange GPU timeout action: %s\n' "$ORANGE_GPU_TIMEOUT_ACTION"
printf 'Orange GPU watchdog timeout seconds: %s\n' "$ORANGE_GPU_WATCHDOG_TIMEOUT_SECS"
if [[ "$ORANGE_GPU_PARENT_PROBE_ATTEMPTS" != "0" ]]; then
  printf 'Parent readiness probe scene: raw-vulkan-physical-device-count-query-exit-smoke\n'
fi
if [[ "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB" == "true" ]]; then
  printf 'Metadata stage path: %s\n' "$(metadata_stage_path_for_token "$RUN_TOKEN")"
  printf 'Metadata probe stage path: %s\n' "$(metadata_probe_stage_path_for_token "$RUN_TOKEN")"
  printf 'Metadata probe fingerprint path: %s\n' "$(metadata_probe_fingerprint_path_for_token "$RUN_TOKEN")"
  printf 'Metadata probe report path: %s\n' "$(metadata_probe_report_path_for_token "$RUN_TOKEN")"
  printf 'Metadata probe timeout class path: %s\n' "$(metadata_probe_timeout_class_path_for_token "$RUN_TOKEN")"
  printf 'Metadata probe summary path: %s\n' "$(metadata_probe_summary_path_for_token "$RUN_TOKEN")"
  if payload_probe_config_enabled; then
    printf 'Metadata payload root: %s\n' "$(payload_probe_root_for_token "$RUN_TOKEN")"
    printf 'Metadata payload manifest path: %s\n' "$(payload_probe_manifest_path_for_token "$RUN_TOKEN")"
  fi
  if [[ "$ORANGE_GPU_MODE" == "compositor-scene" || "$ORANGE_GPU_MODE" == "shell-session" || "$ORANGE_GPU_MODE" == "shell-session-held" || "$ORANGE_GPU_MODE" == "shell-session-runtime-touch-counter" || "$ORANGE_GPU_MODE" == "app-direct-present" || "$ORANGE_GPU_MODE" == "app-direct-present-touch-counter" || "$ORANGE_GPU_MODE" == "app-direct-present-runtime-touch-counter" ]]; then
    printf 'Metadata compositor frame path: %s\n' "$(metadata_compositor_frame_path_for_token "$RUN_TOKEN")"
  fi
fi
if [[ "$PRELUDE" == "orange-init" ]]; then
  printf 'Prelude payload path: /orange-init\n'
fi
printf 'Derived success postlude: %s\n' "$(success_postlude_value)"
if [[ "$(checkpoint_hold_seconds_value)" != "0" && "$PRELUDE" == "orange-init" ]]; then
  printf 'Visible checkpoint hold seconds: %s\n' "$(checkpoint_hold_seconds_value)"
  printf 'Visible sequence: orange %ss -> orange %ss -> orange %ss on success\n' \
    "$PRELUDE_HOLD_SECS" \
    "$(checkpoint_hold_seconds_value)" \
    "$HOLD_SECS"
fi
printf 'Config path: /%s\n' "$CONFIG_ENTRY"
printf 'Configured hold seconds: %s\n' "$HOLD_SECS"
printf 'Reboot target: %s\n' "$REBOOT_TARGET"
printf 'Run token: %s\n' "$RUN_TOKEN"
printf 'Dev mount style: %s\n' "$DEV_MOUNT"
printf 'Mount /dev: %s\n' "$MOUNT_DEV"
printf 'Mount proc: %s\n' "$MOUNT_PROC"
printf 'Mount sys: %s\n' "$MOUNT_SYS"
printf 'Log kmsg: %s\n' "$LOG_KMSG"
printf 'Log pmsg: %s\n' "$LOG_PMSG"
printf 'Firmware bootstrap: %s\n' "$FIRMWARE_BOOTSTRAP"
if [[ "$FIRMWARE_BOOTSTRAP" != "none" ]]; then
  printf 'GPU firmware dir: %s\n' "$GPU_FIRMWARE_DIR"
  printf 'GPU firmware staged dir: %s\n' "$STAGED_GPU_FIRMWARE_DIR"
fi
printf 'DRI bootstrap: %s\n' "$DRI_BOOTSTRAP"
printf 'Input bootstrap: %s\n' "$INPUT_BOOTSTRAP"
if [[ "$INPUT_BOOTSTRAP" != "none" ]]; then
  printf 'Input module dir: %s\n' "$INPUT_MODULE_DIR"
  printf 'Input module staged dir: %s\n' "$STAGED_INPUT_MODULE_DIR"
fi
printf 'Wi-Fi bootstrap: %s\n' "$WIFI_BOOTSTRAP"
if [[ "$WIFI_BOOTSTRAP" != "none" ]]; then
  printf 'Wi-Fi helper profile: %s\n' "$WIFI_HELPER_PROFILE"
  printf 'Wi-Fi supplicant probe: %s\n' "$WIFI_SUPPLICANT_PROBE"
  printf 'Wi-Fi module dir: %s\n' "$WIFI_MODULE_DIR"
  printf 'Wi-Fi module staged dir: %s\n' "$STAGED_WIFI_MODULE_DIR"
fi
printf 'Metadata path: %s\n' "$(hello_init_metadata_path "$OUTPUT_IMAGE")"
if [[ "$ORANGE_GPU_MODE" == "compositor-scene" ]]; then
  printf 'Compositor session path: %s\n' "$COMPOSITOR_SCENE_SESSION_PATH"
  printf 'Compositor binary path: %s\n' "$COMPOSITOR_SCENE_COMPOSITOR_PATH"
  printf 'Compositor startup config path: %s\n' "$COMPOSITOR_SCENE_STARTUP_CONFIG_PATH"
elif [[ "$ORANGE_GPU_MODE" == "shell-session" || "$ORANGE_GPU_MODE" == "shell-session-held" || "$ORANGE_GPU_MODE" == "shell-session-runtime-touch-counter" ]]; then
  printf 'Compositor session path: %s\n' "$COMPOSITOR_SCENE_SESSION_PATH"
  printf 'Compositor binary path: %s\n' "$COMPOSITOR_SCENE_COMPOSITOR_PATH"
  printf 'Compositor startup config path: %s\n' "$SHELL_SESSION_STARTUP_CONFIG_PATH"
  printf 'Shell session start app id: %s\n' "$SHELL_SESSION_START_APP_ID"
  printf 'App direct present id: %s\n' "$APP_DIRECT_PRESENT_APP_ID"
  printf 'App direct present client kind: %s\n' "$APP_DIRECT_PRESENT_CLIENT_KIND"
  printf 'App client path: %s\n' "$APP_DIRECT_PRESENT_CLIENT_PATH"
  printf 'App binary path: %s\n' "$APP_DIRECT_PRESENT_BINARY_PATH"
  if [[ "$APP_DIRECT_PRESENT_CLIENT_KIND" == "typescript" ]]; then
    printf 'App TypeScript renderer: %s\n' "$APP_DIRECT_PRESENT_TS_RENDERER"
    printf 'App runtime bundle env: %s\n' "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV"
    printf 'App runtime bundle path: %s\n' "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_PATH"
    printf 'App system binary path: %s\n' "$APP_DIRECT_PRESENT_SYSTEM_BINARY_PATH"
    printf 'App Linux audio bridge enabled: %s\n' "$ORANGE_GPU_ENABLE_LINUX_AUDIO"
  fi
  if [[ "$ORANGE_GPU_MODE" == "shell-session-runtime-touch-counter" ]]; then
    printf 'App direct present manual touch: %s\n' "$APP_DIRECT_PRESENT_MANUAL_TOUCH"
  fi
elif [[ "$ORANGE_GPU_MODE" == "app-direct-present" || "$ORANGE_GPU_MODE" == "app-direct-present-touch-counter" || "$ORANGE_GPU_MODE" == "app-direct-present-runtime-touch-counter" ]]; then
  printf 'Compositor session path: %s\n' "$COMPOSITOR_SCENE_SESSION_PATH"
  printf 'Compositor binary path: %s\n' "$COMPOSITOR_SCENE_COMPOSITOR_PATH"
  printf 'Compositor startup config path: %s\n' "$APP_DIRECT_PRESENT_STARTUP_CONFIG_PATH"
  printf 'App direct present id: %s\n' "$APP_DIRECT_PRESENT_APP_ID"
  printf 'App direct present client kind: %s\n' "$APP_DIRECT_PRESENT_CLIENT_KIND"
  printf 'App client path: %s\n' "$APP_DIRECT_PRESENT_CLIENT_PATH"
  printf 'App binary path: %s\n' "$APP_DIRECT_PRESENT_BINARY_PATH"
  if [[ "$APP_DIRECT_PRESENT_CLIENT_KIND" == "typescript" ]]; then
    printf 'App TypeScript renderer: %s\n' "$APP_DIRECT_PRESENT_TS_RENDERER"
    printf 'App runtime bundle env: %s\n' "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV"
    printf 'App runtime bundle path: %s\n' "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_PATH"
    printf 'App system binary path: %s\n' "$APP_DIRECT_PRESENT_SYSTEM_BINARY_PATH"
    printf 'App Linux audio bridge enabled: %s\n' "$ORANGE_GPU_ENABLE_LINUX_AUDIO"
  fi
  printf 'App direct present manual touch: %s\n' "$APP_DIRECT_PRESENT_MANUAL_TOUCH"
fi
if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  printf 'Kept orange-gpu workdir: %s\n' "$WORK_DIR"
fi
