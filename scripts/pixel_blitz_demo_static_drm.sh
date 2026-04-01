#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

"$SCRIPT_DIR/pixel_build_blitz_demo.sh"

blitz_exit_delay_ms="${PIXEL_BLITZ_EXIT_DELAY_MS-2500}"
session_timeout_secs="${PIXEL_GUEST_SESSION_TIMEOUT_SECS-20}"
guest_client_env="SHADOW_BLITZ_STATIC_ONLY=1"

if [[ -n "$blitz_exit_delay_ms" ]]; then
  guest_client_env="$guest_client_env SHADOW_BLITZ_EXIT_DELAY_MS=$blitz_exit_delay_ms"
fi

if [[ -n "${PIXEL_GUEST_CLIENT_ENV-}" ]]; then
  guest_client_env="$guest_client_env ${PIXEL_GUEST_CLIENT_ENV}"
fi

PIXEL_GUEST_CLIENT_ARTIFACT="$(pixel_blitz_demo_artifact)" \
PIXEL_GUEST_CLIENT_DST="$(pixel_blitz_demo_dst)" \
PIXEL_COMPOSITOR_MARKER='[shadow-guest-compositor] presented-frame' \
PIXEL_CLIENT_MARKER='[shadow-blitz-demo] static-document-ready' \
PIXEL_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME='' \
PIXEL_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT=1 \
PIXEL_GUEST_CLIENT_EXIT_ON_CONFIGURE='' \
PIXEL_GUEST_SESSION_TIMEOUT_SECS="$session_timeout_secs" \
PIXEL_GUEST_CLIENT_ENV="$guest_client_env" \
  "$SCRIPT_DIR/pixel_guest_ui_drm.sh"
