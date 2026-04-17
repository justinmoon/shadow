#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

stage_only=0
if [[ -n "${PIXEL_RUNTIME_APP_PREP_ONLY-}" || -n "${PIXEL_RUNTIME_APP_PREPARE_ONLY-}" || -n "${PIXEL_RUNTIME_APP_STAGE_ONLY-}" ]]; then
  stage_only=1
fi
asset_json="$("$SCRIPT_DIR/runtime/prepare_sound_demo_assets.sh")"
runtime_app_config_json="${SHADOW_RUNTIME_APP_CONFIG_JSON:-$(
  ASSET_JSON="$asset_json" python3 - <<'PY'
import json
import os

asset = json.loads(os.environ["ASSET_JSON"])
print(json.dumps({"source": asset["source"]}))
PY
)}"
source_path_in_bundle="$(
  ASSET_JSON="$asset_json" python3 - <<'PY'
import json
import os

asset = json.loads(os.environ["ASSET_JSON"])
print(asset["source"]["path"])
PY
)"

sound_guest_env=''
if (( stage_only == 0 )); then
  serial="$(pixel_resolve_serial)"
  panel_size="$(pixel_display_size "$serial")"
  panel_width="${panel_size%x*}"
  panel_height="${panel_size#*x}"
  sound_guest_env=$(
    cat <<EOF
SHADOW_BLITZ_SURFACE_WIDTH=$panel_width
SHADOW_BLITZ_SURFACE_HEIGHT=$panel_height
SHADOW_BLITZ_RUNTIME_AUTO_CLICK_TARGET=play
SHADOW_RUNTIME_AUDIO_SPIKE_GAIN=${PIXEL_RUNTIME_AUDIO_SPIKE_GAIN:-0.03}
EOF
  )
fi

if [[ -n "${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}" ]]; then
  sound_guest_env="${sound_guest_env}"$'\n'"${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV}"
fi

required_markers=$(
  cat <<EOF
runtime-event-dispatched source=auto type=click target=play
[shadow-runtime-audio-smoke] command=play state=playing backend=linux_spike source_kind=file path=$source_path_in_bundle
EOF
)
if [[ -n "${PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS-}" ]]; then
  required_markers="${required_markers}"$'\n'"${PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS}"
fi

forbidden_markers='[shadow-runtime-audio-smoke] command=play error='
if [[ -n "${PIXEL_RUNTIME_APP_EXTRA_FORBIDDEN_MARKERS-}" ]]; then
  forbidden_markers="${forbidden_markers}"$'\n'"${PIXEL_RUNTIME_APP_EXTRA_FORBIDDEN_MARKERS}"
fi

PIXEL_TAKEOVER_STOP_ALLOCATOR="${PIXEL_TAKEOVER_STOP_ALLOCATOR:-0}" \
PIXEL_RUNTIME_ENABLE_LINUX_AUDIO=1 \
PIXEL_RUNTIME_APP_INPUT_PATH="runtime/app-sound-smoke/app.tsx" \
PIXEL_RUNTIME_APP_CACHE_DIR="build/runtime/pixel-app-sound-smoke" \
PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV="$sound_guest_env" \
PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS="$required_markers" \
PIXEL_RUNTIME_APP_EXTRA_FORBIDDEN_MARKERS="$forbidden_markers" \
SHADOW_RUNTIME_APP_CONFIG_JSON="$runtime_app_config_json" \
PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS="${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS:-30000}" \
PIXEL_GUEST_REQUIRED_MARKER_TIMEOUT_SECS="${PIXEL_GUEST_REQUIRED_MARKER_TIMEOUT_SECS:-45}" \
PIXEL_GUEST_SESSION_EXIT_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_EXIT_TIMEOUT_SECS:-0}" \
PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-90}" \
  "$SCRIPT_DIR/pixel/pixel_runtime_app_drm.sh"
