#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
enable_podcast_app="${SHADOW_RUNTIME_ENABLE_PODCAST_APP:-0}"
podcast_session_json=""
podcast_asset_dir=""

cd "$REPO_ROOT"
default_session_json="$("$SCRIPT_DIR/runtime_prepare_host_session.sh")"
counter_session_json="$(
  SHADOW_RUNTIME_APP_INPUT_PATH="runtime/app-counter/app.tsx" \
  SHADOW_RUNTIME_APP_CACHE_DIR="build/runtime/app-counter-host" \
    "$SCRIPT_DIR/runtime_prepare_host_session.sh"
)"
camera_session_json="$(
  SHADOW_RUNTIME_APP_INPUT_PATH="runtime/app-camera/app.tsx" \
  SHADOW_RUNTIME_APP_CACHE_DIR="build/runtime/app-camera-host" \
    "$SCRIPT_DIR/runtime_prepare_host_session.sh"
)"
timeline_session_json="$(
  SHADOW_RUNTIME_APP_CONFIG_JSON='{"limit":12,"syncOnStart":true}' \
  SHADOW_RUNTIME_APP_INPUT_PATH="runtime/app-nostr-timeline/app.tsx" \
  SHADOW_RUNTIME_APP_CACHE_DIR="build/runtime/app-nostr-timeline-host" \
    "$SCRIPT_DIR/runtime_prepare_host_session.sh"
)"
cashu_session_json="$(
  SHADOW_RUNTIME_APP_INPUT_PATH="runtime/app-cashu-wallet/app.tsx" \
  SHADOW_RUNTIME_APP_CACHE_DIR="build/runtime/app-cashu-wallet-host" \
    "$SCRIPT_DIR/runtime_prepare_host_session.sh"
)"

if [[ "$enable_podcast_app" == "1" ]]; then
  podcast_asset_json="$("$SCRIPT_DIR/prepare_podcast_player_demo_assets.sh")"
  podcast_asset_dir="$(
    ASSET_JSON="$podcast_asset_json" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["ASSET_JSON"])["assetDir"])
PY
  )"
  podcast_runtime_app_config_json="$(
    ASSET_JSON="$podcast_asset_json" python3 - <<'PY'
import json
import os

asset = json.loads(os.environ["ASSET_JSON"])
asset.pop("assetDir", None)
print(json.dumps(asset))
PY
  )"
  podcast_session_json="$(
    SHADOW_RUNTIME_APP_CONFIG_JSON="$podcast_runtime_app_config_json" \
    SHADOW_RUNTIME_APP_INPUT_PATH="runtime/app-podcast-player/app.tsx" \
    SHADOW_RUNTIME_APP_CACHE_DIR="build/runtime/app-podcast-player-host" \
      "$SCRIPT_DIR/runtime_prepare_host_session.sh"
  )"
  podcast_bundle_dir="$(
    PODCAST_SESSION_JSON="$podcast_session_json" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["PODCAST_SESSION_JSON"])["bundleDir"])
PY
  )"
  if [[ -n "$podcast_asset_dir" ]]; then
    rm -rf "$podcast_bundle_dir/assets"
    cp -R "$podcast_asset_dir"/. "$podcast_bundle_dir"/
  fi
fi

DEFAULT_SESSION_JSON="$default_session_json" \
COUNTER_SESSION_JSON="$counter_session_json" \
CAMERA_SESSION_JSON="$camera_session_json" \
TIMELINE_SESSION_JSON="$timeline_session_json" \
CASHU_SESSION_JSON="$cashu_session_json" \
PODCAST_SESSION_JSON="$podcast_session_json" \
python3 - <<'PY'
import json
import os
import shlex

default_session = json.loads(os.environ["DEFAULT_SESSION_JSON"])
counter_session = json.loads(os.environ["COUNTER_SESSION_JSON"])
camera_session = json.loads(os.environ["CAMERA_SESSION_JSON"])
timeline_session = json.loads(os.environ["TIMELINE_SESSION_JSON"])
cashu_session = json.loads(os.environ["CASHU_SESSION_JSON"])
podcast_session_json = os.environ.get("PODCAST_SESSION_JSON", "").strip()
rewrite_from = os.environ.get("SHADOW_RUNTIME_APP_BUNDLE_REWRITE_FROM")
rewrite_to = os.environ.get("SHADOW_RUNTIME_APP_BUNDLE_REWRITE_TO")
audio_backend = os.environ.get("SHADOW_RUNTIME_AUDIO_BACKEND", "").strip()


def rewrite(path: str) -> str:
    if rewrite_from and rewrite_to and path.startswith(rewrite_from):
        return rewrite_to + path[len(rewrite_from):]
    return path

state_dir_override = os.environ.get("SHADOW_STATE_DIR")
if state_dir_override:
    state_dir = state_dir_override
else:
    state_dir = "/var/lib/shadow-ui"
    if not os.path.isdir("/var/lib/shadow-ui"):
        xdg = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
        state_dir = os.path.join(xdg, "shadow-ui")

exports = {
    "SHADOW_RUNTIME_APP_BUNDLE_PATH": rewrite(default_session["bundlePath"]),
    "SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH": rewrite(counter_session["bundlePath"]),
    "SHADOW_RUNTIME_APP_CAMERA_BUNDLE_PATH": rewrite(camera_session["bundlePath"]),
    "SHADOW_RUNTIME_APP_TIMELINE_BUNDLE_PATH": rewrite(timeline_session["bundlePath"]),
    "SHADOW_RUNTIME_APP_CASHU_BUNDLE_PATH": rewrite(cashu_session["bundlePath"]),
    "SHADOW_RUNTIME_HOST_BINARY_PATH": default_session["runtimeHostBinaryPath"],
    "SHADOW_RUNTIME_CASHU_DATA_DIR": os.path.join(state_dir, "runtime-cashu"),
    "SHADOW_RUNTIME_NOSTR_DB_PATH": os.path.join(state_dir, "runtime-nostr.sqlite3"),
}

if podcast_session_json:
    podcast_session = json.loads(podcast_session_json)
    exports["SHADOW_RUNTIME_APP_PODCAST_BUNDLE_PATH"] = rewrite(podcast_session["bundlePath"])

if audio_backend:
    exports["SHADOW_RUNTIME_AUDIO_BACKEND"] = audio_backend

for key, value in exports.items():
    print(f"export {key}={shlex.quote(str(value))}")
PY
