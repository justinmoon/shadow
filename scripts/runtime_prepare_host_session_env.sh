#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"
default_session_json="$("$SCRIPT_DIR/runtime_prepare_host_session.sh")"
counter_session_json="$(
  SHADOW_RUNTIME_APP_INPUT_PATH="runtime/app-counter/app.tsx" \
  SHADOW_RUNTIME_APP_CACHE_DIR="build/runtime/app-counter-host" \
    "$SCRIPT_DIR/runtime_prepare_host_session.sh"
)"
timeline_session_json="$(
  SHADOW_RUNTIME_APP_CONFIG_JSON='{"limit":12,"syncOnStart":false}' \
  SHADOW_RUNTIME_APP_INPUT_PATH="runtime/app-nostr-timeline/app.tsx" \
  SHADOW_RUNTIME_APP_CACHE_DIR="build/runtime/app-nostr-timeline-host" \
    "$SCRIPT_DIR/runtime_prepare_host_session.sh"
)"

DEFAULT_SESSION_JSON="$default_session_json" \
COUNTER_SESSION_JSON="$counter_session_json" \
TIMELINE_SESSION_JSON="$timeline_session_json" \
python3 - <<'PY'
import json
import os
import shlex

default_session = json.loads(os.environ["DEFAULT_SESSION_JSON"])
counter_session = json.loads(os.environ["COUNTER_SESSION_JSON"])
timeline_session = json.loads(os.environ["TIMELINE_SESSION_JSON"])
rewrite_from = os.environ.get("SHADOW_RUNTIME_APP_BUNDLE_REWRITE_FROM")
rewrite_to = os.environ.get("SHADOW_RUNTIME_APP_BUNDLE_REWRITE_TO")


def rewrite(path: str) -> str:
    if rewrite_from and rewrite_to and path.startswith(rewrite_from):
        return rewrite_to + path[len(rewrite_from):]
    return path

exports = {
    "SHADOW_RUNTIME_APP_BUNDLE_PATH": rewrite(default_session["bundlePath"]),
    "SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH": rewrite(counter_session["bundlePath"]),
    "SHADOW_RUNTIME_APP_TIMELINE_BUNDLE_PATH": rewrite(timeline_session["bundlePath"]),
    "SHADOW_RUNTIME_HOST_BINARY_PATH": default_session["runtimeHostBinaryPath"],
    "SHADOW_RUNTIME_NOSTR_DB_PATH": "/var/lib/shadow-ui/runtime-nostr.sqlite3",
}

for key, value in exports.items():
    print(f"export {key}={shlex.quote(str(value))}")
PY
