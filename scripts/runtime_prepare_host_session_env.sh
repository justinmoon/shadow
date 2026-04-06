#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"
session_json="$("$SCRIPT_DIR/runtime_prepare_host_session.sh")"

SESSION_JSON="$session_json" python3 - <<'PY'
import json
import os
import shlex

data = json.loads(os.environ["SESSION_JSON"])
bundle_path = data["bundlePath"]
rewrite_from = os.environ.get("SHADOW_RUNTIME_APP_BUNDLE_REWRITE_FROM")
rewrite_to = os.environ.get("SHADOW_RUNTIME_APP_BUNDLE_REWRITE_TO")
if rewrite_from and rewrite_to and bundle_path.startswith(rewrite_from):
    bundle_path = rewrite_to + bundle_path[len(rewrite_from):]

exports = {
    "SHADOW_BLITZ_DEMO_MODE": "runtime",
    "SHADOW_RUNTIME_APP_BUNDLE_PATH": bundle_path,
    "SHADOW_RUNTIME_HOST_BINARY_PATH": data["runtimeHostBinaryPath"],
    "SHADOW_RUNTIME_HOST_BACKEND": data["runtimeHostBackend"],
}

for key, value in exports.items():
    print(f"export {key}={shlex.quote(str(value))}")
PY
