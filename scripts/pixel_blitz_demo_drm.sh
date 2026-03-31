#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

if [[ ! -f "$(pixel_blitz_demo_artifact)" ]]; then
  "$SCRIPT_DIR/pixel_build_blitz_demo.sh"
fi

: "${PIXEL_BLITZ_DYNAMIC_DELAY_MS:=900}"
: "${PIXEL_BLITZ_EXIT_DELAY_MS:=12000}"
: "${PIXEL_GUEST_SESSION_TIMEOUT_SECS:=20}"
: "${PIXEL_GUEST_CLIENT_ENV:=SHADOW_BLITZ_DYNAMIC_DELAY_MS=$PIXEL_BLITZ_DYNAMIC_DELAY_MS SHADOW_BLITZ_EXIT_DELAY_MS=$PIXEL_BLITZ_EXIT_DELAY_MS}"

PIXEL_GUEST_CLIENT_ARTIFACT="$(pixel_blitz_demo_artifact)" \
PIXEL_GUEST_CLIENT_DST="$(pixel_blitz_demo_dst)" \
PIXEL_COMPOSITOR_MARKER='[shadow-guest-compositor] presented-frame' \
PIXEL_CLIENT_MARKER='[shadow-blitz-demo] dynamic-document-ready' \
PIXEL_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME='' \
PIXEL_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT=1 \
PIXEL_GUEST_CLIENT_EXIT_ON_CONFIGURE='' \
PIXEL_GUEST_SESSION_TIMEOUT_SECS="$PIXEL_GUEST_SESSION_TIMEOUT_SECS" \
PIXEL_GUEST_CLIENT_ENV="$PIXEL_GUEST_CLIENT_ENV" \
  "$SCRIPT_DIR/pixel_guest_ui_drm.sh"
