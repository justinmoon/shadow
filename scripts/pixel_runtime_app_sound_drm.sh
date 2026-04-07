#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
panel_size="$(pixel_display_size "$serial")"
panel_width="${panel_size%x*}"
panel_height="${panel_size#*x}"
asset_json="$("$SCRIPT_DIR/prepare_sound_demo_assets.sh")"
runtime_app_config_json="${SHADOW_RUNTIME_APP_CONFIG_JSON:-$(
  ASSET_JSON="$asset_json" python3 - <<'PY'
import json
import os

asset = json.loads(os.environ["ASSET_JSON"])
print(json.dumps({"source": asset["source"]}))
PY
)}"

sound_guest_env=$(
  cat <<EOF
SHADOW_BLITZ_SURFACE_WIDTH=$panel_width
SHADOW_BLITZ_SURFACE_HEIGHT=$panel_height
SHADOW_BLITZ_TOUCH_ANYWHERE_TARGET=play
EOF
)

if [[ -n "${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}" ]]; then
  sound_guest_env="${sound_guest_env}"$'\n'"${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV}"
fi
sound_guest_env="$(printf '%s\n' "$sound_guest_env" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"

PIXEL_RUNTIME_ENABLE_LINUX_AUDIO=1 \
PIXEL_RUNTIME_APP_INPUT_PATH="runtime/app-sound-smoke/app.tsx" \
PIXEL_RUNTIME_APP_CACHE_DIR="build/runtime/pixel-app-sound-smoke" \
PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV="$sound_guest_env" \
SHADOW_RUNTIME_APP_CONFIG_JSON="$runtime_app_config_json" \
PIXEL_GUEST_COMPOSITOR_MARKER_TIMEOUT_SECS="${PIXEL_GUEST_COMPOSITOR_MARKER_TIMEOUT_SECS:-45}" \
PIXEL_GUEST_FRAME_CHECKPOINT_TIMEOUT_SECS="${PIXEL_GUEST_FRAME_CHECKPOINT_TIMEOUT_SECS:-45}" \
PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-90}" \
  "$SCRIPT_DIR/pixel_runtime_app_drm.sh"
