#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"
session_json="$("$SCRIPT_DIR/runtime/runtime_prepare_host_session.sh")"

SESSION_JSON="$session_json" python3 - <<'PY'
import json
import os
import subprocess
import sys

session = json.loads(os.environ["SESSION_JSON"])
bundle_path = session["bundlePath"]
binary_path = session["systemBinaryPath"]

process = subprocess.Popen(
    [binary_path, "--session", bundle_path],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)


def send(request):
    assert process.stdin is not None
    process.stdin.write(json.dumps(request) + "\n")
    process.stdin.flush()
    assert process.stdout is not None
    line = process.stdout.readline()
    if not line:
        stderr = process.stderr.read() if process.stderr is not None else ""
        raise SystemExit(
            f"runtime-app-keyboard-smoke: runtime host closed stdout\n{stderr}",
        )
    response = json.loads(line)
    if response.get("status") != "ok":
        raise SystemExit(
            f"runtime-app-keyboard-smoke: unexpected response: {json.dumps(response)}",
        )
    return response["payload"]


initial = send({"op": "render"})
focused = send({"op": "dispatch", "event": {"targetId": "draft", "type": "focus"}})
focused_text_input = focused.get("textInput")
send({
    "op": "dispatch",
    "event": {
        "targetId": "draft",
        "type": "keydown",
        "keyboard": {
            "key": "G",
            "code": "KeyG",
            "shiftKey": True,
            "ctrlKey": False,
            "altKey": False,
            "metaKey": False,
        },
    },
})
send({
    "op": "dispatch",
    "event": {
        "targetId": "draft",
        "type": "input",
        "value": "G",
        "selection": {"start": 1, "end": 1, "direction": "none"},
    },
})
send({
    "op": "dispatch",
    "event": {
        "targetId": "draft",
        "type": "keydown",
        "keyboard": {
            "key": "m",
            "code": "KeyM",
            "shiftKey": False,
            "ctrlKey": False,
            "altKey": False,
            "metaKey": False,
        },
    },
})
send({
    "op": "dispatch",
    "event": {
        "targetId": "draft",
        "type": "input",
        "value": "GM",
        "selection": {"start": 2, "end": 2, "direction": "none"},
    },
})
send({
    "op": "dispatch",
    "event": {
        "targetId": "draft",
        "type": "keydown",
        "keyboard": {
            "key": "Backspace",
            "code": "Backspace",
            "shiftKey": False,
            "ctrlKey": False,
            "altKey": False,
            "metaKey": False,
        },
    },
})
send({
    "op": "dispatch",
    "event": {
        "targetId": "draft",
        "type": "input",
        "value": "G",
        "selection": {"start": 1, "end": 1, "direction": "none"},
    },
})
final_payload = send({"op": "dispatch", "event": {"targetId": "draft", "type": "blur"}})

assert process.stdin is not None
process.stdin.close()
stderr = process.stderr.read() if process.stderr is not None else ""
return_code = process.wait(timeout=10)
if return_code not in (0, None):
    raise SystemExit(
        f"runtime-app-keyboard-smoke: runtime host exited {return_code}\n{stderr}",
    )

initial_html = initial["html"]
focused_html = focused["html"]
final_html = final_payload["html"]

if "English text seam" not in initial_html:
    raise SystemExit("runtime-app-keyboard-smoke: initial render missing keyboard headline")
if "Focus: focused" not in focused_html:
    raise SystemExit("runtime-app-keyboard-smoke: focus event did not update state")
if focused_text_input is None:
    raise SystemExit("runtime-app-keyboard-smoke: focus response missing textInput payload")
if focused_text_input.get("targetId") != "draft":
    raise SystemExit(
        "runtime-app-keyboard-smoke: unexpected textInput target "
        f"{json.dumps(focused_text_input)}",
    )

expected_fragments = [
    "Focus: blurred",
    "Draft: G",
    "Selection: 1-1:none",
    "G / KeyG / shift",
    "m / KeyM / none",
    "Backspace / Backspace / none",
]
for fragment in expected_fragments:
    if fragment not in final_html:
        raise SystemExit(
            f"runtime-app-keyboard-smoke: final render missing fragment: {fragment}",
        )

print(json.dumps({
    "systemPackageAttr": session["systemPackageAttr"],
    "systemBinaryName": session["systemBinaryName"],
    "bundlePath": bundle_path,
    "result": "keyboard-ok",
}, indent=2))
PY
