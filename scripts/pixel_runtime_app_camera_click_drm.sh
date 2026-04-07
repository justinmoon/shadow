#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

extra_guest_env="${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}"
if [[ -n "$extra_guest_env" ]]; then
  extra_guest_env="SHADOW_BLITZ_RUNTIME_AUTO_CLICK_TARGET=capture ${extra_guest_env}"
else
  extra_guest_env="SHADOW_BLITZ_RUNTIME_AUTO_CLICK_TARGET=capture"
fi

PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV="$extra_guest_env" \
  "$SCRIPT_DIR/pixel_runtime_app_camera_drm.sh"
