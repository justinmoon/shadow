#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
  "$REPO_ROOT/runtime/apps.json" \
  '"configEnv": "SHADOW_RUNTIME_APP_TIMELINE_CONFIG_JSON"' \
  "manifest timeline startup sync override env"

expect_fixed \
  "$REPO_ROOT/runtime/apps.json" \
  '"limit": 12' \
  "manifest timeline startup sync limit"

expect_fixed \
  "$REPO_ROOT/runtime/apps.json" \
  '"syncOnStart": true' \
  "manifest timeline startup sync default"

expect_fixed \
  "$REPO_ROOT/scripts/runtime/runtime_prepare_host_session_env.sh" \
  "--profile vm-shell" \
  "host session env uses shared VM-shell artifact profile"

expect_fixed \
  "$REPO_ROOT/scripts/pixel/pixel_runtime_app_nostr_timeline_drm.sh" \
  "runtime_app_config_json='{\"limit\":12,\"relayUrls\":[\"wss://relay.primal.net/\",\"wss://relay.damus.io/\"],\"syncOnStart\":true}'" \
  "pixel direct timeline relay sync default"

expect_fixed \
  "$REPO_ROOT/scripts/lib/pixel_common.sh" \
  'SHADOW_RUNTIME_NOSTR_DB_PATH=$(pixel_runtime_nostr_db_path)' \
  "pixel runtime host env nostr sqlite path"

expect_fixed \
  "$REPO_ROOT/scripts/pixel/pixel_shell_drm.sh" \
  '$(pixel_system_env_lines)' \
  "pixel shell system env nostr sqlite path"

expect_fixed \
  "$REPO_ROOT/scripts/pixel/pixel_runtime_app_drm.sh" \
  '$(pixel_system_env_lines)' \
  "pixel runtime system env nostr sqlite path"

expect_fixed \
  "$REPO_ROOT/runtime/app-nostr-timeline/app.tsx" \
  "const DEFAULT_RELAY_URLS = [\"wss://relay.primal.net/\", \"wss://relay.damus.io/\"];" \
  "timeline app default relay list"

expect_fixed \
  "$REPO_ROOT/runtime/app-nostr-timeline/app.tsx" \
  "const syncOnStart = value?.syncOnStart !== false;" \
  "timeline app startup sync fallback"

printf 'timeline_sync_defaults_smoke: ok\n'
