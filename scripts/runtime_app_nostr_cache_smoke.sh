#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./runtime_host_backend_common.sh
source "$SCRIPT_DIR/runtime_host_backend_common.sh"
INPUT_PATH="runtime/app-nostr-smoke/app.tsx"
CACHE_DIR="build/runtime/app-nostr-cache-smoke"
DB_PATH="$CACHE_DIR/nostr-cache.sqlite3"
AUTHOR_FILTER_EXPR='JSON.stringify(globalThis.Shadow.os.nostr.listKind1({authors:["npub-feed-a"],limit:2}))'
EXPECTED_INITIAL_HTML='<main class="nostr-feed"><header class="feed-header"><h1>Shadow Nostr</h1><button class="publish" data-shadow-id="publish">Post Kind 1</button></header><p class="feed-status">Loaded 3 notes</p><ol class="feed-list"><li class="feed-item"><article class="feed-note"><p class="feed-meta">shadow-note-3:npub-feed-b</p><p class="feed-content">local cache warmed from the system service</p></article></li><li class="feed-item"><article class="feed-note"><p class="feed-meta">shadow-note-2:npub-feed-a</p><p class="feed-content">relay subscriptions will live below app code</p></article></li><li class="feed-item"><article class="feed-note"><p class="feed-meta">shadow-note-1:npub-feed-a</p><p class="feed-content">shadow os owns nostr for tiny apps</p></article></li></ol></main>'
EXPECTED_PUBLISHED_HTML='<main class="nostr-feed"><header class="feed-header"><h1>Shadow Nostr</h1><button class="publish" data-shadow-id="publish">Post Kind 1</button></header><p class="feed-status">Posted shadow-note-4</p><ol class="feed-list"><li class="feed-item"><article class="feed-note"><p class="feed-meta">shadow-note-4:npub-shadow-os</p><p class="feed-content">shadow says hello from the os</p></article></li><li class="feed-item"><article class="feed-note"><p class="feed-meta">shadow-note-3:npub-feed-b</p><p class="feed-content">local cache warmed from the system service</p></article></li><li class="feed-item"><article class="feed-note"><p class="feed-meta">shadow-note-2:npub-feed-a</p><p class="feed-content">relay subscriptions will live below app code</p></article></li><li class="feed-item"><article class="feed-note"><p class="feed-meta">shadow-note-1:npub-feed-a</p><p class="feed-content">shadow os owns nostr for tiny apps</p></article></li></ol></main>'
EXPECTED_PERSISTED_HTML='<main class="nostr-feed"><header class="feed-header"><h1>Shadow Nostr</h1><button class="publish" data-shadow-id="publish">Post Kind 1</button></header><p class="feed-status">Loaded 3 notes</p><ol class="feed-list"><li class="feed-item"><article class="feed-note"><p class="feed-meta">shadow-note-4:npub-shadow-os</p><p class="feed-content">shadow says hello from the os</p></article></li><li class="feed-item"><article class="feed-note"><p class="feed-meta">shadow-note-3:npub-feed-b</p><p class="feed-content">local cache warmed from the system service</p></article></li><li class="feed-item"><article class="feed-note"><p class="feed-meta">shadow-note-2:npub-feed-a</p><p class="feed-content">relay subscriptions will live below app code</p></article></li></ol></main>'

extract_runtime_json() {
  local output="$1"
  python3 -c '
import re
import sys

payload = sys.stdin.read()
for line in reversed(payload.splitlines()):
    match = re.search(r"result=(.+)$", line)
    if match:
        print(match.group(1))
        break
else:
    raise SystemExit("could not find runtime result payload")
' <<<"$output"
}

assert_html_payload() {
  local output="$1"
  local expected_html="$2"
  python3 -c '
import json
import re
import sys

expected_html = sys.argv[1]
payload = sys.stdin.read()
for line in reversed(payload.splitlines()):
    match = re.search(r"result=(\{.*\})$", line)
    if not match:
        continue
    document = json.loads(match.group(1))
    if document.get("html") != expected_html:
        raise SystemExit("unexpected html payload: %r" % (document.get("html"),))
    if document.get("css", None) is not None:
        raise SystemExit("expected css to be null, got: %r" % (document.get("css"),))
    break
else:
    raise SystemExit("could not find runtime document payload")
' "$expected_html" <<<"$output"
}

cd "$REPO_ROOT"
runtime_host_backend_resolve
if [[ "$SHADOW_RUNTIME_HOST_BACKEND" != "deno-core" ]]; then
  echo "runtime app nostr cache smoke only supports deno-core today" >&2
  exit 1
fi

rm -f "$DB_PATH"
mkdir -p "$CACHE_DIR"
export SHADOW_RUNTIME_NOSTR_DB_PATH="$DB_PATH"

bundle_json="$(
  deno run --quiet --allow-env --allow-read --allow-write --allow-run \
    scripts/runtime_prepare_app_bundle.ts \
    --input "$INPUT_PATH" \
    --cache-dir "$CACHE_DIR"
)"
printf '%s\n' "$bundle_json"

bundle_path="$(
  printf '%s\n' "$bundle_json" | python3 -c 'import json, sys; print(json.load(sys.stdin)["bundlePath"])'
)"

initial_output="$(
  nix run --accept-flake-config ".#${SHADOW_RUNTIME_HOST_PACKAGE_ATTR}" -- "$bundle_path"
)"
printf '%s\n' "$initial_output"
assert_html_payload "$initial_output" "$EXPECTED_INITIAL_HTML"

publish_output="$(
  nix run --accept-flake-config ".#${SHADOW_RUNTIME_HOST_PACKAGE_ATTR}" -- \
    "$bundle_path" \
    --result-expr 'JSON.stringify(globalThis.SHADOW_RUNTIME_APP.dispatch({type:"click",targetId:"publish"}))'
)"
printf '%s\n' "$publish_output"
assert_html_payload "$publish_output" "$EXPECTED_PUBLISHED_HTML"

persisted_output="$(
  nix run --accept-flake-config ".#${SHADOW_RUNTIME_HOST_PACKAGE_ATTR}" -- "$bundle_path"
)"
printf '%s\n' "$persisted_output"
assert_html_payload "$persisted_output" "$EXPECTED_PERSISTED_HTML"

author_filter_output="$(
  nix run --accept-flake-config ".#${SHADOW_RUNTIME_HOST_PACKAGE_ATTR}" -- \
    "$bundle_path" \
    --result-expr "$AUTHOR_FILTER_EXPR"
)"
printf '%s\n' "$author_filter_output"

author_filter_json="$(extract_runtime_json "$author_filter_output")"
python3 -c '
import json
import sys

events = json.loads(sys.argv[1])
expected_ids = ["shadow-note-2", "shadow-note-1"]
actual_ids = [event.get("id") for event in events]
if actual_ids != expected_ids:
    raise SystemExit(f"unexpected filtered ids: {actual_ids!r}")
if any(event.get("pubkey") != "npub-feed-a" for event in events):
    raise SystemExit(f"unexpected filtered pubkeys: {events!r}")
' "$author_filter_json"

printf 'Runtime app nostr cache smoke succeeded: backend=%s db=%s bundle=%s\n' \
  "$SHADOW_RUNTIME_HOST_BACKEND" \
  "$DB_PATH" \
  "$bundle_path"
