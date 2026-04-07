#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

: "${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS:=12000}"
: "${PIXEL_GUEST_SESSION_TIMEOUT_SECS:=20}"

extra_guest_env="${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}"
if [[ -n "$extra_guest_env" ]]; then
  extra_guest_env="SHADOW_BLITZ_RUNTIME_AUTO_CLICK_TARGET=quick-gm ${extra_guest_env}"
else
  extra_guest_env="SHADOW_BLITZ_RUNTIME_AUTO_CLICK_TARGET=quick-gm"
fi

extra_required_markers="${PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS-}"
required_marker='runtime-event-dispatched source=auto type=click target=quick-gm'
if [[ -n "$extra_required_markers" ]]; then
  extra_required_markers="${extra_required_markers}"$'\n'"${required_marker}"
else
  extra_required_markers="$required_marker"
fi

runtime_app_config_json="${SHADOW_RUNTIME_APP_CONFIG_JSON:-}"
if [[ -z "$runtime_app_config_json" ]]; then
  runtime_app_config_json='{"limit":12,"relayUrls":["wss://relay.primal.net/","wss://relay.damus.io/"],"syncOnStart":false}'
fi

SHADOW_RUNTIME_APP_CONFIG_JSON="$runtime_app_config_json" \
PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS="$PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS" \
PIXEL_GUEST_SESSION_TIMEOUT_SECS="$PIXEL_GUEST_SESSION_TIMEOUT_SECS" \
PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV="$extra_guest_env" \
PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS="$extra_required_markers" \
  "$SCRIPT_DIR/pixel_runtime_app_nostr_timeline_drm.sh"
