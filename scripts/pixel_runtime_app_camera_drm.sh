#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
camera_endpoint="${PIXEL_RUNTIME_CAMERA_ENDPOINT:-127.0.0.1:37656}"
device_binary="${PIXEL_CAMERA_RS_DEVICE_BINARY:-/data/local/tmp/shadow-camera-provider-host}"
daemon_pid_path="/data/local/tmp/shadow-camera-provider-host-serve.pid"
daemon_log_path="/data/local/tmp/shadow-camera-provider-host-serve.log"

cleanup() {
  pixel_root_shell "$serial" "
    if [ -f '$daemon_pid_path' ]; then
      kill \$(cat '$daemon_pid_path') >/dev/null 2>&1 || true
      rm -f '$daemon_pid_path'
    fi
  " >/dev/null 2>&1 || true
}

trap cleanup EXIT

"$SCRIPT_DIR/pixel_camera_rs_run.sh" ping >/dev/null

pixel_root_shell "$serial" "
  if [ -f '$daemon_pid_path' ]; then
    kill \$(cat '$daemon_pid_path') >/dev/null 2>&1 || true
  fi
  rm -f '$daemon_pid_path' '$daemon_log_path'
  chmod 0755 '$device_binary'
  nohup '$device_binary' serve '$camera_endpoint' >'$daemon_log_path' 2>&1 &
  echo \$! > '$daemon_pid_path'
  sleep 1
  kill -0 \$(cat '$daemon_pid_path')
" >/dev/null

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
