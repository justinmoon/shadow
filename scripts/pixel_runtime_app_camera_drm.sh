#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
# shellcheck source=./pixel_camera_runtime_common.sh
source "$SCRIPT_DIR/pixel_camera_runtime_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
camera_endpoint="$(pixel_camera_runtime_endpoint)"

cleanup() {
  pixel_camera_runtime_cleanup_broker "$serial"
}

trap cleanup EXIT

pixel_camera_runtime_prepare_broker "$serial" "$camera_endpoint"

panel_size="$(pixel_display_size "$serial")"
panel_width="${panel_size%x*}"
panel_height="${panel_size#*x}"

camera_guest_env=$(
  cat <<EOF
SHADOW_BLITZ_SURFACE_WIDTH=$panel_width
SHADOW_BLITZ_SURFACE_HEIGHT=$panel_height
SHADOW_BLITZ_TOUCH_ANYWHERE_TARGET=capture
SHADOW_BLITZ_RUNTIME_DEBUG_DUMP=1
SHADOW_BLITZ_RUNTIME_POLL_INTERVAL_MS=100
SHADOW_RUNTIME_CAMERA_ENDPOINT=$camera_endpoint
EOF
)

if [[ -n "${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}" ]]; then
  camera_guest_env="${camera_guest_env}"$'\n'"${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV}"
fi
camera_guest_env="$(printf '%s\n' "$camera_guest_env" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"

PIXEL_TAKEOVER_STOP_ALLOCATOR=0 \
PIXEL_RUNTIME_APP_INPUT_PATH="runtime/app-camera/app.tsx" \
PIXEL_RUNTIME_APP_CACHE_DIR="build/runtime/pixel-app-camera" \
PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV="$camera_guest_env" \
PIXEL_GUEST_COMPOSITOR_MARKER_TIMEOUT_SECS="${PIXEL_GUEST_COMPOSITOR_MARKER_TIMEOUT_SECS:-45}" \
PIXEL_GUEST_FRAME_CHECKPOINT_TIMEOUT_SECS="${PIXEL_GUEST_FRAME_CHECKPOINT_TIMEOUT_SECS:-45}" \
PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-120}" \
  "$SCRIPT_DIR/pixel_runtime_app_drm.sh"
