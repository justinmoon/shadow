#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

asset_json="$("$SCRIPT_DIR/runtime/prepare_sound_demo_assets.sh")"
runtime_app_config_json="$(
  ASSET_JSON="$asset_json" python3 - <<'PY'
import json
import os

asset = json.loads(os.environ["ASSET_JSON"])
print(json.dumps({"source": asset["source"]}))
PY
)"
url_source_url="https://example.invalid/runtime-audio-url-smoke.mp3"
url_runtime_app_config_json="$(
  ASSET_JSON="$asset_json" URL_SOURCE_URL="$url_source_url" python3 - <<'PY'
import json
import os

asset = json.loads(os.environ["ASSET_JSON"])
print(json.dumps({
    "source": {
        "durationMs": asset["source"]["durationMs"],
        "kind": "url",
        "url": os.environ["URL_SOURCE_URL"],
    }
}))
PY
)"
asset_source_path="$(
  ASSET_JSON="$asset_json" python3 - <<'PY'
import json
import os

asset = json.loads(os.environ["ASSET_JSON"])
print(asset["source"]["path"])
PY
)"
fake_audio_bridge_binary="$REPO_ROOT/scripts/runtime/runtime_audio_linux_spike_fake.sh"

cd "$REPO_ROOT"
session_json="$(
  SHADOW_RUNTIME_APP_CONFIG_JSON="$runtime_app_config_json" \
  SHADOW_RUNTIME_APP_INPUT_PATH="runtime/app-sound-smoke/app.tsx" \
  SHADOW_RUNTIME_APP_CACHE_DIR="build/runtime/app-sound-smoke-host" \
    "$SCRIPT_DIR/runtime/runtime_prepare_host_session.sh"
)"
url_session_json="$(
  SHADOW_RUNTIME_APP_CONFIG_JSON="$url_runtime_app_config_json" \
  SHADOW_RUNTIME_APP_INPUT_PATH="runtime/app-sound-smoke/app.tsx" \
  SHADOW_RUNTIME_APP_CACHE_DIR="build/runtime/app-sound-smoke-host-url" \
    "$SCRIPT_DIR/runtime/runtime_prepare_host_session.sh"
)"

ASSET_SOURCE_PATH="$asset_source_path" \
FAKE_AUDIO_BRIDGE_BINARY="$fake_audio_bridge_binary" \
FILE_SESSION_JSON="$session_json" \
URL_SESSION_JSON="$url_session_json" \
URL_SOURCE_URL="$url_source_url" \
python3 - <<'PY'
import json
import os
import subprocess
import tempfile
import time

file_session = json.loads(os.environ["FILE_SESSION_JSON"])
url_session = json.loads(os.environ["URL_SESSION_JSON"])
asset_source_path = os.environ["ASSET_SOURCE_PATH"]
fake_audio_bridge_binary = os.environ["FAKE_AUDIO_BRIDGE_BINARY"]
url_source_url = os.environ["URL_SOURCE_URL"]

def run_scenario(
    name,
    session,
    extra_env,
    expected_source_fragment,
    capture_path=None,
    after_play=None,
):
    bundle_path = session["bundlePath"]
    binary_path = session["systemBinaryPath"]
    process_env = dict(os.environ)
    process_env.update(extra_env)
    process = subprocess.Popen(
        [binary_path, "--session", bundle_path],
        stdin=subprocess.PIPE,
        env=process_env,
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
                    f"runtime-app-sound-smoke ({name}): runtime host closed stdout\n{stderr}",
                )
            try:
                return json.loads(line)
            except json.JSONDecodeError as error:
                if line.startswith("[shadow-runtime-"):
                    continue
                raise SystemExit(
                    f"runtime-app-sound-smoke ({name}): decode response: {error}\nline={line!r}",
                ) from error

    def send_ok(request):
        response = send_raw(request)
        if response.get("status") != "ok":
            raise SystemExit(
                f"runtime-app-sound-smoke ({name}): unexpected response: {json.dumps(response)}",
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
                    f"runtime-app-sound-smoke ({name}): unexpected response: {json.dumps(response)}",
                )
            payload = response["payload"]
            html = payload["html"]
            if fragment in html:
                return html
            time.sleep(0.05)
        raise SystemExit(
            f"runtime-app-sound-smoke ({name}): timed out waiting for fragment {fragment!r}",
        )

    def wait_for_capture(predicate, description, timeout_seconds=5):
        deadline = time.time() + timeout_seconds
        last_capture = None
        while time.time() < deadline:
            if capture_path is not None and os.path.exists(capture_path):
                try:
                    with open(capture_path, "r", encoding="utf-8") as handle:
                        last_capture = json.load(handle)
                except json.JSONDecodeError:
                    time.sleep(0.05)
                    continue
                if predicate(last_capture):
                    return last_capture
            time.sleep(0.05)
        raise SystemExit(
            "runtime-app-sound-smoke "
            f"({name}): timed out waiting for capture {description}; last={last_capture}"
        )

    def dispatch_and_wait(target_id, fragment):
        payload = send_ok({"op": "dispatch", "event": {"targetId": target_id, "type": "click"}})
        html = payload["html"]
        if fragment in html:
            return html
        return wait_for_fragment(fragment)

    try:
        initial = send_ok({"op": "render"})
        prepared_html = dispatch_and_wait("prepare", "State:</span> idle")
        playing_html = dispatch_and_wait("play", "State:</span> playing")
        if after_play is not None:
            after_play(dispatch_and_wait, wait_for_capture)
        stopped_html = dispatch_and_wait("stop", "State:</span> stopped")
        released_html = dispatch_and_wait("release", "State:</span> released")

        initial_html = initial["html"]
        if "Linux audio seam" not in initial_html:
            raise SystemExit(
                f"runtime-app-sound-smoke ({name}): initial render missing headline"
            )
        if "State:</span> missing" not in initial_html:
            raise SystemExit(
                f"runtime-app-sound-smoke ({name}): initial render missing unprepared state"
            )
        if "State:</span> idle" not in prepared_html:
            raise SystemExit(
                f"runtime-app-sound-smoke ({name}): prepare click did not surface idle state"
            )
        if expected_source_fragment not in prepared_html:
            raise SystemExit(
                f"runtime-app-sound-smoke ({name}): expected source label {expected_source_fragment!r}"
            )
        if "State:</span> playing" not in playing_html:
            raise SystemExit(
                f"runtime-app-sound-smoke ({name}): play click did not surface playing state"
            )
        if "State:</span> stopped" not in stopped_html:
            raise SystemExit(
                f"runtime-app-sound-smoke ({name}): stop click did not surface stopped state"
            )
        if "State:</span> released" not in released_html:
            raise SystemExit(
                f"runtime-app-sound-smoke ({name}): release click did not surface released state"
            )
    finally:
        assert process.stdin is not None
        process.stdin.close()
        timed_out = False
        try:
            return_code = process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            timed_out = True
            process.kill()
            return_code = process.wait(timeout=5)
        stderr = process.stderr.read() if process.stderr is not None else ""
        if timed_out:
            raise SystemExit(
                f"runtime-app-sound-smoke ({name}): runtime host did not exit cleanly\n{stderr}",
            )
        if return_code not in (0, None):
            raise SystemExit(
                f"runtime-app-sound-smoke ({name}): runtime host exited {return_code}\n{stderr}",
            )

    return {
        "bundle_path": bundle_path,
        "backend_fragment": prepared_html,
    }


memory = run_scenario(
    "memory",
    file_session,
    {},
    f"Source:</span> file / {asset_source_path}",
)
if "Backend:</span> memory" not in memory["backend_fragment"]:
    raise SystemExit("runtime-app-sound-smoke (memory): expected memory backend label")

with tempfile.TemporaryDirectory() as tmp_dir:
    session_config_path = os.path.join(tmp_dir, "session-config.json")
    with open(session_config_path, "w", encoding="utf-8") as handle:
        json.dump(
            {
                "services": {
                    "audioBackend": "memory",
                }
            },
            handle,
        )

    config_memory = run_scenario(
        "config_memory_overrides_env",
        file_session,
        {
            "SHADOW_RUNTIME_SESSION_CONFIG": session_config_path,
            "SHADOW_RUNTIME_AUDIO_BACKEND": "linux_bridge",
        },
        f"Source:</span> file / {asset_source_path}",
    )
    if "Backend:</span> memory" not in config_memory["backend_fragment"]:
        raise SystemExit(
            "runtime-app-sound-smoke (config_memory_overrides_env): expected memory backend label"
        )

    file_capture_path = os.path.join(tmp_dir, "linux-bridge-file.json")
    captured_results = {}

    def expect_gain(capture):
        gain = capture.get("gain")
        start_ms = capture.get("startMs")
        return (
            gain is not None
            and start_ms is not None
            and abs(float(gain) - 1.0) < 0.01
            and int(start_ms) == 0
        )

    def expect_seek(capture):
        start_ms = capture.get("startMs")
        return start_ms is not None and int(start_ms) >= 1_000

    def expect_volume(capture):
        gain = capture.get("gain")
        start_ms = capture.get("startMs")
        return (
            gain is not None
            and start_ms is not None
            and abs(float(gain) - 0.4) < 0.01
            and int(start_ms) >= 1_000
        )

    def verify_file_linux_bridge(dispatch_and_wait, wait_for_capture):
        wait_for_capture(expect_gain, "initial play gain")
        dispatch_and_wait("seek-forward", "Seeked forward by one second.")
        wait_for_capture(expect_seek, "seek startMs")
        dispatch_and_wait("volume-down", "Player volume reduced.")
        wait_for_capture(expect_volume, "volume gain and persisted startMs")

    def expect_url_capture(capture):
        return (
            capture.get("sourceKind") == "url"
            and capture.get("url") == url_source_url
        )

    def verify_url_linux_bridge(_dispatch_and_wait, wait_for_capture):
        captured_results["url"] = wait_for_capture(
            expect_url_capture,
            "url source handoff",
        )

    url_capture_path = os.path.join(tmp_dir, "linux-bridge-url.json")
    linux_bridge_url = run_scenario(
        "linux_bridge_url",
        url_session,
        {
            "SHADOW_RUNTIME_AUDIO_BACKEND": "linux_bridge",
            "SHADOW_RUNTIME_AUDIO_BRIDGE_BINARY": fake_audio_bridge_binary,
            "SHADOW_AUDIO_SPIKE_TEST_OUTPUT": url_capture_path,
            "SHADOW_AUDIO_SPIKE_TEST_SLEEP_SECS": "0.2",
        },
        f"Source:</span> url / {url_source_url}",
        url_capture_path,
        verify_url_linux_bridge,
    )
    if "Backend:</span> linux_bridge" not in linux_bridge_url["backend_fragment"]:
        raise SystemExit(
            "runtime-app-sound-smoke (linux_bridge_url): expected linux_bridge backend label"
        )
    linux_bridge = run_scenario(
        "linux_bridge",
        file_session,
        {
            "SHADOW_RUNTIME_AUDIO_BACKEND": "linux_bridge",
            "SHADOW_RUNTIME_AUDIO_BRIDGE_BINARY": fake_audio_bridge_binary,
            "SHADOW_AUDIO_SPIKE_TEST_OUTPUT": file_capture_path,
            "SHADOW_AUDIO_SPIKE_TEST_SLEEP_SECS": "5",
        },
        f"Source:</span> file / {asset_source_path}",
        file_capture_path,
        verify_file_linux_bridge,
    )
    if "Backend:</span> linux_bridge" not in linux_bridge["backend_fragment"]:
        raise SystemExit(
            "runtime-app-sound-smoke (linux_bridge): expected linux_bridge backend label"
        )
    url_capture = captured_results.get("url")
    if url_capture is None:
        raise SystemExit(
            "runtime-app-sound-smoke (linux_bridge_url): missing captured url handoff"
        )

print(json.dumps({
    "systemPackageAttr": file_session["systemPackageAttr"],
    "systemBinaryName": file_session["systemBinaryName"],
    "bundlePath": file_session["bundlePath"],
    "result": "sound-audio-api-ok",
    "linuxBridgeProtocolGuard": "ok",
}, indent=2))
PY
