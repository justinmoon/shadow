#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS="${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS:-300000}" \
PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-360}" \
PIXEL_TAKEOVER_RESTORE_ANDROID= \
PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS='[shadow-guest-compositor] touch-ready' \
  "$SCRIPT_DIR/pixel_runtime_app_nostr_timeline_drm.sh"
