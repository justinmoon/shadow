#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INPUT_PATH="runtime/app-focus-smoke/app.tsx"
CACHE_DIR="build/runtime/app-focus-smoke"
EXPECTED_FOCUS_HTML='<main class="compose"><label class="field"><span>Draft</span><input class="field-input" data-shadow-id="draft" name="draft" value="ready"></label><p class="status">Focus: focus:draft</p><p class="status">Last: focus:draft:draft:ready</p><p class="preview">Preview: ready</p></main>'
EXPECTED_INPUT_HTML='<main class="compose"><label class="field"><span>Draft</span><input class="field-input" data-shadow-id="draft" name="draft" value="hello from input"></label><p class="status">Focus: focus:draft</p><p class="status">Last: input:draft:draft:hello from input</p><p class="preview">Preview: hello from input</p></main>'
EXPECTED_BLUR_HTML='<main class="compose"><label class="field"><span>Draft</span><input class="field-input" data-shadow-id="draft" name="draft" value="hello from input"></label><p class="status">Focus: blurred</p><p class="status">Last: blur:draft:draft:hello from input</p><p class="preview">Preview: hello from input</p></main>'

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

python3 - "$runtime_host_binary_path" "$bundle_path" "$EXPECTED_FOCUS_HTML" "$EXPECTED_INPUT_HTML" "$EXPECTED_BLUR_HTML" "$runtime_backend" <<'PY'
import json
import subprocess
import sys

binary_path, bundle_path, expected_focus_html, expected_input_html, expected_blur_html, backend = sys.argv[1:7]

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
    focus_payload = request({
        "op": "dispatch",
        "event": {"type": "focus", "targetId": "draft"},
    })
    if focus_payload.get("html") != expected_focus_html:
        raise SystemExit(f"unexpected focus payload: {focus_payload.get('html')!r}")
    if focus_payload.get("css", None) is not None:
        raise SystemExit(f"expected focus css to be null, got: {focus_payload.get('css')!r}")

    input_payload = request({
        "op": "dispatch",
        "event": {"type": "input", "targetId": "draft", "value": "hello from input"},
    })
    if input_payload.get("html") != expected_input_html:
        raise SystemExit(f"unexpected input payload: {input_payload.get('html')!r}")
    if input_payload.get("css", None) is not None:
        raise SystemExit(f"expected input css to be null, got: {input_payload.get('css')!r}")

    blur_payload = request({
        "op": "dispatch",
        "event": {"type": "blur", "targetId": "draft"},
    })
    if blur_payload.get("html") != expected_blur_html:
        raise SystemExit(f"unexpected blur payload: {blur_payload.get('html')!r}")
    if blur_payload.get("css", None) is not None:
        raise SystemExit(f"expected blur css to be null, got: {blur_payload.get('css')!r}")

    print(json.dumps({
        "focus": focus_payload,
        "input": input_payload,
        "blur": blur_payload,
    }, indent=2))
    print(f"Runtime app focus smoke succeeded: backend={backend} bundle={bundle_path}")
finally:
    proc.stdin.close()
    proc.stdout.close()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
PY
