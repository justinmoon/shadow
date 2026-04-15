#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

blitz_exit_delay_ms="${PIXEL_BLITZ_EXIT_DELAY_MS-2500}"
session_timeout_secs="${PIXEL_GUEST_SESSION_TIMEOUT_SECS-30}"
gpu_bundle_dir="$(pixel_artifact_path shadow-blitz-demo-gnu)"
gpu_launcher_artifact="$(pixel_artifact_path run-shadow-blitz-demo-gpu-softbuffer)"
gpu_launcher_dst="$(pixel_runtime_linux_dir)/run-shadow-blitz-demo"
compositor_marker="${PIXEL_COMPOSITOR_MARKER-[shadow-guest-compositor] presented-frame}"
runtime_shader_cache_dir="$(pixel_runtime_mesa_cache_dir)"
extra_precreate_dirs="${PIXEL_GUEST_PRECREATE_DIRS-}"

guest_client_env=$(
  cat <<EOF
SHADOW_BLITZ_STATIC_ONLY=1
WGPU_BACKEND=${WGPU_BACKEND:-gl}
$(pixel_runtime_linux_user_env_lines)
MESA_SHADER_CACHE_DIR=$runtime_shader_cache_dir
EOF
)

if [[ ! -d "$gpu_bundle_dir" || ! -x "$gpu_launcher_artifact" ]]; then
  bash "$SCRIPT_DIR/pixel_prepare_blitz_demo_gpu_softbuffer_bundle.sh"
fi

if [[ -n "$blitz_exit_delay_ms" ]]; then
  guest_client_env="${guest_client_env}"$'\n'"SHADOW_BLITZ_EXIT_DELAY_MS=$blitz_exit_delay_ms"
fi

if [[ -n "${PIXEL_GUEST_CLIENT_ENV-}" ]]; then
  guest_client_env="${guest_client_env}"$'\n'"${PIXEL_GUEST_CLIENT_ENV}"
fi

guest_precreate_dirs="$(pixel_runtime_precreate_dirs_lines)"
if [[ -n "$extra_precreate_dirs" ]]; then
  guest_precreate_dirs="${guest_precreate_dirs}"$'\n'"${extra_precreate_dirs}"
fi

PIXEL_GUEST_CLIENT_ARTIFACT="$gpu_launcher_artifact" \
PIXEL_GUEST_CLIENT_DST="$gpu_launcher_dst" \
PIXEL_RUNTIME_HOST_BUNDLE_ARTIFACT_DIR="$gpu_bundle_dir" \
PIXEL_CLIENT_MARKER='[shadow-blitz-demo] static-document-ready' \
PIXEL_COMPOSITOR_MARKER="$compositor_marker" \
PIXEL_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME='' \
PIXEL_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT=1 \
PIXEL_GUEST_CLIENT_EXIT_ON_CONFIGURE='' \
PIXEL_GUEST_SESSION_TIMEOUT_SECS="$session_timeout_secs" \
PIXEL_GUEST_CLIENT_ENV="$guest_client_env" \
PIXEL_GUEST_PRECREATE_DIRS="$guest_precreate_dirs" \
  "$SCRIPT_DIR/pixel_guest_ui_drm.sh"
