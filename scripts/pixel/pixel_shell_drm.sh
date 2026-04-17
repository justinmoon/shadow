#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./pixel_camera_runtime_common.sh
source "$SCRIPT_DIR/lib/pixel_camera_runtime_common.sh"
# shellcheck source=./session_apps.sh
source "$SCRIPT_DIR/lib/session_apps.sh"
ensure_bootimg_shell "$@"

shell_start_app_id=""
shell_stage_only=0
shell_run_only=0
camera_runtime_enabled=1

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app)
        shell_start_app_id="${2:?pixel_shell_drm: --app requires a value}"
        shift 2
        ;;
      --stage-only)
        shell_stage_only=1
        shift
        ;;
      --run-only)
        shell_run_only=1
        shift
        ;;
      --camera-runtime)
        camera_runtime_enabled=1
        shift
        ;;
      --no-camera-runtime)
        camera_runtime_enabled=0
        shift
        ;;
      *)
        echo "pixel_shell_drm: unsupported argument $1" >&2
        exit 64
        ;;
    esac
  done
}

parse_args "$@"

serial="$(pixel_resolve_serial)"
pixel_require_host_lock "$serial" "$0" "$@"
camera_endpoint=""
camera_start_command=""
camera_cleanup_command=""

if (( shell_stage_only == 1 && shell_run_only == 1 )); then
  echo "pixel_shell_drm: --run-only cannot be combined with --stage-only" >&2
  exit 64
fi
if [[ -n "$shell_start_app_id" ]]; then
  if shadow_session_app_is_shell "$shell_start_app_id"; then
    shell_start_app_id=""
  elif ! shadow_session_app_supports_auto_open "$shell_start_app_id"; then
    echo "pixel_shell_drm: unsupported --app $shell_start_app_id; expected $(shadow_session_apps_usage)" >&2
    exit 64
  fi
fi
if (( camera_runtime_enabled == 1 )); then
  camera_endpoint="$(pixel_camera_runtime_endpoint)"
  camera_start_command="$(pixel_camera_runtime_start_command "$camera_endpoint")"
  camera_cleanup_command="$(pixel_camera_runtime_cleanup_command)"
fi

default_mesa_tarball="$(pixel_dir)/vendor/mesa-for-android-container_26.1.0-devel-20260404_debian_trixie_arm64.tar.gz"
if [[ -z "${PIXEL_VENDOR_MESA_TARBALL-}" && -f "$default_mesa_tarball" ]]; then
  PIXEL_VENDOR_MESA_TARBALL="$default_mesa_tarball"
  export PIXEL_VENDOR_MESA_TARBALL
fi
if [[ -z "${PIXEL_VENDOR_TURNIP_LIB_PATH-}" && -z "${PIXEL_VENDOR_TURNIP_TARBALL-}" ]]; then
  PIXEL_VENDOR_TURNIP_LIB_PATH="$(pixel_ensure_pinned_turnip_lib)"
  export PIXEL_VENDOR_TURNIP_LIB_PATH
fi
# Deterministic default. Never infer renderer mode from optional GPU assets.
# CPU stays opt-in through PIXEL_SHELL_RENDERER=cpu.
: "${PIXEL_SHELL_RENDERER:=gpu_softbuffer}"

build_include_guest_client=1
if [[ "$PIXEL_SHELL_RENDERER" == "gpu_softbuffer" ]]; then
  build_include_guest_client=0
fi

if (( shell_run_only == 0 )); then
  PIXEL_BUILD_INCLUDE_GUEST_CLIENT="$build_include_guest_client" \
    "$SCRIPT_DIR/pixel/pixel_build.sh"
fi

guest_client_artifact="$(pixel_guest_client_artifact)"
guest_client_dst="$(pixel_guest_client_dst)"
runtime_prepare_extra_env=()

case "$PIXEL_SHELL_RENDERER" in
  cpu)
    if (( shell_run_only == 0 )); then
      PIXEL_BLITZ_RENDERER=cpu "$SCRIPT_DIR/pixel/pixel_build_guest_client.sh"
    fi
    ;;
  gpu_softbuffer)
    if (( shell_run_only == 0 )); then
      "$SCRIPT_DIR/pixel/pixel_prepare_blitz_demo_gpu_softbuffer_bundle.sh"
    fi
    guest_client_artifact="$(pixel_artifact_path run-shadow-blitz-demo-gpu-softbuffer)"
    guest_client_dst="$(pixel_runtime_linux_dir)/run-shadow-blitz-demo"
    runtime_prepare_extra_env=(
      "PIXEL_RUNTIME_EXTRA_BUNDLE_ARTIFACT_DIR=$(pixel_artifact_path shadow-blitz-demo-gnu)"
    )
    ;;
  *)
    echo "pixel_shell_drm: unsupported PIXEL_SHELL_RENDERER: $PIXEL_SHELL_RENDERER" >&2
    exit 1
    ;;
esac

if (( shell_run_only == 0 )); then
  env "${runtime_prepare_extra_env[@]}" "$SCRIPT_DIR/pixel/pixel_prepare_shell_runtime_artifacts.sh"
  if (( camera_runtime_enabled == 1 )); then
    pixel_camera_runtime_prepare_helper "$serial"
  fi
fi

PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS="${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS-}"
PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS-}"
extra_guest_env="${PIXEL_SHELL_EXTRA_GUEST_CLIENT_ENV-}"
extra_session_env="${PIXEL_SHELL_EXTRA_SESSION_ENV-}"
extra_required_markers="${PIXEL_SHELL_EXTRA_REQUIRED_MARKERS-}"
runtime_mesa_cache_dir="$(pixel_runtime_mesa_cache_dir)"
expect_client_process=''

shell_guest_env=$(
  cat <<EOF
SHADOW_BLITZ_RUNTIME_POLL_INTERVAL_MS=${SHADOW_BLITZ_RUNTIME_POLL_INTERVAL_MS:-16}
SHADOW_BLITZ_DEBUG_OVERLAY=0
SHADOW_BLITZ_ANDROID_FONTS=${SHADOW_BLITZ_ANDROID_FONTS:-curated}
SHADOW_BLITZ_SOFTWARE_KEYBOARD=${SHADOW_BLITZ_SOFTWARE_KEYBOARD:-1}
$(pixel_runtime_linux_user_env_lines)
EOF
)
if (( camera_runtime_enabled == 1 )); then
  shell_guest_env="${shell_guest_env}"$'\n'"SHADOW_RUNTIME_CAMERA_ENDPOINT=$camera_endpoint"
fi
if [[ -n "$PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS" ]]; then
  shell_guest_env="${shell_guest_env}"$'\n'"SHADOW_BLITZ_RUNTIME_EXIT_DELAY_MS=$PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS"
fi
if [[ "$PIXEL_SHELL_RENDERER" == "gpu_softbuffer" ]]; then
  shell_guest_env="${shell_guest_env}"$'\n'"MESA_SHADER_CACHE_DIR=$runtime_mesa_cache_dir"
  if [[ -n "${PIXEL_VENDOR_TURNIP_TARBALL-}" || -n "${PIXEL_VENDOR_TURNIP_LIB_PATH-}" ]]; then
    shell_guest_env="${shell_guest_env}"$'\n'"WGPU_BACKEND=${WGPU_BACKEND:-vulkan}"
    shell_guest_env="${shell_guest_env}"$'\n'"MESA_LOADER_DRIVER_OVERRIDE=${MESA_LOADER_DRIVER_OVERRIDE:-kgsl}"
    shell_guest_env="${shell_guest_env}"$'\n'"TU_DEBUG=${TU_DEBUG:-noconform}"
    shell_guest_env="${shell_guest_env}"$'\n'"SHADOW_LINUX_LD_PRELOAD=$(pixel_runtime_openlog_preload_dst)"
    shell_guest_env="${shell_guest_env}"$'\n'"SHADOW_OPENLOG_DENY_DRI=${SHADOW_OPENLOG_DENY_DRI:-1}"
  else
    shell_guest_env="${shell_guest_env}"$'\n'"WGPU_BACKEND=${WGPU_BACKEND:-gl}"
  fi
fi
if [[ -n "$extra_guest_env" ]]; then
  shell_guest_env="${shell_guest_env}"$'\n'"${extra_guest_env}"
fi
shell_session_env=$(
  cat <<EOF
SHADOW_GUEST_START_APP_ID=shell
$(pixel_runtime_shell_bundle_env_lines)
$(pixel_runtime_host_env_lines)
SHADOW_GUEST_COMPOSITOR_BOOT_SPLASH_DRM=1
EOF
)
if [[ -n "$shell_start_app_id" ]]; then
  shell_session_env="${shell_session_env}"$'\n'"SHADOW_GUEST_SHELL_START_APP_ID=$shell_start_app_id"
  extra_required_markers="${extra_required_markers}"$'\n''[shadow-guest-compositor] mapped-window'
  extra_required_markers="${extra_required_markers}"$'\n'"[shadow-guest-compositor] surface-app-tracked app=$shell_start_app_id"
fi
if [[ -n "$extra_session_env" ]]; then
  shell_session_env="${shell_session_env}"$'\n'"${extra_session_env}"
fi

required_markers='[shadow-guest-compositor] touch-ready'
if [[ -n "$extra_required_markers" ]]; then
  required_markers="${required_markers}"$'\n'"${extra_required_markers}"
fi

if (( shell_stage_only == 1 )); then
  PIXEL_GUEST_CLIENT_ARTIFACT="$guest_client_artifact" \
  PIXEL_GUEST_CLIENT_DST="$guest_client_dst" \
  PIXEL_RUNTIME_HOST_BUNDLE_ARTIFACT_DIR="$(pixel_shell_runtime_host_bundle_artifact_dir)" \
    "$SCRIPT_DIR/pixel/pixel_push.sh"
  exit 0
fi

exec env \
  PIXEL_GUEST_CLIENT_ARTIFACT="$guest_client_artifact" \
  PIXEL_GUEST_CLIENT_DST="$guest_client_dst" \
  PIXEL_RUNTIME_HOST_BUNDLE_ARTIFACT_DIR="$(pixel_shell_runtime_host_bundle_artifact_dir)" \
  PIXEL_COMPOSITOR_MARKER='[shadow-guest-compositor] presented-frame' \
  PIXEL_GUEST_REQUIRED_MARKERS="$required_markers" \
  PIXEL_GUEST_EXPECT_CLIENT_PROCESS="$expect_client_process" \
  PIXEL_GUEST_EXPECT_CLIENT_MARKER='' \
  PIXEL_VERIFY_REQUIRE_CLIENT_MARKER='' \
  PIXEL_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME='' \
  PIXEL_GUEST_CLIENT_EXIT_ON_CONFIGURE='' \
  PIXEL_GUEST_SESSION_TIMEOUT_SECS="$PIXEL_GUEST_SESSION_TIMEOUT_SECS" \
  PIXEL_GUEST_CLIENT_ENV="$shell_guest_env" \
  PIXEL_GUEST_SESSION_ENV="$shell_session_env" \
  PIXEL_GUEST_PRECREATE_DIRS="$(pixel_runtime_precreate_dirs_lines)" \
  PIXEL_GUEST_PRE_SESSION_DEVICE_SCRIPT="$camera_start_command" \
  PIXEL_GUEST_POST_SESSION_DEVICE_SCRIPT="$camera_cleanup_command" \
  PIXEL_TAKEOVER_STOP_ALLOCATOR="${PIXEL_TAKEOVER_STOP_ALLOCATOR:-0}" \
  PIXEL_GUEST_SKIP_PUSH="$([[ "$shell_run_only" == 1 ]] && printf 1 || true)" \
  "$SCRIPT_DIR/pixel/pixel_guest_ui_drm.sh"
