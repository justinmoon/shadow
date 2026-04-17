#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

asset_json="$("$SCRIPT_DIR/runtime/prepare_podcast_player_demo_assets.sh")"
asset_dir="$(
  ASSET_JSON="$asset_json" python3 - <<'PY'
import json
import os

print(json.loads(os.environ["ASSET_JSON"])["assetDir"])
PY
)"
runtime_app_config_json="$(
  ASSET_JSON="$asset_json" python3 - <<'PY'
import json
import os

asset = json.loads(os.environ["ASSET_JSON"])
asset.pop("assetDir", None)
print(json.dumps(asset))
PY
)"

cd "$REPO_ROOT"
session_json="$(
  SHADOW_RUNTIME_APP_CONFIG_JSON="$runtime_app_config_json" \
  SHADOW_RUNTIME_APP_INPUT_PATH="runtime/app-podcast-player/app.tsx" \
  SHADOW_RUNTIME_APP_CACHE_DIR="build/runtime/app-podcast-player-host" \
    "$SCRIPT_DIR/runtime/runtime_prepare_host_session.sh"
)"

ASSET_DIR="$asset_dir" SESSION_JSON="$session_json" python3 - <<'PY'
import json
import os
import shutil
import subprocess
import time

asset_dir = os.environ["ASSET_DIR"]
session = json.loads(os.environ["SESSION_JSON"])
bundle_dir = session["bundleDir"]
bundle_path = session["bundlePath"]
binary_path = session["runtimeHostBinaryPath"]

for name in os.listdir(asset_dir):
    source_path = os.path.join(asset_dir, name)
    target_path = os.path.join(bundle_dir, name)
    if os.path.isdir(source_path):
        shutil.copytree(source_path, target_path, dirs_exist_ok=True)
    else:
        shutil.copy2(source_path, target_path)

process = subprocess.Popen(
    [binary_path, "--session", bundle_path],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)

def send_raw(request):
    assert process.stdin is not None
    process.stdin.write(json.dumps(request) + "\n")
    process.stdin.flush()
    assert process.stdout is not None
    while True:
        line = process.stdout.readline()
        if not line:
            stderr = process.stderr.read() if process.stderr is not None else ""
            raise SystemExit(
                f"runtime-app-podcast-player-smoke: runtime host closed stdout\n{stderr}",
            )
        try:
            return json.loads(line)
        except json.JSONDecodeError as error:
            if line.startswith("[shadow-runtime-"):
                continue
            raise SystemExit(
                "runtime-app-podcast-player-smoke: decode response: "
                f"{error}\nline={line!r}"
            ) from error

def send_ok(request):
    response = send_raw(request)
    if response.get("status") != "ok":
        raise SystemExit(
            f"runtime-app-podcast-player-smoke: unexpected response: {json.dumps(response)}",
        )
    return response["payload"]

def wait_for_fragment(fragment, timeout_seconds=5):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        response = send_raw({"op": "render_if_dirty"})
        if response.get("status") == "no_update":
            time.sleep(0.05)
            continue
        if response.get("status") != "ok":
            raise SystemExit(
                f"runtime-app-podcast-player-smoke: unexpected response: {json.dumps(response)}",
            )
        html = response["payload"]["html"]
        if fragment in html:
            return html
        time.sleep(0.05)
    raise SystemExit(
        f"runtime-app-podcast-player-smoke: timed out waiting for fragment {fragment!r}",
    )

def dispatch_and_wait(target_id, fragment):
    payload = send_ok({"op": "dispatch", "event": {"targetId": target_id, "type": "click"}})
    html = payload["html"]
    if fragment in html:
        return html
    return wait_for_fragment(fragment)

initial = send_ok({"op": "render"})
playing_html = dispatch_and_wait("play-00", "State:</span> playing")
stopped_html = dispatch_and_wait("stop", "State:</span> stopped")
released_html = dispatch_and_wait("release", "State:</span> released")

assert process.stdin is not None
process.stdin.close()
stderr = process.stderr.read() if process.stderr is not None else ""
return_code = process.wait(timeout=10)
if return_code not in (0, None):
    raise SystemExit(
        f"runtime-app-podcast-player-smoke: runtime host exited {return_code}\n{stderr}",
    )

initial_html = initial["html"]
if "No Solutions player" not in initial_html:
    raise SystemExit("runtime-app-podcast-player-smoke: missing headline")
if "#00: Test Recording / Teaser w/ Pablo" not in initial_html:
    raise SystemExit("runtime-app-podcast-player-smoke: missing episode list")
if "Backend:</span> memory" not in playing_html:
    raise SystemExit("runtime-app-podcast-player-smoke: expected memory backend")
if "Current:</span> #00: Test Recording / Teaser w/ Pablo" not in playing_html:
    raise SystemExit("runtime-app-podcast-player-smoke: missing active episode")
if "Source:</span> assets/podcast/00-test-recording-teaser-w-pablo.mp3" not in playing_html:
    raise SystemExit("runtime-app-podcast-player-smoke: missing first episode source path")
if "State:</span> stopped" not in stopped_html:
    raise SystemExit("runtime-app-podcast-player-smoke: stop did not update state")
if "State:</span> released" not in released_html:
    raise SystemExit("runtime-app-podcast-player-smoke: release did not update state")

print(json.dumps({
    "bundlePath": bundle_path,
    "result": "podcast-player-audio-api-ok",
    "runtimeHostBinaryName": session["runtimeHostBinaryName"],
    "runtimeHostPackageAttr": session["runtimeHostPackageAttr"],
}, indent=2))
PY
