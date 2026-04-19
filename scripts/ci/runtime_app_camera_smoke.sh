#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"
if [[ -n "${SHADOW_SYSTEM_BINARY_OVERRIDE:-}" ]]; then
  session_json="$(
    deno run --quiet --allow-env --allow-read --allow-write --allow-run \
      scripts/runtime/runtime_build_artifacts.ts \
      --system-binary-path "${SHADOW_SYSTEM_BINARY_OVERRIDE}" \
      --profile single \
      --app-id app \
      --input runtime/app-camera/app.tsx \
      --cache-dir build/runtime/app-camera
  )"
else
  session_json="$(
    SHADOW_RUNTIME_APP_INPUT_PATH="runtime/app-camera/app.tsx" \
    SHADOW_RUNTIME_APP_CACHE_DIR="build/runtime/app-camera" \
      "$SCRIPT_DIR/runtime/runtime_prepare_host_session.sh"
  )"
fi

SESSION_JSON="$session_json" python3 - <<'PY'
import json
import os
import subprocess
import sys
import time
from html.parser import HTMLParser

session = json.loads(os.environ["SESSION_JSON"])
if "bundlePath" in session:
    bundle_path = session["bundlePath"]
    binary_path = session["systemBinaryPath"]
    system_binary_name = session["systemBinaryName"]
    system_package_attr = session["systemPackageAttr"]
else:
    bundle_path = session["apps"]["app"]["effectiveBundlePath"]
    binary_path = session["systemBinaryPath"]
    system_binary_name = os.path.basename(binary_path)
    system_package_attr = session.get("systemPackageAttr")

process = subprocess.Popen(
    [binary_path, "--session", bundle_path],
    env={**os.environ, "SHADOW_RUNTIME_CAMERA_ALLOW_MOCK": "1"},
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
        raise SystemExit(f"runtime-app-camera-smoke: runtime host closed stdout\n{stderr}")
    return json.loads(line)


def unwrap(response):
    if response.get("status") != "ok":
        raise SystemExit(
            f"runtime-app-camera-smoke: unexpected response: {json.dumps(response)}"
        )
    return response["payload"]


class MainAttrParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.attrs = None

    def handle_starttag(self, tag, attrs):
        if tag == "main" and self.attrs is None:
            self.attrs = dict(attrs)


def attrs(html: str) -> dict[str, str]:
    parser = MainAttrParser()
    parser.feed(html)
    if parser.attrs is None:
        raise SystemExit("runtime-app-camera-smoke: render missing main shell attrs")
    return parser.attrs


initial = unwrap(send({"op": "render"}))
if "Take Photo" not in initial["html"]:
    raise SystemExit("runtime-app-camera-smoke: initial render missing Take Photo button")

ready_html = initial["html"]
deadline = time.time() + 10
while time.time() < deadline:
    response = send({"op": "render_if_dirty"})
    if response.get("status") == "no_update":
        time.sleep(0.1)
        continue
    payload = unwrap(response)
    ready_html = payload["html"]
    if "Ready on" in ready_html:
        break

if "Ready on" not in ready_html:
    raise SystemExit("runtime-app-camera-smoke: app never surfaced camera readiness")

ready_attrs = attrs(ready_html)
if ready_attrs.get("data-shadow-status-kind") != "ready":
    raise SystemExit("runtime-app-camera-smoke: ready render missing status marker")

preview_clicked = unwrap(
    send({"op": "dispatch", "event": {"targetId": "preview-toggle", "type": "click"}})
)
if "Stop Preview" not in preview_clicked["html"]:
    raise SystemExit("runtime-app-camera-smoke: click did not enable preview")

preview_html = preview_clicked["html"]
deadline = time.time() + 15
while time.time() < deadline:
    response = send({"op": "render_if_dirty"})
    if response.get("status") == "no_update":
        time.sleep(0.1)
        continue
    payload = unwrap(response)
    preview_html = payload["html"]
    if "preview active" in preview_html.lower() and "data:image/" in preview_html:
        break

if "preview active" not in preview_html.lower() or "data:image/" not in preview_html:
    raise SystemExit("runtime-app-camera-smoke: app never surfaced a preview frame")

clicked = unwrap(
    send({"op": "dispatch", "event": {"targetId": "capture", "type": "click"}})
)
if "Capturing..." not in clicked["html"]:
    raise SystemExit("runtime-app-camera-smoke: click did not surface capture state")

clicked_attrs = attrs(clicked["html"])
if clicked_attrs.get("data-shadow-status-kind") != "capturing":
    raise SystemExit("runtime-app-camera-smoke: click render missing capturing marker")

final_html = None
deadline = time.time() + 15
while time.time() < deadline:
    response = send({"op": "render_if_dirty"})
    if response.get("status") == "no_update":
        time.sleep(0.2)
        continue
    payload = unwrap(response)
    if "Latest mock photo." in payload["html"] and payload["html"].count("data:image/") >= 1:
        final_html = payload["html"]
        break
    final_html = payload["html"]

if final_html is None:
    raise SystemExit("runtime-app-camera-smoke: timed out waiting for capture result")

if "Latest mock photo." not in final_html:
    raise SystemExit("runtime-app-camera-smoke: final render missing latest capture section")

final_attrs = attrs(final_html)
if final_attrs.get("data-shadow-status-kind") != "ready":
    raise SystemExit("runtime-app-camera-smoke: final render missing ready status marker")
if final_attrs.get("data-shadow-last-capture-is-mock") != "true":
    raise SystemExit("runtime-app-camera-smoke: final render missing mock capture marker")
if not (final_attrs.get("data-shadow-last-capture-bytes") or "").isdigit():
    raise SystemExit("runtime-app-camera-smoke: final render missing capture byte marker")

assert process.stdin is not None
process.stdin.close()
stderr = process.stderr.read() if process.stderr is not None else ""
try:
    return_code = process.wait(timeout=10)
except subprocess.TimeoutExpired:
    process.terminate()
    try:
        return_code = process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        return_code = process.wait(timeout=5)
if return_code not in (0, -15, -9, None):
    raise SystemExit(f"runtime-app-camera-smoke: runtime host exited {return_code}\n{stderr}")

print(
    json.dumps(
        {
            "bundlePath": bundle_path,
            "result": "camera-explicit-mock-capture-ok",
            "systemBinaryName": system_binary_name,
            "systemPackageAttr": system_package_attr,
        },
        indent=2,
    )
)
PY
