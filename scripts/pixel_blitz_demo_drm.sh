#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

if [[ ! -f "$(pixel_blitz_demo_artifact)" ]]; then
  "$SCRIPT_DIR/pixel_build_blitz_demo.sh"
fi

PIXEL_GUEST_CLIENT_ARTIFACT="$(pixel_blitz_demo_artifact)" \
PIXEL_GUEST_CLIENT_DST="$(pixel_blitz_demo_dst)" \
PIXEL_COMPOSITOR_MARKER='[shadow-guest-compositor] presented-frame' \
PIXEL_CLIENT_MARKER='[shadow-blitz-demo] dynamic-document-ready' \
PIXEL_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME='' \
PIXEL_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT=1 \
PIXEL_GUEST_CLIENT_EXIT_ON_CONFIGURE='' \
  "$SCRIPT_DIR/pixel_guest_ui_drm.sh"
