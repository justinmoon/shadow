#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INPUT_PATH="runtime/app-selection-smoke/app.tsx"
CACHE_DIR="build/runtime/app-selection-smoke"
EXPECTED_SELECTED_HTML='<main class="compose"><label class="field"><span>Draft</span><input class="field-input" data-shadow-id="draft" name="draft" value="hello brave world"></label><p class="status">Selection: 6-11 forward (hello brave world)</p><p class="preview">Preview: hello brave world</p></main>'
EXPECTED_COLLAPSED_HTML='<main class="compose"><label class="field"><span>Draft</span><input class="field-input" data-shadow-id="draft" name="draft" value="hello brave world"></label><p class="status">Selection: 5-5 none (hello brave world)</p><p class="preview">Preview: hello brave world</p></main>'

cd "$REPO_ROOT"

session_json="$(
  SHADOW_RUNTIME_APP_INPUT_PATH="$INPUT_PATH" \
  SHADOW_RUNTIME_APP_CACHE_DIR="$CACHE_DIR" \
  scripts/runtime_prepare_host_session.sh
)"
printf '%s\n' "$session_json"

bundle_path="$(
  printf '%s\n' "$session_json" | python3 -c 'import json, sys; print(json.load(sys.stdin)["bundlePath"])'
)"
runtime_host_binary_path="$(
  printf '%s\n' "$session_json" | python3 -c 'import json, sys; print(json.load(sys.stdin)["runtimeHostBinaryPath"])'
)"
runtime_backend="$(
  printf '%s\n' "$session_json" | python3 -c 'import json, sys; print(json.load(sys.stdin)["runtimeHostBackend"])'
)"

python3 - "$runtime_host_binary_path" "$bundle_path" "$EXPECTED_SELECTED_HTML" "$EXPECTED_COLLAPSED_HTML" "$runtime_backend" <<'PY'
import json
import subprocess
import sys

binary_path, bundle_path, expected_selected_html, expected_collapsed_html, backend = sys.argv[1:6]

proc = subprocess.Popen(
    [binary_path, "--session", bundle_path],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=None,
    text=True,
)

assert proc.stdin is not None
assert proc.stdout is not None

def request(payload):
    proc.stdin.write(json.dumps(payload) + "\n")
    proc.stdin.flush()
    line = proc.stdout.readline()
    if not line:
        raise SystemExit("runtime session closed stdout")
    response = json.loads(line)
    if response.get("status") != "ok":
        raise SystemExit(f"runtime session returned error: {response}")
    return response["payload"]

try:
    selected_payload = request({
        "op": "dispatch",
        "event": {
            "type": "input",
            "targetId": "draft",
            "value": "hello brave world",
            "selection": {"start": 6, "end": 11, "direction": "forward"},
        },
    })
    if selected_payload.get("html") != expected_selected_html:
        raise SystemExit(f"unexpected selected payload: {selected_payload.get('html')!r}")
    if selected_payload.get("css", None) is not None:
        raise SystemExit(f"expected selected css to be null, got: {selected_payload.get('css')!r}")

    collapsed_payload = request({
        "op": "dispatch",
        "event": {
            "type": "input",
            "targetId": "draft",
            "selection": {"start": 5, "end": 5, "direction": "none"},
        },
    })
    if collapsed_payload.get("html") != expected_collapsed_html:
        raise SystemExit(f"unexpected collapsed payload: {collapsed_payload.get('html')!r}")
    if collapsed_payload.get("css", None) is not None:
        raise SystemExit(f"expected collapsed css to be null, got: {collapsed_payload.get('css')!r}")

    print(json.dumps({
        "selected": selected_payload,
        "collapsed": collapsed_payload,
    }, indent=2))
    print(f"Runtime app selection smoke succeeded: backend={backend} bundle={bundle_path}")
finally:
    proc.stdin.close()
    proc.stdout.close()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
PY
