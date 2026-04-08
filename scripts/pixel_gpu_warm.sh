#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

: "${PIXEL_RUNTIME_APP_RENDERER:=gpu_softbuffer}"

PIXEL_RUNTIME_APP_PREP_ONLY=1 \
PIXEL_RUNTIME_APP_RENDERER="$PIXEL_RUNTIME_APP_RENDERER" \
  "$SCRIPT_DIR/pixel_runtime_app_nostr_timeline_drm.sh"
