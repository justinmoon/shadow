#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INPUT_PATH="runtime/app-input-smoke/app.tsx"
CACHE_DIR="build/runtime/app-input-smoke"
RESULT_EXPR='JSON.stringify(globalThis.SHADOW_RUNTIME_APP.dispatch({type:"change",targetId:"draft",value:"hello from change"}))'
EXPECTED_HTML='<main class="compose"><label class="field"><span>Draft</span><input class="field-input" data-shadow-id="draft" name="draft" value="hello from change"></label><p class="preview">Preview: hello from change</p></main>'

cd "$REPO_ROOT"

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
  nix run --accept-flake-config .#deno-core-smoke -- \
    "$bundle_path" \
    --result-expr "$RESULT_EXPR"
)"
printf '%s\n' "$smoke_output"

document_json="$(
  printf '%s\n' "$smoke_output" | python3 -c '
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
    print(json.dumps(document, indent=2))
    break
else:
    raise SystemExit("could not find document payload in deno_core output")
' "$EXPECTED_HTML"
)"
printf '%s\n' "$document_json"

printf 'Runtime app input smoke succeeded: %s\n' "$bundle_path"
