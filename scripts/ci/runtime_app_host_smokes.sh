#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

SHADOW_RUNTIME_APP_INPUT_PATH=runtime/app-keyboard-smoke/app.tsx \
SHADOW_RUNTIME_APP_CACHE_DIR=build/runtime/app-keyboard-smoke \
  "$SCRIPT_DIR/ci/runtime_app_keyboard_smoke.sh"

nix develop .#runtime -c "$SCRIPT_DIR/ci/runtime_app_camera_smoke.sh"

SHADOW_RUNTIME_APP_INPUT_PATH=runtime/app-nostr-gm/app.tsx \
SHADOW_RUNTIME_APP_CACHE_DIR=build/runtime/app-nostr-gm \
  "$SCRIPT_DIR/ci/runtime_app_nostr_gm_smoke.sh"

"$SCRIPT_DIR/ci/runtime_app_nostr_timeline_smoke.sh"
"$SCRIPT_DIR/ci/runtime_app_sound_smoke.sh"
"$SCRIPT_DIR/ci/runtime_app_podcast_player_smoke.sh"
"$SCRIPT_DIR/ci/runtime_app_cashu_wallet_smoke.sh"
