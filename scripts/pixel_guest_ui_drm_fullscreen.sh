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
client_env="SHADOW_GUEST_COUNTER_WIDTH=$panel_width SHADOW_GUEST_COUNTER_HEIGHT=$panel_height SHADOW_GUEST_COUNTER_FULLSCREEN=1 SHADOW_GUEST_COUNTER_PATTERN=quadrants"
if [[ -n "${PIXEL_GUEST_CLIENT_ENV:-}" ]]; then
  client_env="$client_env ${PIXEL_GUEST_CLIENT_ENV}"
fi

PIXEL_GUEST_CLIENT_ENV="$client_env" \
PIXEL_GUEST_COUNTER_LINGER_MS="${PIXEL_GUEST_COUNTER_LINGER_MS:-2000}" \
PIXEL_COMPOSITOR_MARKER='[shadow-guest-compositor] presented-frame' \
PIXEL_CLIENT_MARKER='[shadow-guest-counter] frame-committed' \
  "$SCRIPT_DIR/pixel_guest_ui_drm.sh"
