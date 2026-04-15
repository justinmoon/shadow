#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
runtime_flake_ref=""
runtime_host_package_attr="shadow-runtime-host"
enable_podcast_app="0"
bundle_rewrite_from=""
bundle_rewrite_to=""
audio_backend=""
state_dir_override=""
podcast_session_json=""
podcast_asset_dir=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --flake-ref)
        runtime_flake_ref="${2:-}"
        shift 2
        ;;
      --runtime-host-package)
        runtime_host_package_attr="${2:-}"
        shift 2
        ;;
      --include-podcast)
        enable_podcast_app="1"
        shift
        ;;
      --bundle-rewrite-from)
        bundle_rewrite_from="${2:-}"
        shift 2
        ;;
      --bundle-rewrite-to)
        bundle_rewrite_to="${2:-}"
        shift 2
        ;;
      --audio-backend)
        audio_backend="${2:-}"
        shift 2
        ;;
      --state-dir)
        state_dir_override="${2:-}"
        shift 2
        ;;
      *)
        echo "runtime_prepare_host_session_env.sh: unsupported argument $1" >&2
        exit 1
        ;;
    esac
  done
}

runtime_prepare_host_session_json() {
  local -a command=("$SCRIPT_DIR/runtime_prepare_host_session.sh")

  if [[ -n "$runtime_flake_ref" ]]; then
    command+=(--flake-ref "$runtime_flake_ref")
  fi
  command+=(--runtime-host-package "$runtime_host_package_attr")
  "${command[@]}"
}

parse_args "$@"

cd "$REPO_ROOT"
default_session_json="$(runtime_prepare_host_session_json)"
counter_session_json="$(
  SHADOW_RUNTIME_APP_INPUT_PATH="runtime/app-counter/app.tsx" \
  SHADOW_RUNTIME_APP_CACHE_DIR="build/runtime/app-counter-host" \
    runtime_prepare_host_session_json
)"
camera_session_json="$(
  SHADOW_RUNTIME_APP_INPUT_PATH="runtime/app-camera/app.tsx" \
  SHADOW_RUNTIME_APP_CACHE_DIR="build/runtime/app-camera-host" \
    runtime_prepare_host_session_json
)"
timeline_session_json="$(
  SHADOW_RUNTIME_APP_CONFIG_JSON='{"limit":12,"syncOnStart":true}' \
  SHADOW_RUNTIME_APP_INPUT_PATH="runtime/app-nostr-timeline/app.tsx" \
  SHADOW_RUNTIME_APP_CACHE_DIR="build/runtime/app-nostr-timeline-host" \
    runtime_prepare_host_session_json
)"
cashu_session_json="$(
  SHADOW_RUNTIME_APP_INPUT_PATH="runtime/app-cashu-wallet/app.tsx" \
  SHADOW_RUNTIME_APP_CACHE_DIR="build/runtime/app-cashu-wallet-host" \
    runtime_prepare_host_session_json
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
      runtime_prepare_host_session_json
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

RUNTIME_PREP_BUNDLE_REWRITE_FROM="$bundle_rewrite_from" \
RUNTIME_PREP_BUNDLE_REWRITE_TO="$bundle_rewrite_to" \
RUNTIME_PREP_AUDIO_BACKEND="$audio_backend" \
RUNTIME_PREP_STATE_DIR="$state_dir_override" \
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
rewrite_from = os.environ.get("RUNTIME_PREP_BUNDLE_REWRITE_FROM", "")
rewrite_to = os.environ.get("RUNTIME_PREP_BUNDLE_REWRITE_TO", "")
audio_backend = os.environ.get("RUNTIME_PREP_AUDIO_BACKEND", "").strip()


def rewrite(path: str) -> str:
    if rewrite_from and rewrite_to and path.startswith(rewrite_from):
        return rewrite_to + path[len(rewrite_from):]
    return path

state_dir_override = os.environ.get("RUNTIME_PREP_STATE_DIR", "")
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
