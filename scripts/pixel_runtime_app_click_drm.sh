#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

: "${PIXEL_BLITZ_RUNTIME_AUTO_CLICK_TARGET:=counter}"

PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS='[shadow-runtime-demo] runtime-event-dispatched source=auto type=click target='"$PIXEL_BLITZ_RUNTIME_AUTO_CLICK_TARGET" \
PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV=$(
  cat <<EOF
SHADOW_BLITZ_RUNTIME_AUTO_CLICK_TARGET=$PIXEL_BLITZ_RUNTIME_AUTO_CLICK_TARGET
EOF
) \
  "$SCRIPT_DIR/pixel_runtime_app_drm.sh"
