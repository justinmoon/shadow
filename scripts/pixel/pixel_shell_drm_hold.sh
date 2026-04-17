#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

exec env \
  PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS="${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS-}" \
  PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS-}" \
  PIXEL_GUEST_SESSION_EXIT_TIMEOUT_SECS= \
  PIXEL_TAKEOVER_RESTORE_ANDROID= \
  "$SCRIPT_DIR/pixel/pixel_shell_drm.sh" "$@"
