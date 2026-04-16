#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "timeline_sync_defaults_smoke: $*" >&2
  exit 1
}

expect_fixed() {
  local path="$1"
  local needle="$2"
  local description="$3"

  if ! grep -Fq -- "$needle" "$path"; then
    fail "$description missing in $path"
  fi
}

expect_fixed \
  "$REPO_ROOT/scripts/pixel_prepare_shell_runtime_artifacts.sh" \
  "timeline_config_json='{\"limit\":12,\"syncOnStart\":true}'" \
  "pixel shell timeline startup sync default"

expect_fixed \
  "$REPO_ROOT/scripts/runtime_build_artifacts.ts" \
  "const DEFAULT_TIMELINE_CONFIG = { limit: 12, syncOnStart: true };" \
  "host session timeline startup sync default"

expect_fixed \
  "$REPO_ROOT/scripts/runtime_prepare_host_session_env.sh" \
  "--profile vm-shell" \
  "host session env uses shared VM-shell artifact profile"

expect_fixed \
  "$REPO_ROOT/scripts/pixel_runtime_app_nostr_timeline_drm.sh" \
  "runtime_app_config_json='{\"limit\":12,\"relayUrls\":[\"wss://relay.primal.net/\",\"wss://relay.damus.io/\"],\"syncOnStart\":true}'" \
  "pixel direct timeline relay sync default"

expect_fixed \
  "$REPO_ROOT/scripts/pixel_common.sh" \
  'SHADOW_RUNTIME_NOSTR_DB_PATH=$(pixel_runtime_nostr_db_path)' \
  "pixel runtime host env nostr sqlite path"

expect_fixed \
  "$REPO_ROOT/scripts/pixel_shell_drm.sh" \
  '$(pixel_runtime_host_env_lines)' \
  "pixel shell nostr sqlite path"

expect_fixed \
  "$REPO_ROOT/scripts/pixel_runtime_app_drm.sh" \
  '$(pixel_runtime_host_env_lines)' \
  "pixel runtime nostr sqlite path"

expect_fixed \
  "$REPO_ROOT/runtime/app-nostr-timeline/app.tsx" \
  "const DEFAULT_RELAY_URLS = [\"wss://relay.primal.net/\", \"wss://relay.damus.io/\"];" \
  "timeline app default relay list"

expect_fixed \
  "$REPO_ROOT/runtime/app-nostr-timeline/app.tsx" \
  "const syncOnStart = value?.syncOnStart !== false;" \
  "timeline app startup sync fallback"

printf 'timeline_sync_defaults_smoke: ok\n'
