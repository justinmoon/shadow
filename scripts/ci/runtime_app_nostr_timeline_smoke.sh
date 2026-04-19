#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

python3 - <<'PY'
import json
import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path


REPO_ROOT = Path.cwd()
SCRIPT_DIR = REPO_ROOT / "scripts"
PREPARE_TIMEOUT_SECONDS = 600


def reserve_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def run(command, *, env=None, input_text=None, timeout=20):
    return subprocess.run(
        command,
        cwd=REPO_ROOT,
        env=env,
        input=input_text,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=True,
    )

def send(process, request):
    assert process.stdin is not None
    process.stdin.write(json.dumps(request) + "\n")
    process.stdin.flush()
    assert process.stdout is not None
    line = process.stdout.readline()
    if not line:
        stderr = process.stderr.read() if process.stderr is not None else ""
        raise SystemExit(
            f"runtime-app-nostr-timeline-smoke: runtime host closed stdout\n{stderr}",
        )
    response = json.loads(line)
    status = response.get("status")
    if status == "error":
        raise SystemExit(
            f"runtime-app-nostr-timeline-smoke: runtime host error: {response['message']}",
        )
    return response


def query_relay_via_websocket(relay_url: str, *, timeout=5):
    script = f"""
const ws = new WebSocket({json.dumps(relay_url)});
const messages = [];
ws.onopen = () => ws.send(JSON.stringify(["REQ", "sub1", {{"kinds": [1], "limit": 10}}]));
ws.onmessage = (event) => {{
  messages.push(String(event.data));
  if (String(event.data).includes('"EOSE"')) {{
    console.log(JSON.stringify(messages));
    ws.close();
  }}
}};
ws.onclose = () => process.exit(0);
setTimeout(() => {{
  console.log(JSON.stringify(messages));
  ws.close();
}}, 2000);
"""
    result = run(["node", "-e", script], timeout=timeout)
    return result.stdout.strip()


with tempfile.TemporaryDirectory(prefix="shadow-nostr-timeline-") as temp_dir:
    temp_path = Path(temp_dir)
    db_path = temp_path / "nostr.sqlite3"
    events_path = temp_path / "relay-events.jsonl"
    key_a = run(["nak", "key", "generate"], timeout=10).stdout.strip()
    key_b = run(["nak", "key", "generate"], timeout=10).stdout.strip()
    seed_relay_port = reserve_port()
    seed_relay_url = f"ws://127.0.0.1:{seed_relay_port}"
    seed_relay = subprocess.Popen(
        [
            "nak",
            "serve",
            "--hostname",
            "127.0.0.1",
            "--port",
            str(seed_relay_port),
        ],
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        assert seed_relay.stderr is not None
        relay_ready = False
        deadline = time.time() + 10
        while time.time() < deadline:
            line = seed_relay.stderr.readline()
            if not line:
                time.sleep(0.1)
                continue
            if "relay running at" in line:
                relay_ready = True
                break
        if not relay_ready:
            raise SystemExit(
                "runtime-app-nostr-timeline-smoke: timed out waiting for local nak relay",
            )

        event_lines = [
            run(
                ["nak", "publish", "--sec", key_a, seed_relay_url],
                input_text="relay smoke alpha\n",
                timeout=20,
            ).stdout.strip(),
            run(
                ["nak", "publish", "--sec", key_b, seed_relay_url],
                input_text="relay smoke beta\n",
                timeout=20,
            ).stdout.strip(),
        ]
        events_path.write_text("\n".join(event_lines) + "\n", encoding="utf-8")
    finally:
        seed_relay.terminate()
        try:
            seed_relay.wait(timeout=3)
        except subprocess.TimeoutExpired:
            seed_relay.kill()
            seed_relay.wait(timeout=3)

    relay_port = reserve_port()
    relay_url = f"ws://127.0.0.1:{relay_port}"
    relay = subprocess.Popen(
        [
            "nak",
            "serve",
            "--hostname",
            "127.0.0.1",
            "--port",
            str(relay_port),
            "--events",
            str(events_path),
        ],
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        assert relay.stderr is not None
        relay_ready = False
        deadline = time.time() + 10
        while time.time() < deadline:
            line = relay.stderr.readline()
            if not line:
                time.sleep(0.1)
                continue
            if "relay running at" in line:
                relay_ready = True
                break
        if not relay_ready:
            raise SystemExit(
                "runtime-app-nostr-timeline-smoke: timed out waiting for seeded nak relay",
            )

        relay_dump = query_relay_via_websocket(relay_url, timeout=10)
        if "relay smoke alpha" not in relay_dump or "relay smoke beta" not in relay_dump:
            raise SystemExit(
                "runtime-app-nostr-timeline-smoke: seeded relay websocket query missing notes",
            )

        prepare_env = os.environ.copy()
        prepare_env.update({
            "SHADOW_RUNTIME_APP_INPUT_PATH": "runtime/app-nostr-timeline/app.tsx",
            "SHADOW_RUNTIME_APP_CACHE_DIR": "build/runtime/app-nostr-timeline",
            "SHADOW_RUNTIME_APP_CONFIG_JSON": json.dumps({
                "limit": 8,
                "relayUrls": [relay_url],
                "syncOnStart": False,
            }),
        })
        session_json = run(
            [str(SCRIPT_DIR / "runtime" / "runtime_prepare_host_session.sh")],
            env=prepare_env,
            timeout=PREPARE_TIMEOUT_SECONDS,
        ).stdout
        session = json.loads(session_json)

        runtime_env = os.environ.copy()
        runtime_env["SHADOW_RUNTIME_NOSTR_DB_PATH"] = str(db_path)
        process = subprocess.Popen(
            [session["systemBinaryPath"], "--session", session["bundlePath"]],
            cwd=REPO_ROOT,
            env=runtime_env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            initial = send(process, {"op": "render"})
            initial_html = initial["payload"]["html"]
            if "Timeline" not in initial_html:
                raise SystemExit(
                    "runtime-app-nostr-timeline-smoke: initial render missing timeline headline",
                )

            clicked = send(
                process,
                {"op": "dispatch", "event": {"targetId": "refresh", "type": "click"}},
            )
            clicked_html = clicked["payload"]["html"]
            if "Talking to relays" not in clicked_html and "Refreshing timeline from relays" not in clicked_html:
                raise SystemExit(
                    "runtime-app-nostr-timeline-smoke: refresh click missing loading state",
                )

            synced_html = None
            deadline = time.time() + 20
            while time.time() < deadline:
                response = send(process, {"op": "render_if_dirty"})
                if response.get("status") == "no_update":
                    time.sleep(0.2)
                    continue
                synced_html = response["payload"]["html"]
                if "relay smoke alpha" in synced_html and "relay smoke beta" in synced_html:
                    break
            if synced_html is None or "relay smoke alpha" not in synced_html or "relay smoke beta" not in synced_html:
                raise SystemExit(
                    "runtime-app-nostr-timeline-smoke: local relay notes never appeared in timeline",
                )

            if process.stdin is not None:
                process.stdin.close()
            process.wait(timeout=10)

            process = subprocess.Popen(
                [session["systemBinaryPath"], "--session", session["bundlePath"]],
                cwd=REPO_ROOT,
                env=runtime_env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            restarted = send(process, {"op": "render"})
            restarted_html = restarted["payload"]["html"]
            for fragment in ("relay smoke alpha", "relay smoke beta"):
                if fragment not in restarted_html:
                    raise SystemExit(
                        "runtime-app-nostr-timeline-smoke: restart lost cached relay note: "
                        f"{fragment}",
                    )
        finally:
            if process.stdin is not None:
                process.stdin.close()
            stderr = process.stderr.read() if process.stderr is not None else ""
            return_code = process.wait(timeout=10)
            if return_code not in (0, None):
                raise SystemExit(
                    f"runtime-app-nostr-timeline-smoke: runtime host exited {return_code}\n{stderr}",
                )
    finally:
        relay.terminate()
        try:
            relay.wait(timeout=3)
        except subprocess.TimeoutExpired:
            relay.kill()
            relay.wait(timeout=3)

print(
    json.dumps(
        {
            "relayUrl": relay_url,
            "result": "timeline-ok",
        },
        indent=2,
    ),
)
PY
