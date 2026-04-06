#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"
session_json="$("$SCRIPT_DIR/runtime_prepare_host_session.sh")"

SESSION_JSON="$session_json" python3 - <<'PY'
import json
import os
import subprocess
import sys

session = json.loads(os.environ["SESSION_JSON"])
bundle_path = session["bundlePath"]
binary_path = session["runtimeHostBinaryPath"]

process = subprocess.Popen(
    [binary_path, "--session", bundle_path],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)

requests = [
    {"op": "render"},
    {"op": "dispatch", "event": {"targetId": "gm", "type": "click"}},
]

responses = []
for request in requests:
    assert process.stdin is not None
    process.stdin.write(json.dumps(request) + "\n")
    process.stdin.flush()
    assert process.stdout is not None
    line = process.stdout.readline()
    if not line:
        stderr = process.stderr.read() if process.stderr is not None else ""
        raise SystemExit(f"runtime-app-nostr-gm-smoke: runtime host closed stdout\n{stderr}")
    responses.append(json.loads(line))

assert process.stdin is not None
process.stdin.close()
stderr = process.stderr.read() if process.stderr is not None else ""
return_code = process.wait(timeout=10)
if return_code not in (0, None):
    raise SystemExit(f"runtime-app-nostr-gm-smoke: runtime host exited {return_code}\n{stderr}")

initial = responses[0]
clicked = responses[1]

def unwrap_payload(response):
    if response.get("status") != "ok":
        raise SystemExit(f"runtime-app-nostr-gm-smoke: unexpected response: {json.dumps(response)}")
    return response["payload"]

initial_payload = unwrap_payload(initial)
clicked_payload = unwrap_payload(clicked)

initial_html = initial_payload["html"]
clicked_html = clicked_payload["html"]

if "Tap to send GM" not in initial_html:
    raise SystemExit("runtime-app-nostr-gm-smoke: initial render missing GM call-to-action")

if "GM sent" not in clicked_html and "Relay publish failed" not in clicked_html:
    raise SystemExit("runtime-app-nostr-gm-smoke: click did not transition to success/error state")

print(json.dumps({
    "runtimeHostPackageAttr": session["runtimeHostPackageAttr"],
    "runtimeHostBinaryName": session["runtimeHostBinaryName"],
    "bundlePath": bundle_path,
    "result": "GM sent" if "GM sent" in clicked_html else "Relay publish failed",
}, indent=2))
PY
