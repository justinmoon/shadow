#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

gm_guest_env=$(
  cat <<EOF
SHADOW_BLITZ_TOUCH_ANYWHERE_TARGET=gm
EOF
)

if [[ -n "${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}" ]]; then
  gm_guest_env="${gm_guest_env}"$'\n'"${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV}"
fi
gm_guest_env="$(printf '%s\n' "$gm_guest_env" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"

PIXEL_RUNTIME_APP_INPUT_PATH="runtime/app-nostr-gm/app.tsx" \
PIXEL_RUNTIME_APP_CACHE_DIR="build/runtime/pixel-app-nostr-gm" \
PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV="$gm_guest_env" \
PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-90}" \
  "$SCRIPT_DIR/pixel_runtime_app_drm.sh"
