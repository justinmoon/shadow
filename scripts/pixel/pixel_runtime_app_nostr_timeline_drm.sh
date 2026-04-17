#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

timeline_guest_env=$(
  cat <<EOF
SHADOW_BLITZ_TOUCH_ANYWHERE_TARGET=refresh
EOF
)

if [[ -n "${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}" ]]; then
  timeline_guest_env="${timeline_guest_env}"$'\n'"${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV}"
fi
runtime_app_config_json="${SHADOW_RUNTIME_APP_CONFIG_JSON:-}"
if [[ -z "$runtime_app_config_json" ]]; then
  runtime_app_config_json='{"limit":12,"relayUrls":["wss://relay.primal.net/","wss://relay.damus.io/"],"syncOnStart":true}'
fi

SHADOW_RUNTIME_APP_CONFIG_JSON="$runtime_app_config_json" \
PIXEL_RUNTIME_APP_INPUT_PATH="runtime/app-nostr-timeline/app.tsx" \
PIXEL_RUNTIME_APP_CACHE_DIR="build/runtime/pixel-app-nostr-timeline" \
PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV="$timeline_guest_env" \
PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-120}" \
  "$SCRIPT_DIR/pixel/pixel_runtime_app_drm.sh"
