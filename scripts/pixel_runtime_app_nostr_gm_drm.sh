#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
panel_size="$(pixel_display_size "$serial")"
panel_width="${panel_size%x*}"
panel_height="${panel_size#*x}"

gm_guest_env=$(
  cat <<EOF
SHADOW_RUNTIME_NOSTR_RELAY_URLS=wss://relay.primal.net/,wss://relay.damus.io/
SHADOW_RUNTIME_NOSTR_PUBLISH_TIMEOUT_MS=20000
SHADOW_BLITZ_SURFACE_WIDTH=$panel_width
SHADOW_BLITZ_SURFACE_HEIGHT=$panel_height
EOF
)

if [[ -n "${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}" ]]; then
  gm_guest_env="${gm_guest_env}"$'\n'"${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV}"
fi
gm_guest_env="$(printf '%s\n' "$gm_guest_env" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"

PIXEL_RUNTIME_APP_INPUT_PATH="runtime/app-nostr-gm/app.tsx" \
PIXEL_RUNTIME_APP_CACHE_DIR="build/runtime/pixel-app-nostr-gm" \
PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV="$gm_guest_env" \
PIXEL_GUEST_COMPOSITOR_MARKER_TIMEOUT_SECS="${PIXEL_GUEST_COMPOSITOR_MARKER_TIMEOUT_SECS:-45}" \
PIXEL_GUEST_FRAME_CHECKPOINT_TIMEOUT_SECS="${PIXEL_GUEST_FRAME_CHECKPOINT_TIMEOUT_SECS:-45}" \
PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-90}" \
  "$SCRIPT_DIR/pixel_runtime_app_drm.sh"
