#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./runtime_host_backend_common.sh
source "$SCRIPT_DIR/runtime_host_backend_common.sh"
INPUT_PATH="runtime/app-compile-smoke/app.tsx"
CACHE_DIR="build/runtime/app-document-smoke"
RESULT_EXPR='JSON.stringify(globalThis.SHADOW_RUNTIME_APP.dispatch({type:"click",targetId:"counter"}))'

cd "$REPO_ROOT"
runtime_host_backend_resolve

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

smoke_output="$(
  nix run --accept-flake-config ".#${SHADOW_RUNTIME_HOST_PACKAGE_ATTR}" -- \
    "$bundle_path" \
    --result-expr "$RESULT_EXPR"
)"
printf '%s\n' "$smoke_output"

document_json="$(
  printf '%s\n' "$smoke_output" | python3 -c '
import json
import re
import sys

payload = sys.stdin.read()
for line in reversed(payload.splitlines()):
    match = re.search(r"result=(\{.*\})$", line)
    if not match:
        continue
    document = json.loads(match.group(1))
    html = document.get("html") or ""
    required_fragments = [
        "<main class=\"shell\"",
        "data-shadow-state=\"warm\"",
        "data-shadow-count=\"2\"",
        "data-shadow-id=\"counter\"",
        "data-shadow-card=\"warm\"",
    ]
    for fragment in required_fragments:
        if fragment not in html:
            raise SystemExit("missing html fragment %r in payload: %r" % (fragment, html))
    if document.get("css", None) is not None:
        raise SystemExit("expected css to be null, got: %r" % (document.get("css"),))
    print(json.dumps(document, indent=2))
    break
else:
    raise SystemExit("could not find document payload in runtime host output")
'
)"
printf '%s\n' "$document_json"

printf 'Runtime app click smoke succeeded: backend=%s bundle=%s\n' "$SHADOW_RUNTIME_HOST_BACKEND" "$bundle_path"
