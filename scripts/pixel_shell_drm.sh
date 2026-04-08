#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

default_turnip_tarball="$(pixel_dir)/vendor/turnip_26.1.0-devel-20260404_debian_trixie_arm64.tar.gz"
default_mesa_tarball="$(pixel_dir)/vendor/mesa-for-android-container_26.1.0-devel-20260404_debian_trixie_arm64.tar.gz"
if [[ -z "${PIXEL_VENDOR_MESA_TARBALL-}" && -f "$default_mesa_tarball" ]]; then
  PIXEL_VENDOR_MESA_TARBALL="$default_mesa_tarball"
  export PIXEL_VENDOR_MESA_TARBALL
fi
if [[ -z "${PIXEL_VENDOR_TURNIP_TARBALL-}" && -f "$default_turnip_tarball" ]]; then
  PIXEL_VENDOR_TURNIP_TARBALL="$default_turnip_tarball"
  export PIXEL_VENDOR_TURNIP_TARBALL
fi

if [[ -z "${PIXEL_SHELL_RENDERER-}" ]]; then
  if [[ -n "${PIXEL_VENDOR_TURNIP_TARBALL-}" ]]; then
    PIXEL_SHELL_RENDERER="gpu_softbuffer"
  else
    PIXEL_SHELL_RENDERER="cpu"
  fi
fi

build_include_guest_client=1
if [[ "$PIXEL_SHELL_RENDERER" == "gpu_softbuffer" ]]; then
  build_include_guest_client=0
fi

PIXEL_BUILD_INCLUDE_GUEST_CLIENT="$build_include_guest_client" \
  "$SCRIPT_DIR/pixel_build.sh"

guest_client_artifact="$(pixel_guest_client_artifact)"
guest_client_dst="$(pixel_guest_client_dst)"
runtime_prepare_extra_env=()

case "$PIXEL_SHELL_RENDERER" in
  cpu)
    PIXEL_BLITZ_RENDERER=cpu "$SCRIPT_DIR/pixel_build_guest_client.sh"
    ;;
  gpu_softbuffer)
    "$SCRIPT_DIR/pixel_prepare_blitz_demo_gpu_softbuffer_bundle.sh"
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

env "${runtime_prepare_extra_env[@]}" "$SCRIPT_DIR/pixel_prepare_shell_runtime_artifacts.sh"

PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS="${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS-}"
PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS-}"
extra_guest_env="${PIXEL_SHELL_EXTRA_GUEST_CLIENT_ENV-}"
extra_session_env="${PIXEL_SHELL_EXTRA_SESSION_ENV-}"
extra_required_markers="${PIXEL_SHELL_EXTRA_REQUIRED_MARKERS-}"
shell_start_app_id="${PIXEL_SHELL_START_APP_ID-}"
runtime_home_dir="$(pixel_runtime_linux_dir)/home"
runtime_cache_dir="$runtime_home_dir/.cache"
runtime_config_dir="$runtime_home_dir/.config"
expect_client_process=''
xkb_config_root="$(pixel_runtime_linux_dir)/share/X11/xkb"

shell_guest_env=$(
  cat <<EOF
SHADOW_BLITZ_DEMO_MODE=runtime
SHADOW_BLITZ_DEBUG_OVERLAY=0
SHADOW_BLITZ_ANDROID_FONTS=${SHADOW_BLITZ_ANDROID_FONTS:-curated}
HOME=$runtime_home_dir
XDG_CACHE_HOME=$runtime_cache_dir
XDG_CONFIG_HOME=$runtime_config_dir
XKB_CONFIG_ROOT=$xkb_config_root
EOF
)
if [[ -n "$PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS" ]]; then
  shell_guest_env="${shell_guest_env}"$'\n'"SHADOW_BLITZ_RUNTIME_EXIT_DELAY_MS=$PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS"
fi
if [[ "$PIXEL_SHELL_RENDERER" == "gpu_softbuffer" ]]; then
  shell_guest_env="${shell_guest_env}"$'\n'"MESA_SHADER_CACHE_DIR=$runtime_cache_dir/mesa"
  if [[ -n "${PIXEL_VENDOR_TURNIP_TARBALL-}" ]]; then
    shell_guest_env="${shell_guest_env}"$'\n'"WGPU_BACKEND=${WGPU_BACKEND:-vulkan}"
    shell_guest_env="${shell_guest_env}"$'\n'"MESA_LOADER_DRIVER_OVERRIDE=${MESA_LOADER_DRIVER_OVERRIDE:-kgsl}"
    shell_guest_env="${shell_guest_env}"$'\n'"TU_DEBUG=${TU_DEBUG:-noconform}"
    shell_guest_env="${shell_guest_env}"$'\n'"SHADOW_LINUX_LD_PRELOAD=$(pixel_runtime_linux_dir)/lib/shadow-openlog-preload.so"
    shell_guest_env="${shell_guest_env}"$'\n'"SHADOW_OPENLOG_DENY_DRI=${SHADOW_OPENLOG_DENY_DRI:-1}"
  else
    shell_guest_env="${shell_guest_env}"$'\n'"WGPU_BACKEND=${WGPU_BACKEND:-gl}"
  fi
fi
if [[ -n "$extra_guest_env" ]]; then
  shell_guest_env="${shell_guest_env}"$'\n'"${extra_guest_env}"
fi
shell_guest_env="$(printf '%s\n' "$shell_guest_env" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"

shell_session_env=$(
  cat <<EOF
SHADOW_GUEST_START_APP_ID=shell
SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH=$(pixel_runtime_counter_bundle_dst)
SHADOW_RUNTIME_APP_TIMELINE_BUNDLE_PATH=$(pixel_runtime_timeline_bundle_dst)
SHADOW_RUNTIME_APP_PODCAST_BUNDLE_PATH=$(pixel_runtime_podcast_bundle_dst)
SHADOW_RUNTIME_APP_CASHU_BUNDLE_PATH=$(pixel_runtime_cashu_bundle_dst)
SHADOW_RUNTIME_APP_PODCAST_BUNDLE_PATH=$(pixel_runtime_podcast_bundle_dst)
SHADOW_RUNTIME_HOST_BINARY_PATH=$(pixel_runtime_host_launcher_dst)
SHADOW_RUNTIME_CASHU_DATA_DIR=$(pixel_runtime_dir)/cashu
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
shell_session_env="$(printf '%s\n' "$shell_session_env" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"

required_markers='[shadow-guest-compositor] touch-ready'
if [[ -n "$extra_required_markers" ]]; then
  required_markers="${required_markers}"$'\n'"${extra_required_markers}"
fi

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
PIXEL_GUEST_PRECREATE_DIRS="$runtime_home_dir $runtime_cache_dir $runtime_cache_dir/mesa $runtime_config_dir" \
  "$SCRIPT_DIR/pixel_guest_ui_drm.sh"
