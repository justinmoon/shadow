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
APP_DIRECT_PRESENT_CLIENT_LAUNCHER_BINARY="${PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_LAUNCHER_BIN:-}"
KEY_PATH="${AVB_TEST_KEY_PATH:-}"
OUTPUT_IMAGE="${PIXEL_BOOT_ORANGE_GPU_IMAGE:-}"
HELLO_INIT_MODE="${PIXEL_HELLO_INIT_MODE:-direct}"
HOLD_SECS="${PIXEL_HELLO_INIT_HOLD_SECS:-3}"
PRELUDE="${PIXEL_ORANGE_GPU_PRELUDE:-none}"
PRELUDE_HOLD_SECS="${PIXEL_ORANGE_GPU_PRELUDE_HOLD_SECS:-0}"
ORANGE_GPU_MODE="${PIXEL_ORANGE_GPU_MODE:-gpu-render}"
ORANGE_GPU_LAUNCH_DELAY_SECS="${PIXEL_ORANGE_GPU_LAUNCH_DELAY_SECS:-0}"
ORANGE_GPU_PARENT_PROBE_ATTEMPTS="${PIXEL_ORANGE_GPU_PARENT_PROBE_ATTEMPTS:-0}"
ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS="${PIXEL_ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS:-0}"
ORANGE_GPU_METADATA_STAGE_BREADCRUMB="${PIXEL_ORANGE_GPU_METADATA_STAGE_BREADCRUMB:-false}"
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
FIRMWARE_BOOTSTRAP="${PIXEL_ORANGE_GPU_FIRMWARE_BOOTSTRAP:-none}"
GPU_FIRMWARE_DIR="${PIXEL_ORANGE_GPU_FIRMWARE_DIR:-}"
KEEP_WORK_DIR=0
WORK_DIR=""
COMPOSITOR_SCENE_STARTUP_CONFIG=""
APP_DIRECT_PRESENT_STARTUP_CONFIG=""
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
APP_DIRECT_PRESENT_APP_ID="${PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_APP_ID:-rust-demo}"
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
ORANGE_GPU_BUNDLE_ARCHIVE_NAME="orange-gpu.tar.xz"
ORANGE_GPU_BUNDLE_ARCHIVE_PATH="/orange-gpu.tar.xz"
STAGED_GPU_BUNDLE_ARCHIVE=""
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
                                                    [--prelude none|orange-init]
                                                    [--prelude-hold-secs N]
                                                    [--orange-gpu-mode gpu-render|orange-gpu-loop|bundle-smoke|vulkan-instance-smoke|raw-vulkan-instance-smoke|firmware-probe-only|timeout-control-smoke|c-kgsl-open-readonly-smoke|c-kgsl-open-readonly-firmware-helper-smoke|c-kgsl-open-readonly-pid1-smoke|raw-kgsl-open-readonly-smoke|raw-kgsl-getproperties-smoke|raw-vulkan-physical-device-count-query-exit-smoke|raw-vulkan-physical-device-count-query-no-destroy-smoke|raw-vulkan-physical-device-count-query-smoke|raw-vulkan-physical-device-count-smoke|vulkan-enumerate-adapters-count-smoke|vulkan-enumerate-adapters-smoke|vulkan-adapter-smoke|vulkan-device-request-smoke|vulkan-device-smoke|vulkan-offscreen|compositor-scene|app-direct-present]
                                                    [--orange-gpu-launch-delay-secs N]
                                                    [--orange-gpu-parent-probe-attempts N]
                                                    [--orange-gpu-parent-probe-interval-secs N]
                                                    [--orange-gpu-metadata-stage-breadcrumb true|false]
                                                    [--orange-gpu-firmware-helper true|false]
                                                    [--orange-gpu-timeout-action reboot|panic]
                                                    [--orange-gpu-watchdog-timeout-secs N]
                                                    [--reboot-target TARGET]
                                                    [--run-token TOKEN]
                                                    [--dev-mount devtmpfs|tmpfs]
                                                    [--mount-dev true|false]
                                                    [--mount-proc true|false]
                                                    [--mount-sys true|false]
                                                    [--log-kmsg true|false]
                                                    [--log-pmsg true|false]
                                                    [--dri-bootstrap none|sunfish-card0-renderD128|sunfish-card0-renderD128-kgsl3d0]
                                                    [--firmware-bootstrap none|ramdisk-lib-firmware]
                                                    [--firmware-dir DIR]
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
offscreen render path, a compositor-owned shell scene, an app-owned
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

default_app_direct_present_client_launcher_binary() {
  printf '%s\n' "${PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_LAUNCHER_DEFAULT_BIN:-$(pixel_artifact_path app-direct-present-launcher)}"
}

resolve_app_direct_present_metadata() {
  local app_metadata

  if [[ "$APP_DIRECT_PRESENT_APP_ID" == "rust-demo" ]]; then
    APP_DIRECT_PRESENT_CLIENT_KIND="rust"
    APP_DIRECT_PRESENT_BINARY_NAME="shadow-rust-demo"
    APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV=""
    APP_DIRECT_PRESENT_RUNTIME_BUNDLE_NAME=""
    APP_DIRECT_PRESENT_TS_INPUT_PATH=""
  else
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
    if app.get("model") != "typescript":
        raise SystemExit(f"unsupported app-direct-present app model for {requested_app_id}: {app.get('model')}")
    runtime = app.get("runtime") or {}
    print(app.get("binaryName", ""))
    print(runtime.get("bundleEnv", ""))
    print(runtime.get("bundleFilename", ""))
    print(runtime.get("inputPath", ""))
    raise SystemExit(0)

raise SystemExit(f"unknown app-direct-present app id: {requested_app_id}")
PY
    )"
    APP_DIRECT_PRESENT_CLIENT_KIND="typescript"
    APP_DIRECT_PRESENT_BINARY_NAME="$(sed -n '1p' <<<"$app_metadata")"
    APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV="$(sed -n '2p' <<<"$app_metadata")"
    APP_DIRECT_PRESENT_RUNTIME_BUNDLE_NAME="$(sed -n '3p' <<<"$app_metadata")"
    APP_DIRECT_PRESENT_TS_INPUT_PATH="$(sed -n '4p' <<<"$app_metadata")"
  fi

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
    firmware-probe-only|timeout-control-smoke|c-kgsl-open-readonly-smoke|c-kgsl-open-readonly-firmware-helper-smoke|c-kgsl-open-readonly-pid1-smoke)
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

assert_orange_gpu_mode_word() {
  local value
  value="${1:?assert_orange_gpu_mode_word requires a value}"

  case "$value" in
    gpu-render|orange-gpu-loop|bundle-smoke|vulkan-instance-smoke|raw-vulkan-instance-smoke|firmware-probe-only|timeout-control-smoke|c-kgsl-open-readonly-smoke|c-kgsl-open-readonly-firmware-helper-smoke|c-kgsl-open-readonly-pid1-smoke|raw-kgsl-open-readonly-smoke|raw-kgsl-getproperties-smoke|raw-vulkan-physical-device-count-query-exit-smoke|raw-vulkan-physical-device-count-query-no-destroy-smoke|raw-vulkan-physical-device-count-query-smoke|raw-vulkan-physical-device-count-smoke|vulkan-enumerate-adapters-count-smoke|vulkan-enumerate-adapters-smoke|vulkan-adapter-smoke|vulkan-device-request-smoke|vulkan-device-smoke|vulkan-offscreen|compositor-scene|app-direct-present)
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: orange gpu mode must be gpu-render, orange-gpu-loop, bundle-smoke, vulkan-instance-smoke, raw-vulkan-instance-smoke, firmware-probe-only, timeout-control-smoke, c-kgsl-open-readonly-smoke, c-kgsl-open-readonly-firmware-helper-smoke, c-kgsl-open-readonly-pid1-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, vulkan-enumerate-adapters-count-smoke, vulkan-enumerate-adapters-smoke, vulkan-adapter-smoke, vulkan-device-request-smoke, vulkan-device-smoke, vulkan-offscreen, compositor-scene, or app-direct-present: $value" >&2
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
    reboot|panic)
      ;;
    *)
      echo "pixel_boot_build_orange_gpu: unsupported orange-gpu-timeout-action value: $value" >&2
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
    gpu-render|orange-gpu-loop|bundle-smoke|vulkan-instance-smoke|raw-vulkan-instance-smoke|firmware-probe-only|timeout-control-smoke|c-kgsl-open-readonly-smoke|c-kgsl-open-readonly-firmware-helper-smoke|c-kgsl-open-readonly-pid1-smoke|raw-kgsl-open-readonly-smoke|raw-kgsl-getproperties-smoke|raw-vulkan-physical-device-count-query-exit-smoke|raw-vulkan-physical-device-count-query-no-destroy-smoke|raw-vulkan-physical-device-count-query-smoke|raw-vulkan-physical-device-count-smoke|vulkan-enumerate-adapters-count-smoke|vulkan-enumerate-adapters-smoke|vulkan-adapter-smoke|vulkan-device-request-smoke|vulkan-device-smoke|vulkan-offscreen|compositor-scene|app-direct-present)
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
  if [[ -n "$STAGED_GPU_BUNDLE_ARCHIVE" ]]; then
    printf 'orange_gpu_bundle_archive_path=%s\n' "$ORANGE_GPU_BUNDLE_ARCHIVE_PATH" >>"$output_path"
  fi
  if [[ "$ORANGE_GPU_MODE" == "app-direct-present" ]]; then
    printf 'app_direct_present_app_id=%s\n' "$APP_DIRECT_PRESENT_APP_ID" >>"$output_path"
    if [[ -n "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV" ]]; then
      printf 'app_direct_present_runtime_bundle_env=%s\n' "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV" >>"$output_path"
      printf 'app_direct_present_runtime_bundle_path=%s\n' "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_PATH" >>"$output_path"
    fi
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
    "$(metadata_compositor_frame_path_for_token "$RUN_TOKEN")" <<'PY'
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
    frame_artifact_path,
) = sys.argv[1:11]
env_assignments = []
if client_kind == "rust":
    env_assignments.append({"key": "SHADOW_RUNTIME_CAMERA_ALLOW_MOCK", "value": "1"})
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

stage_app_direct_present_rust_bundle() {
  local output_dir app_package_ref app_out_link
  output_dir="${1:?stage_app_direct_present_rust_bundle requires an output dir}"

  app_package_ref="$(repo_root)#packages.${PIXEL_GUEST_BUILD_SYSTEM:-aarch64-linux}.shadow-rust-demo"
  app_out_link="$(pixel_dir)/shadow-rust-demo-aarch64-linux-result"
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
  local blitz_package_ref blitz_out_link blitz_stage_dir
  local system_package_ref system_out_link system_stage_dir
  output_dir="${1:?stage_app_direct_present_typescript_bundle requires an output dir}"

  bundle_json="$(
    "$SCRIPT_DIR/runtime_build_artifacts.sh" \
      --profile single \
      --app-id app \
      --input "$APP_DIRECT_PRESENT_TS_INPUT_PATH" \
      --cache-dir "$APP_DIRECT_PRESENT_TS_CACHE_DIR"
  )"
  printf '%s\n' "$bundle_json"
  bundle_source_path="$(
    printf '%s\n' "$bundle_json" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(data["apps"]["app"]["effectiveBundlePath"])
'
  )"
  [[ -f "$bundle_source_path" ]] || {
    echo "pixel_boot_build_orange_gpu: TypeScript runtime bundle source not found: $bundle_source_path" >&2
    exit 1
  }

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
  chmod 0644 "$output_dir/$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_NAME"
  strip_app_direct_present_elf_files "$output_dir"
  rm -rf "$blitz_stage_dir" "$system_stage_dir"
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
    "$HOLD_SECS" \
    "$PRELUDE" \
    "$PRELUDE_HOLD_SECS" \
    "$ORANGE_GPU_MODE" \
    "$ORANGE_GPU_LAUNCH_DELAY_SECS" \
    "$ORANGE_GPU_PARENT_PROBE_ATTEMPTS" \
    "$ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS" \
    "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB" \
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
    "$FIRMWARE_BOOTSTRAP" \
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
    "$STAGED_GPU_BUNDLE_ARCHIVE" \
    "$APP_DIRECT_PRESENT_APP_ID" \
    "$APP_DIRECT_PRESENT_CLIENT_KIND" \
    "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_ENV" \
    "$APP_DIRECT_PRESENT_RUNTIME_BUNDLE_PATH" \
    "$APP_DIRECT_PRESENT_TS_RENDERER" <<'PY'
import json
import sys
from pathlib import Path

(
    metadata_path,
    image_path,
    bundle_dir,
    hold_seconds,
    prelude,
    prelude_hold_seconds,
    orange_gpu_mode,
    orange_gpu_launch_delay_secs,
    orange_gpu_parent_probe_attempts,
    orange_gpu_parent_probe_interval_secs,
    orange_gpu_metadata_stage_breadcrumb,
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
    firmware_bootstrap,
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
    staged_gpu_bundle_archive,
    app_direct_present_app_id,
    app_direct_present_client_kind,
    app_direct_present_runtime_bundle_env,
    app_direct_present_runtime_bundle_path,
    app_direct_present_typescript_renderer,
) = sys.argv[1:]


def parse_bool(raw: str) -> bool:
    return raw == "true"


payload_json = {
    "kind": "orange_gpu_build",
    "image": image_path,
    "payload": "orange-gpu",
    "orange_gpu_mode": orange_gpu_mode,
    "orange_gpu_launch_delay_secs": int(orange_gpu_launch_delay_secs),
    "orange_gpu_parent_probe_attempts": int(orange_gpu_parent_probe_attempts),
    "orange_gpu_parent_probe_interval_secs": int(orange_gpu_parent_probe_interval_secs),
    "orange_gpu_metadata_stage_breadcrumb": parse_bool(orange_gpu_metadata_stage_breadcrumb),
    "orange_gpu_firmware_helper": parse_bool(orange_gpu_firmware_helper),
    "orange_gpu_timeout_action": orange_gpu_timeout_action,
    "orange_gpu_watchdog_timeout_secs": int(orange_gpu_watchdog_timeout_secs),
    "gpu_bundle_dir": bundle_dir,
    "gpu_bundle_archive_path": (
        orange_gpu_bundle_archive_path if staged_gpu_bundle_archive else ""
    ),
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
        and orange_gpu_mode in {"compositor-scene", "app-direct-present"}
        else ""
    ),
}
if orange_gpu_mode == "app-direct-present":
    payload_json["app_direct_present_app_id"] = app_direct_present_app_id
    payload_json["app_direct_present_client_kind"] = app_direct_present_client_kind
    payload_json["app_direct_present_runtime_bundle_env"] = app_direct_present_runtime_bundle_env
    payload_json["app_direct_present_runtime_bundle_path"] = app_direct_present_runtime_bundle_path
    if app_direct_present_client_kind == "typescript":
        payload_json["app_direct_present_typescript_renderer"] = (
            app_direct_present_typescript_renderer
        )

Path(metadata_path).write_text(
    json.dumps(payload_json, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

append_tree_add_specs() {
  local host_root archive_root build_args_name
  host_root="${1:?append_tree_add_specs requires a host root}"
  archive_root="${2:?append_tree_add_specs requires an archive root}"
  build_args_name="${3:?append_tree_add_specs requires a build-args array name}"
  local -n build_args_ref="$build_args_name"
  local relative_path

  build_args_ref+=(--add "$archive_root=$host_root")
  while IFS= read -r relative_path; do
    [[ -n "$relative_path" ]] || continue
    build_args_ref+=(--add "$archive_root/$relative_path=$host_root/$relative_path")
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
    --firmware-bootstrap)
      FIRMWARE_BOOTSTRAP="${2:?missing value for --firmware-bootstrap}"
      shift 2
      ;;
    --firmware-dir)
      GPU_FIRMWARE_DIR="${2:?missing value for --firmware-dir}"
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
assert_prelude_word "$PRELUDE"
assert_orange_gpu_mode_word "$ORANGE_GPU_MODE"
if [[ "$ORANGE_GPU_MODE" == "app-direct-present" ]]; then
  assert_safe_word app-direct-present-app-id "$APP_DIRECT_PRESENT_APP_ID" 64
  resolve_app_direct_present_metadata
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

if [[ "$ORANGE_GPU_MODE" == "c-kgsl-open-readonly-firmware-helper-smoke" && "$MOUNT_SYS" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: c-kgsl-open-readonly-firmware-helper-smoke requires --mount-sys true so hello-init can service /sys/class/firmware requests" >&2
  exit 1
fi
if [[ "$ORANGE_GPU_MODE" == "c-kgsl-open-readonly-firmware-helper-smoke" && "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: c-kgsl-open-readonly-firmware-helper-smoke requires --orange-gpu-metadata-stage-breadcrumb true so helper progress survives recovery" >&2
  exit 1
fi
if [[ "$ORANGE_GPU_MODE" =~ ^(compositor-scene|app-direct-present)$ && "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: $ORANGE_GPU_MODE requires --orange-gpu-metadata-stage-breadcrumb true so the captured frame survives recovery" >&2
  exit 1
fi
if [[ "$ORANGE_GPU_MODE" =~ ^(compositor-scene|app-direct-present)$ && "$ORANGE_GPU_FIRMWARE_HELPER" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: $ORANGE_GPU_MODE requires --orange-gpu-firmware-helper true so the session stays on the signed-off GPU seam" >&2
  exit 1
fi
assert_bool_word orange-gpu-metadata-stage-breadcrumb "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB"
assert_bool_word orange-gpu-firmware-helper "$ORANGE_GPU_FIRMWARE_HELPER"
assert_timeout_action_word "$ORANGE_GPU_TIMEOUT_ACTION"
assert_hello_init_mode_word "$HELLO_INIT_MODE"
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
if [[ "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB" == "true" && "$MOUNT_DEV" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: orange gpu metadata stage breadcrumb requires mount-dev=true" >&2
  exit 1
fi
if [[ "$ORANGE_GPU_FIRMWARE_HELPER" == "true" && "$MOUNT_SYS" != "true" ]]; then
  echo "pixel_boot_build_orange_gpu: orange-gpu-firmware-helper requires --mount-sys true" >&2
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
if [[ -z "$DRI_BOOTSTRAP" ]]; then
  if [[ "$PRELUDE" == "orange-init" && "$ORANGE_GPU_MODE" == "bundle-smoke" ]]; then
    DRI_BOOTSTRAP="sunfish-card0-renderD128"
  elif [[ "$ORANGE_GPU_MODE" == "bundle-smoke" ]]; then
    DRI_BOOTSTRAP="none"
  else
    DRI_BOOTSTRAP="sunfish-card0-renderD128-kgsl3d0"
  fi
fi
assert_dri_bootstrap_word "$DRI_BOOTSTRAP"
if [[ -z "$RUN_TOKEN" ]]; then
  RUN_TOKEN="$(generate_run_token)"
fi
assert_safe_word run-token "$RUN_TOKEN" 63

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
    HELLO_INIT_BINARY="$(default_hello_init_binary)"
    "$SCRIPT_DIR/pixel/pixel_build_hello_init.sh" --output "$HELLO_INIT_BINARY"
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
  assert_hello_variant "$HELLO_INIT_BINARY"
fi

if [[ "$ORANGE_GPU_MODE" == "compositor-scene" || "$ORANGE_GPU_MODE" == "app-direct-present" ]]; then
  if [[ -z "$SHADOW_SESSION_BINARY" ]]; then
    SHADOW_SESSION_BINARY="$(pixel_artifact_path shadow-session)"
    build_or_copy_linux_static_device_binary \
      "shadow-session-device" \
      "$SHADOW_SESSION_BINARY" \
      "shadow-session"
  fi
  if [[ -z "$SHADOW_COMPOSITOR_BINARY" ]]; then
    SHADOW_COMPOSITOR_BINARY="$(pixel_artifact_path shadow-compositor-guest)"
    build_or_copy_linux_static_device_binary \
      "shadow-compositor-guest-device" \
      "$SHADOW_COMPOSITOR_BINARY" \
      "shadow-compositor-guest"
  fi
  [[ -f "$SHADOW_SESSION_BINARY" ]] || {
    echo "pixel_boot_build_orange_gpu: shadow-session binary not found: $SHADOW_SESSION_BINARY" >&2
    exit 1
  }
  [[ -f "$SHADOW_COMPOSITOR_BINARY" ]] || {
    echo "pixel_boot_build_orange_gpu: shadow-compositor-guest binary not found: $SHADOW_COMPOSITOR_BINARY" >&2
    exit 1
  }
  assert_static_device_binary "$SHADOW_SESSION_BINARY" "shadow-session"
  assert_static_device_binary "$SHADOW_COMPOSITOR_BINARY" "shadow-compositor-guest"
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

if [[ -z "$GPU_BUNDLE_DIR" ]]; then
  GPU_BUNDLE_DIR="$(default_gpu_bundle_dir)"
  "$SCRIPT_DIR/pixel/pixel_prepare_gpu_smoke_bundle.sh" >/dev/null
fi

assert_gpu_bundle_variant "$GPU_BUNDLE_DIR"
STAGED_GPU_BUNDLE_DIR="$WORK_DIR/orange-gpu-bundle"
STAGED_GPU_FIRMWARE_PARENT_DIR=""
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
elif [[ "$ORANGE_GPU_MODE" == "app-direct-present" ]]; then
  APP_DIRECT_PRESENT_STARTUP_CONFIG="$WORK_DIR/$APP_DIRECT_PRESENT_STARTUP_CONFIG_NAME"
  stage_app_direct_present_client_bundle "$STAGED_GPU_BUNDLE_DIR/$APP_DIRECT_PRESENT_BUNDLE_DIR_NAME"
  merge_app_direct_present_typescript_runtime_libs "$STAGED_GPU_BUNDLE_DIR"
  prune_app_direct_present_diagnostic_payloads "$STAGED_GPU_BUNDLE_DIR"
  render_app_direct_present_startup_config "$APP_DIRECT_PRESENT_STARTUP_CONFIG"
  cp "$SHADOW_SESSION_BINARY" "$STAGED_GPU_BUNDLE_DIR/shadow-session"
  chmod 0755 "$STAGED_GPU_BUNDLE_DIR/shadow-session"
  cp "$SHADOW_COMPOSITOR_BINARY" "$STAGED_GPU_BUNDLE_DIR/shadow-compositor-guest"
  chmod 0755 "$STAGED_GPU_BUNDLE_DIR/shadow-compositor-guest"
  cp "$APP_DIRECT_PRESENT_STARTUP_CONFIG" "$STAGED_GPU_BUNDLE_DIR/$APP_DIRECT_PRESENT_STARTUP_CONFIG_NAME"
fi

strip_staged_elf_files "$STAGED_GPU_BUNDLE_DIR"
if [[ "$ORANGE_GPU_MODE" == "app-direct-present" ]]; then
  STAGED_GPU_BUNDLE_ARCHIVE="$WORK_DIR/$ORANGE_GPU_BUNDLE_ARCHIVE_NAME"
  archive_app_direct_present_gpu_bundle "$STAGED_GPU_BUNDLE_DIR" "$STAGED_GPU_BUNDLE_ARCHIVE"
fi

STAGED_GPU_FIRMWARE_DIR=""
if [[ "$FIRMWARE_BOOTSTRAP" == "ramdisk-lib-firmware" ]]; then
  [[ -d "$GPU_FIRMWARE_DIR" ]] || {
    echo "pixel_boot_build_orange_gpu: firmware dir not found: $GPU_FIRMWARE_DIR" >&2
    exit 1
  }
  if [[ -z "$(find "$GPU_FIRMWARE_DIR" -mindepth 1 -print -quit)" ]]; then
    echo "pixel_boot_build_orange_gpu: firmware dir is empty: $GPU_FIRMWARE_DIR" >&2
    exit 1
  fi
  STAGED_GPU_FIRMWARE_PARENT_DIR="$WORK_DIR/lib-dir"
  STAGED_GPU_FIRMWARE_DIR="$WORK_DIR/lib-firmware"
  mkdir -p "$STAGED_GPU_FIRMWARE_PARENT_DIR"
  stage_gpu_firmware_tree "$GPU_FIRMWARE_DIR" "$STAGED_GPU_FIRMWARE_DIR"
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
  build_args+=(--replace "system/bin/init=$HELLO_INIT_RUST_SHIM_BINARY")
  build_args+=(--add "$HELLO_INIT_RUST_CHILD_ENTRY=$HELLO_INIT_BINARY")
else
  build_args+=(--replace "system/bin/init=$HELLO_INIT_BINARY")
fi

if [[ "$PRELUDE" == "orange-init" ]]; then
  build_args+=(--add "orange-init=$ORANGE_INIT_BINARY")
fi

if [[ -n "$STAGED_GPU_BUNDLE_ARCHIVE" ]]; then
  build_args+=(--add "$ORANGE_GPU_BUNDLE_ARCHIVE_NAME=$STAGED_GPU_BUNDLE_ARCHIVE")
else
  append_tree_add_specs "$STAGED_GPU_BUNDLE_DIR" "$PAYLOAD_ROOT" build_args
fi
if [[ "$FIRMWARE_BOOTSTRAP" == "ramdisk-lib-firmware" ]]; then
  build_args+=(--add "lib=$STAGED_GPU_FIRMWARE_PARENT_DIR")
  append_tree_add_specs "$STAGED_GPU_FIRMWARE_DIR" "lib/firmware" build_args
fi

if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  build_args+=(--keep-work-dir)
fi

"$SCRIPT_DIR/pixel/pixel_boot_build.sh" "${build_args[@]}"
write_metadata

printf 'Owned userspace mode: orange-gpu\n'
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
elif [[ "$ORANGE_GPU_MODE" == "c-kgsl-open-readonly-smoke" ]]; then
  printf 'Payload contract: hello-init directly opens /dev/kgsl-3d0 read-only in the owned child process before any staged Rust bundle exec\n'
elif [[ "$ORANGE_GPU_MODE" == "c-kgsl-open-readonly-firmware-helper-smoke" ]]; then
  printf 'Payload contract: hello-init runs a minimal firmware sysfs helper loop while directly opening /dev/kgsl-3d0 read-only in the owned child process\n'
elif [[ "$ORANGE_GPU_MODE" == "c-kgsl-open-readonly-pid1-smoke" ]]; then
  printf 'Payload contract: hello-init directly opens /dev/kgsl-3d0 read-only in PID 1 before any fork or staged Rust bundle exec\n'
elif [[ "$ORANGE_GPU_MODE" == "compositor-scene" ]]; then
  printf 'Payload contract: hello-init launches /orange-gpu/shadow-session in shell-only compositor mode and requires a durable captured frame under %s\n' "$(metadata_compositor_frame_path_for_token "$RUN_TOKEN")"
elif [[ "$ORANGE_GPU_MODE" == "app-direct-present" ]]; then
  printf 'Payload contract: hello-init launches /orange-gpu/shadow-session in app-only direct-present mode for %s and requires a durable captured frame under %s\n' "$APP_DIRECT_PRESENT_APP_ID" "$(metadata_compositor_frame_path_for_token "$RUN_TOKEN")"
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
printf 'Payload root: %s\n' "$PAYLOAD_IMAGE_PATH"
printf 'GPU bundle dir: %s\n' "$GPU_BUNDLE_DIR"
printf 'GPU bundle staged dir: %s\n' "$STAGED_GPU_BUNDLE_DIR"
if [[ -n "$STAGED_GPU_BUNDLE_ARCHIVE" ]]; then
  printf 'GPU bundle archive path: %s\n' "$ORANGE_GPU_BUNDLE_ARCHIVE_PATH"
  printf 'GPU bundle staged archive: %s\n' "$STAGED_GPU_BUNDLE_ARCHIVE"
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
if [[ "$ORANGE_GPU_MODE" != "app-direct-present" ]]; then
  printf 'GPU exec path: %s/shadow-gpu-smoke\n' "$PAYLOAD_IMAGE_PATH"
fi
printf 'GPU loader path: %s/lib/ld-linux-aarch64.so.1\n' "$PAYLOAD_IMAGE_PATH"
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
elif [[ "$ORANGE_GPU_MODE" == "app-direct-present" ]]; then
  printf 'GPU proof: app-owned %s surface imported and presented with no shell through the Rust boot seam\n' "$APP_DIRECT_PRESENT_APP_ID"
else
  printf 'GPU scene: %s\n' "$(gpu_scene_value)"
fi
printf 'Prelude: %s\n' "$PRELUDE"
printf 'Prelude hold seconds: %s\n' "$PRELUDE_HOLD_SECS"
printf 'Orange GPU launch delay seconds: %s\n' "$ORANGE_GPU_LAUNCH_DELAY_SECS"
printf 'Orange GPU parent probe attempts: %s\n' "$ORANGE_GPU_PARENT_PROBE_ATTEMPTS"
printf 'Orange GPU parent probe interval seconds: %s\n' "$ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS"
printf 'Orange GPU metadata stage breadcrumb: %s\n' "$ORANGE_GPU_METADATA_STAGE_BREADCRUMB"
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
  if [[ "$ORANGE_GPU_MODE" == "compositor-scene" || "$ORANGE_GPU_MODE" == "app-direct-present" ]]; then
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
printf 'Metadata path: %s\n' "$(hello_init_metadata_path "$OUTPUT_IMAGE")"
if [[ "$ORANGE_GPU_MODE" == "compositor-scene" ]]; then
  printf 'Compositor session path: %s\n' "$COMPOSITOR_SCENE_SESSION_PATH"
  printf 'Compositor binary path: %s\n' "$COMPOSITOR_SCENE_COMPOSITOR_PATH"
  printf 'Compositor startup config path: %s\n' "$COMPOSITOR_SCENE_STARTUP_CONFIG_PATH"
elif [[ "$ORANGE_GPU_MODE" == "app-direct-present" ]]; then
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
  fi
fi
if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  printf 'Kept orange-gpu workdir: %s\n' "$WORK_DIR"
fi
