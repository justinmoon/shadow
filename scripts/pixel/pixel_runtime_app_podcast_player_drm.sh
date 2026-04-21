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
podcast_episode_ids="${SHADOW_PODCAST_PLAYER_EPISODE_IDS:-00}"
asset_json="$(
  SHADOW_PODCAST_PLAYER_EPISODE_IDS="$podcast_episode_ids" \
    "$SCRIPT_DIR/runtime/prepare_podcast_player_demo_assets.sh"
)"
asset_dir="$(
  ASSET_JSON="$asset_json" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["ASSET_JSON"])["assetDir"])
PY
)"
runtime_app_config_json="$(
  ASSET_JSON="$asset_json" python3 - <<'PY'
import json
import os

asset = json.loads(os.environ["ASSET_JSON"])
asset.pop("assetDir", None)
print(json.dumps(asset))
PY
)"
primary_episode_path="$(
  ASSET_JSON="$asset_json" python3 - <<'PY'
import json
import os

asset = json.loads(os.environ["ASSET_JSON"])
episodes = asset.get("episodes") or []
if not episodes:
    raise SystemExit("pixel_runtime_app_podcast_player_drm: missing podcast episodes")
print(episodes[0]["path"])
PY
)"

podcast_guest_env=''
if (( stage_only == 0 )); then
  serial="$(pixel_resolve_serial)"
  panel_size="$(pixel_display_size "$serial")"
  panel_width="${panel_size%x*}"
  panel_height="${panel_size#*x}"
  podcast_guest_env=$(
    cat <<EOF
SHADOW_BLITZ_SURFACE_WIDTH=$panel_width
SHADOW_BLITZ_SURFACE_HEIGHT=$panel_height
SHADOW_BLITZ_RUNTIME_AUTO_CLICK_TARGET=play-00
SHADOW_RUNTIME_AUDIO_BACKEND=${PIXEL_RUNTIME_AUDIO_LEGACY_CONFLICT_BACKEND:-memory}
SHADOW_RUNTIME_AUDIO_SPIKE_GAIN=${PIXEL_RUNTIME_AUDIO_SPIKE_GAIN:-0.03}
EOF
  )
fi

if [[ -n "${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}" ]]; then
  podcast_guest_env="${podcast_guest_env}"$'\n'"${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV}"
fi

required_markers=$(
  cat <<EOF
runtime-event-dispatched source=auto type=click target=play-00
[shadow-runtime-podcast-player] command=play episode=00 state=playing backend=linux_spike source=$primary_episode_path
EOF
)
if [[ -n "${PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS-}" ]]; then
  required_markers="${required_markers}"$'\n'"${PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS}"
fi

forbidden_markers=$(
  cat <<'EOF'
[shadow-runtime-podcast-player] command=play error=
[shadow-runtime-podcast-player] command=play episode=00 state=playing backend=memory
EOF
)
if [[ -n "${PIXEL_RUNTIME_APP_EXTRA_FORBIDDEN_MARKERS-}" ]]; then
  forbidden_markers="${forbidden_markers}"$'\n'"${PIXEL_RUNTIME_APP_EXTRA_FORBIDDEN_MARKERS}"
fi

PIXEL_TAKEOVER_STOP_ALLOCATOR="${PIXEL_TAKEOVER_STOP_ALLOCATOR:-0}" \
PIXEL_RUNTIME_ENABLE_LINUX_AUDIO=1 \
PIXEL_RUNTIME_APP_INPUT_PATH="runtime/app-podcast-player/app.tsx" \
PIXEL_RUNTIME_APP_CACHE_DIR="build/runtime/pixel-app-podcast-player" \
PIXEL_RUNTIME_APP_EXTRA_ASSET_DIR="$asset_dir/assets" \
PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV="$podcast_guest_env" \
PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS="$required_markers" \
PIXEL_RUNTIME_APP_EXTRA_FORBIDDEN_MARKERS="$forbidden_markers" \
SHADOW_RUNTIME_APP_CONFIG_JSON="$runtime_app_config_json" \
PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS="${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS:-30000}" \
PIXEL_GUEST_REQUIRED_MARKER_TIMEOUT_SECS="${PIXEL_GUEST_REQUIRED_MARKER_TIMEOUT_SECS:-45}" \
PIXEL_GUEST_SESSION_EXIT_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_EXIT_TIMEOUT_SECS:-0}" \
PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-120}" \
  "$SCRIPT_DIR/pixel/pixel_runtime_app_drm.sh"
