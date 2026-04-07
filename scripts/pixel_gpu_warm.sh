#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PIXEL_RUNTIME_APP_PREPARE_ONLY=1 \
  "$SCRIPT_DIR/pixel_runtime_app_nostr_timeline_drm.sh"
