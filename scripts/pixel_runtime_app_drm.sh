#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

"$SCRIPT_DIR/pixel_build.sh"

: "${PIXEL_RUNTIME_APP_RENDERER:=gpu_softbuffer}"

guest_client_artifact="$(pixel_blitz_demo_artifact)"
guest_client_dst="$(pixel_blitz_demo_dst)"
runtime_prepare_extra_env=()

case "$PIXEL_RUNTIME_APP_RENDERER" in
  cpu)
    "$SCRIPT_DIR/pixel_build_blitz_demo.sh"
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
    echo "pixel_runtime_app_drm: unsupported PIXEL_RUNTIME_APP_RENDERER: $PIXEL_RUNTIME_APP_RENDERER" >&2
    exit 1
    ;;
esac

env "${runtime_prepare_extra_env[@]}" "$SCRIPT_DIR/pixel_prepare_runtime_app_artifacts.sh"

: "${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS:=12000}"
: "${PIXEL_GUEST_SESSION_TIMEOUT_SECS:=20}"
extra_guest_env="${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}"
extra_session_env="${PIXEL_RUNTIME_APP_EXTRA_SESSION_ENV-}"
extra_required_markers="${PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS-}"
touch_signal_path="$(pixel_runtime_dir)/touch-signal"
runtime_home_dir="$(pixel_runtime_linux_dir)/home"
runtime_cache_dir="$runtime_home_dir/.cache"
runtime_config_dir="$runtime_home_dir/.config"

runtime_guest_env=$(
  cat <<EOF
SHADOW_BLITZ_RUNTIME_EXIT_DELAY_MS=$PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS
SHADOW_BLITZ_RAW_POINTER_FALLBACK=1
SHADOW_BLITZ_TOUCH_ANYWHERE_TARGET=counter
SHADOW_BLITZ_TOUCH_ACTIVATE_ON_DOWN=1
SHADOW_BLITZ_TOUCH_SIGNAL_PATH=$touch_signal_path
SHADOW_BLITZ_DEBUG_OVERLAY=0
SHADOW_BLITZ_ANDROID_FONTS=curated
SHADOW_RUNTIME_APP_BUNDLE_PATH=$(pixel_runtime_app_bundle_dst)
SHADOW_RUNTIME_HOST_BINARY_PATH=$(pixel_runtime_host_launcher_dst)
HOME=$runtime_home_dir
XDG_CACHE_HOME=$runtime_cache_dir
XDG_CONFIG_HOME=$runtime_config_dir
EOF
)
if [[ "$PIXEL_RUNTIME_APP_RENDERER" == "gpu_softbuffer" ]]; then
  runtime_guest_env="${runtime_guest_env}"$'\n'"WGPU_BACKEND=${WGPU_BACKEND:-gl}"
  runtime_guest_env="${runtime_guest_env}"$'\n'"MESA_SHADER_CACHE_DIR=$runtime_cache_dir/mesa"
fi
if [[ -n "$extra_guest_env" ]]; then
  runtime_guest_env="${runtime_guest_env}"$'\n'"${extra_guest_env}"
fi
runtime_guest_env="$(printf '%s\n' "$runtime_guest_env" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"

runtime_session_env=$(
  cat <<EOF
SHADOW_GUEST_TOUCH_SIGNAL_PATH=$touch_signal_path
EOF
)
if [[ -n "$extra_session_env" ]]; then
  runtime_session_env="${runtime_session_env}"$'\n'"${extra_session_env}"
fi
runtime_session_env="$(printf '%s\n' "$runtime_session_env" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"

required_markers='runtime-session-ready'
if [[ -n "$extra_required_markers" ]]; then
  required_markers="${required_markers}"$'\n'"${extra_required_markers}"
fi

PIXEL_GUEST_CLIENT_ARTIFACT="$guest_client_artifact" \
PIXEL_GUEST_CLIENT_DST="$guest_client_dst" \
PIXEL_RUNTIME_HOST_BUNDLE_ARTIFACT_DIR="$(pixel_runtime_host_bundle_artifact_dir)" \
PIXEL_RUNTIME_APP_BUNDLE_ARTIFACT="$(pixel_runtime_app_bundle_artifact)" \
PIXEL_COMPOSITOR_MARKER='[shadow-guest-compositor] presented-frame' \
PIXEL_CLIENT_MARKER='runtime-document-ready' \
PIXEL_GUEST_REQUIRED_MARKERS="$required_markers" \
PIXEL_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME='' \
PIXEL_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT=1 \
PIXEL_GUEST_CLIENT_EXIT_ON_CONFIGURE='' \
PIXEL_GUEST_SESSION_TIMEOUT_SECS="$PIXEL_GUEST_SESSION_TIMEOUT_SECS" \
PIXEL_GUEST_CLIENT_ENV="$runtime_guest_env" \
PIXEL_GUEST_SESSION_ENV="$runtime_session_env" \
PIXEL_GUEST_PRECREATE_DIRS="$runtime_home_dir $runtime_cache_dir $runtime_cache_dir/mesa $runtime_config_dir" \
  "$SCRIPT_DIR/pixel_guest_ui_drm.sh"
