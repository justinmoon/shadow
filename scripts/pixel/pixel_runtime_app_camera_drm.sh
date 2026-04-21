#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./pixel_camera_runtime_common.sh
source "$SCRIPT_DIR/lib/pixel_camera_runtime_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
camera_endpoint="$(pixel_camera_runtime_endpoint)"
camera_allow_mock="${SHADOW_RUNTIME_CAMERA_ALLOW_MOCK-}"
camera_timeout_ms="${SHADOW_RUNTIME_CAMERA_TIMEOUT_MS-}"
camera_mock_requested=0
if pixel_camera_runtime_mock_requested "$camera_allow_mock"; then
  camera_mock_requested=1
fi
camera_service_json="$(
  pixel_camera_runtime_service_json \
    "$camera_endpoint" \
    "$camera_allow_mock" \
    "$camera_timeout_ms"
)"

cleanup() {
  pixel_camera_runtime_cleanup_broker "$serial"
}

trap cleanup EXIT

if (( camera_mock_requested == 0 )); then
  pixel_camera_runtime_prepare_broker "$serial" "$camera_endpoint"
fi

panel_size="$(pixel_display_size "$serial")"
panel_width="${panel_size%x*}"
panel_height="${panel_size#*x}"

camera_guest_env=$(
  cat <<EOF
SHADOW_BLITZ_SURFACE_WIDTH=$panel_width
SHADOW_BLITZ_SURFACE_HEIGHT=$panel_height
SHADOW_BLITZ_TOUCH_ANYWHERE_TARGET=capture
SHADOW_BLITZ_RUNTIME_DEBUG_DUMP=1
SHADOW_BLITZ_RUNTIME_POLL_INTERVAL_MS=${SHADOW_BLITZ_RUNTIME_POLL_INTERVAL_MS:-16}
EOF
)

if [[ -n "${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}" ]]; then
  camera_guest_env="${camera_guest_env}"$'\n'"${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV}"
fi

PIXEL_TAKEOVER_STOP_ALLOCATOR=0 \
PIXEL_RUNTIME_APP_INPUT_PATH="runtime/app-camera/app.tsx" \
PIXEL_RUNTIME_APP_CACHE_DIR="build/runtime/pixel-app-camera" \
PIXEL_RUNTIME_APP_SERVICES_JSON="$camera_service_json" \
PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV="$camera_guest_env" \
PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-120}" \
  "$SCRIPT_DIR/pixel/pixel_runtime_app_drm.sh"
