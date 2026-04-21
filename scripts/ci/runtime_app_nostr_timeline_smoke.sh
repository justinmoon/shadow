#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

python3 - <<'PY'
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


REPO_ROOT = Path.cwd()
SCRIPT_DIR = REPO_ROOT / "scripts"
PREPARE_TIMEOUT_SECONDS = 600

sys.path.insert(0, str(SCRIPT_DIR / "ci" / "lib"))
from nostr_test_harness import build_text_note_events, run, running_relay

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


with tempfile.TemporaryDirectory(prefix="shadow-nostr-timeline-") as temp_dir:
    temp_path = Path(temp_dir)
    db_path = temp_path / "nostr.sqlite3"
    event_lines = build_text_note_events(
        REPO_ROOT,
        ["relay smoke alpha", "relay smoke beta"],
    )

    with running_relay(
        REPO_ROOT,
        event_lines=event_lines,
        prefix="shadow-nostr-timeline-relay-",
    ) as relay:
        relay_url = relay.url
        relay_dump = relay.query_kind1(limit=10, timeout=10)
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
            REPO_ROOT,
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
