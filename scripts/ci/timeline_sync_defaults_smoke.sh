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

if ! bash -lc 'cd "$0" && source scripts/lib/pixel_common.sh && pixel_runtime_app_services_json' "$REPO_ROOT" \
  | grep -Fq -- '"nostrDbPath":"/data/local/tmp/shadow-runtime/runtime-nostr.sqlite3"'; then
  fail "pixel runtime services nostr sqlite path missing from sourced pixel_runtime_app_services_json output"
fi
if ! bash -lc 'cd "$0" && source scripts/lib/pixel_common.sh && pixel_runtime_session_config_path' "$REPO_ROOT" \
  | grep -Fq -- '/data/local/tmp/shadow-runtime/session-config.json'; then
  fail "pixel runtime session config path missing from sourced pixel_runtime_session_config_path output"
fi
if ! bash -lc 'cd "$0" && source scripts/lib/pixel_common.sh && pixel_system_env_lines' "$REPO_ROOT" \
  | grep -Fq -- 'SHADOW_SYSTEM_STAGE_LOADER_PATH=/data/local/tmp/shadow-runtime-gnu/lib/ld-linux-aarch64.so.1'; then
  fail "pixel system env lines missing stage loader path"
fi
if ! bash -lc 'cd "$0" && source scripts/lib/pixel_common.sh && pixel_system_env_lines' "$REPO_ROOT" \
  | grep -Fq -- 'SHADOW_SYSTEM_STAGE_LIBRARY_PATH=/data/local/tmp/shadow-runtime-gnu/lib'; then
  fail "pixel system env lines missing stage library path"
fi

expect_fixed \
  "$REPO_ROOT/scripts/pixel/pixel_shell_drm.sh" \
  '$(pixel_system_env_lines)' \
  "pixel shell system env projection call"

expect_fixed \
  "$REPO_ROOT/scripts/pixel/pixel_runtime_app_drm.sh" \
  '$(pixel_system_env_lines)' \
  "pixel runtime system env projection call"

expect_fixed \
  "$REPO_ROOT/scripts/pixel/pixel_guest_ui_drm.sh" \
  'SHADOW_RUNTIME_SESSION_CONFIG=$runtime_session_config_dst' \
  "pixel guest runtime session config export"

expect_fixed \
  "$REPO_ROOT/scripts/pixel/pixel_guest_ui_drm.sh" \
  "cp '\$runtime_session_config_staging_dst' '\$runtime_session_config_dst'" \
  "pixel guest runtime session config staging copy"

expect_fixed \
  "$REPO_ROOT/scripts/pixel/pixel_guest_ui_drm.sh" \
  "cp '\$runtime_session_config_staging_dst' '\$runtime_session_config_chroot_dst'" \
  "pixel guest runtime session config chroot staging copy"

expect_fixed \
  "$REPO_ROOT/runtime/app-nostr-timeline/app.tsx" \
  "const DEFAULT_RELAY_URLS = [\"wss://relay.primal.net/\", \"wss://relay.damus.io/\"];" \
  "timeline app default relay list"

expect_fixed \
  "$REPO_ROOT/runtime/app-nostr-timeline/app.tsx" \
  "const syncOnStart = value?.syncOnStart !== false;" \
  "timeline app startup sync fallback"

printf 'timeline_sync_defaults_smoke: ok\n'
