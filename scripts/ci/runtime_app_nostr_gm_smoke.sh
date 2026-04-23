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
from nostr_test_harness import run, running_relay

def read_response_line() -> dict:
    assert process.stdout is not None
    while True:
        line = process.stdout.readline()
        if not line:
            stderr = process.stderr.read() if process.stderr is not None else ""
            raise SystemExit(f"runtime-app-nostr-gm-smoke: runtime host closed stdout\n{stderr}")
        stripped = line.lstrip()
        if not stripped.startswith("{"):
            continue
        return json.loads(stripped)

def unwrap_payload(response):
    if response.get("status") != "ok":
        raise SystemExit(f"runtime-app-nostr-gm-smoke: unexpected response: {json.dumps(response)}")
    return response["payload"]

with tempfile.TemporaryDirectory(prefix="shadow-nostr-gm-") as temp_dir:
    temp_path = Path(temp_dir)
    config_db_path = temp_path / "n.sqlite3"
    config_socket_path = temp_path / "n.sock"
    config_log_path = config_socket_path.with_suffix(".log")
    env_db_path = temp_path / "e.sqlite3"
    env_socket_path = temp_path / "e.sock"
    env_log_path = env_socket_path.with_suffix(".log")
    session_config_path = temp_path / "s.json"
    session_config_path.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "services": {
                    "nostrDbPath": str(config_db_path),
                    "nostrServiceSocket": str(config_socket_path),
                },
            }
        ),
        encoding="utf-8",
    )

    with running_relay(REPO_ROOT, prefix="shadow-nostr-gm-relay-") as relay:
        prepare_env = os.environ.copy()
        prepare_env.update({
            "SHADOW_RUNTIME_APP_INPUT_PATH": "runtime/app-nostr-gm/app.tsx",
            "SHADOW_RUNTIME_APP_CACHE_DIR": "build/runtime/app-nostr-gm",
            "SHADOW_RUNTIME_APP_CONFIG_JSON": json.dumps({
                "relayUrls": [relay.url],
                "timeoutMs": 12_000,
            }),
        })
        session_json = run(
            REPO_ROOT,
            [str(SCRIPT_DIR / "runtime" / "runtime_prepare_host_session.sh")],
            env=prepare_env,
            timeout=PREPARE_TIMEOUT_SECONDS,
        ).stdout
        session = json.loads(session_json)
        bundle_path = session["bundlePath"]
        binary_path = session["systemBinaryPath"]

        process = subprocess.Popen(
            [binary_path, "--session", bundle_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={
                **os.environ,
                "SHADOW_RUNTIME_SESSION_CONFIG": str(session_config_path),
                "SHADOW_RUNTIME_NOSTR_DB_PATH": str(env_db_path),
                "SHADOW_RUNTIME_NOSTR_SERVICE_SOCKET": str(env_socket_path),
                "SHADOW_SYSTEM_PROMPT_RESPONSE_ACTION_ID": "allow_once",
            },
        )
        try:
            responses = []
            for request in (
                {"op": "render"},
                {"op": "dispatch", "event": {"targetId": "gm", "type": "click"}},
            ):
                assert process.stdin is not None
                process.stdin.write(json.dumps(request) + "\n")
                process.stdin.flush()
                responses.append(read_response_line())

            initial_html = unwrap_payload(responses[0])["html"]
            clicked_html = unwrap_payload(responses[1])["html"]

            if "Tap to send GM" not in initial_html:
                raise SystemExit("runtime-app-nostr-gm-smoke: initial render missing GM call-to-action")

            if "Publishing GM" not in clicked_html and "GM sent" not in clicked_html:
                raise SystemExit(
                    "runtime-app-nostr-gm-smoke: click did not surface deterministic publish progress",
                )

            final_html = None
            deadline = time.time() + 25
            while time.time() < deadline:
                assert process.stdin is not None
                process.stdin.write(json.dumps({"op": "render_if_dirty"}) + "\n")
                process.stdin.flush()
                response = read_response_line()
                if response.get("status") == "no_update":
                    time.sleep(0.25)
                    continue
                final_html = unwrap_payload(response)["html"]
                break

            if final_html is None:
                raise SystemExit("runtime-app-nostr-gm-smoke: timed out waiting for publish completion")

            if "GM sent" not in final_html:
                raise SystemExit(
                    "runtime-app-nostr-gm-smoke: publish did not complete successfully\n"
                    f"{final_html}",
                )

            if "system prompt is unavailable" in final_html:
                raise SystemExit("runtime-app-nostr-gm-smoke: publish still depended on compositor prompt UI")

            relay_dump = relay.query_kind1(limit=20, timeout=10)
            relay_messages = json.loads(relay_dump)
            if not any('"content":"GM"' in message for message in relay_messages):
                raise SystemExit(
                    "runtime-app-nostr-gm-smoke: local relay never observed the GM note\n"
                    f"{relay_dump}",
                )
            if not config_db_path.exists():
                raise SystemExit(
                    "runtime-app-nostr-gm-smoke: session-config Nostr DB path was never created",
                )
            if env_db_path.exists():
                raise SystemExit(
                    "runtime-app-nostr-gm-smoke: env override Nostr DB path unexpectedly won",
                )
            if not config_log_path.exists():
                raise SystemExit(
                    "runtime-app-nostr-gm-smoke: session-config Nostr socket log was never created",
                )
            if env_log_path.exists():
                raise SystemExit(
                    "runtime-app-nostr-gm-smoke: env override Nostr socket unexpectedly won",
                )
        finally:
            assert process.stdin is not None
            process.stdin.close()
            stderr = process.stderr.read() if process.stderr is not None else ""
            return_code = process.wait(timeout=10)
            if return_code not in (0, None):
                raise SystemExit(f"runtime-app-nostr-gm-smoke: runtime host exited {return_code}\n{stderr}")

        print(json.dumps({
            "bundlePath": bundle_path,
            "dbPath": str(config_db_path),
            "relayUrl": relay.url,
            "result": "gm-ok",
            "sessionConfigPath": str(session_config_path),
            "socketPath": str(config_socket_path),
            "systemBinaryName": session["systemBinaryName"],
            "systemPackageAttr": session["systemPackageAttr"],
        }, indent=2))
PY
