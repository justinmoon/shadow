#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
relay_port="$(pixel_nostr_local_relay_port)"
relay_url="ws://127.0.0.1:${relay_port}"
run_dir="${PIXEL_RUNTIME_APP_RUN_DIR:-$(pixel_prepare_named_run_dir "$(pixel_runs_dir)/runtime-app-nostr-timeline-local")}"
session_run_dir="${PIXEL_GUEST_RUN_DIR:-$run_dir/pixel-drm}"
runtime_nostr_db_device_path="$(pixel_runtime_chroot_device_path "$(pixel_runtime_nostr_db_path)")"
mkdir -p "$run_dir"

runtime_app_config_json="$(
  RELAY_URL="$relay_url" python3 - <<'PY'
import json
import os

print(
    json.dumps(
        {
            "limit": 8,
            "relayUrls": [os.environ["RELAY_URL"]],
            "syncOnStart": True,
        }
    )
)
PY
)"

extra_forbidden_markers="${PIXEL_RUNTIME_APP_EXTRA_FORBIDDEN_MARKERS-}"
for marker in \
  "nostr.syncKind1 could not connect to any relay" \
  "nostr.publishEphemeralKind1 could not connect to any relay" \
  "nostr.publishEphemeralKind1 was rejected by every relay"
do
  if [[ -n "$extra_forbidden_markers" ]]; then
    extra_forbidden_markers="${extra_forbidden_markers}"$'\n'"${marker}"
  else
    extra_forbidden_markers="$marker"
  fi
done

prepend_guest_env_line() {
  local existing="${1-}"
  local line="$2"
  if [[ -n "$existing" ]]; then
    printf '%s\n%s' "$line" "$existing"
  else
    printf '%s' "$line"
  fi
}

append_required_marker() {
  local existing="${1-}"
  local marker="$2"
  if [[ -n "$existing" ]]; then
    printf '%s\n%s' "$existing" "$marker"
  else
    printf '%s' "$marker"
  fi
}

click_guest_env="$(prepend_guest_env_line "${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}" "SHADOW_BLITZ_RUNTIME_AUTO_CLICK_TARGET=quick-gm")"
click_required_markers="$(append_required_marker "${PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS-}" "runtime-event-dispatched source=auto type=click target=quick-gm")"

if [[ -n "${PIXEL_RUNTIME_APP_PREP_ONLY-}" || -n "${PIXEL_RUNTIME_APP_PREPARE_ONLY-}" || -n "${PIXEL_RUNTIME_APP_STAGE_ONLY-}" ]]; then
  PIXEL_SERIAL="$serial" \
  PIXEL_GUEST_RUN_DIR="$session_run_dir" \
  SHADOW_RUNTIME_APP_CONFIG_JSON="$runtime_app_config_json" \
  PIXEL_RUNTIME_APP_EXTRA_FORBIDDEN_MARKERS="$extra_forbidden_markers" \
  PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV="$click_guest_env" \
  PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS="$click_required_markers" \
  PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS="${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS:-12000}" \
  PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-45}" \
    "$SCRIPT_DIR/pixel_runtime_app_nostr_timeline_drm.sh"
  exit 0
fi

PIXEL_SERIAL="$serial" \
RUN_DIR="$run_dir" \
SESSION_RUN_DIR="$session_run_dir" \
RELAY_PORT="$relay_port" \
RELAY_URL="$relay_url" \
RUNTIME_APP_CONFIG_JSON="$runtime_app_config_json" \
PIXEL_RUNTIME_APP_EXTRA_FORBIDDEN_MARKERS="$extra_forbidden_markers" \
RUNTIME_NOSTR_DB_DEVICE_PATH="$runtime_nostr_db_device_path" \
REPO_ROOT="$REPO_ROOT" \
SCRIPT_DIR="$SCRIPT_DIR" \
python3 - <<'PY'
import json
import os
import socket
import sqlite3
import subprocess
import time
from pathlib import Path


REPO_ROOT = Path(os.environ["REPO_ROOT"])
SCRIPT_DIR = Path(os.environ["SCRIPT_DIR"])
SERIAL = os.environ["PIXEL_SERIAL"]
RUN_DIR = Path(os.environ["RUN_DIR"])
SESSION_RUN_DIR = Path(os.environ["SESSION_RUN_DIR"])
RELAY_PORT = int(os.environ["RELAY_PORT"])
RELAY_URL = os.environ["RELAY_URL"]
RUNTIME_APP_CONFIG_JSON = os.environ["RUNTIME_APP_CONFIG_JSON"]
EXTRA_FORBIDDEN_MARKERS = os.environ["PIXEL_RUNTIME_APP_EXTRA_FORBIDDEN_MARKERS"]
RUNTIME_NOSTR_DB_DEVICE_PATH = os.environ["RUNTIME_NOSTR_DB_DEVICE_PATH"]
SESSION_TIMEOUT = os.environ.get("PIXEL_GUEST_SESSION_TIMEOUT_SECS", "45")
EXIT_DELAY_MS = os.environ.get("PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS", "12000")
RUN_ONLY = bool(os.environ.get("PIXEL_RUNTIME_APP_RUN_ONLY"))
AUTO_CLICK_ENV = "SHADOW_BLITZ_RUNTIME_AUTO_CLICK_TARGET=quick-gm"
AUTO_CLICK_MARKER = "runtime-event-dispatched source=auto type=click target=quick-gm"

SEED_EVENTS_PATH = RUN_DIR / "relay-events.jsonl"
DB_COPY_PATH = RUN_DIR / "runtime-nostr.sqlite3"
RELAY_MESSAGES_PATH = RUN_DIR / "relay-messages.json"
SUMMARY_PATH = RUN_DIR / "summary.json"


def reserve_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def run(command, *, env=None, input_text=None, timeout=30):
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


def prepend_guest_env_line(existing: str | None, line: str) -> str:
    return f"{line}\n{existing}" if existing else line


def append_required_marker(existing: str | None, marker: str) -> str:
    return f"{existing}\n{marker}" if existing else marker


def adb(*args, timeout=30):
    return run(["adb", "-s", SERIAL, *args], timeout=timeout)


def query_relay_via_websocket(relay_url: str, *, timeout=10) -> str:
    script = f"""
const ws = new WebSocket({json.dumps(relay_url)});
const messages = [];
ws.onopen = () => ws.send(JSON.stringify(["REQ", "sub1", {{"kinds": [1], "limit": 20}}]));
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
    return run(["node", "-e", script], timeout=timeout).stdout.strip()


def wait_for_relay(relay: subprocess.Popen[str], name: str) -> None:
    assert relay.stderr is not None
    deadline = time.time() + 10
    stderr_lines: list[str] = []
    while time.time() < deadline:
        line = relay.stderr.readline()
        if line:
            stderr_lines.append(line)
            if "relay running at" in line:
                return
        elif relay.poll() is not None:
            break
        else:
            time.sleep(0.1)
    stderr = "".join(stderr_lines)
    if relay.stderr is not None:
        stderr += relay.stderr.read()
    raise SystemExit(
        f"pixel-runtime-app-nostr-timeline-local-smoke: timed out waiting for {name}\n{stderr}",
    )


def query_db_contents(db_path: Path) -> list[str]:
    connection = sqlite3.connect(db_path)
    try:
        rows = connection.execute(
            """
            SELECT content
            FROM nostr_kind1_events
            ORDER BY created_at DESC, sequence DESC
            """
        ).fetchall()
    finally:
        connection.close()
    return [row[0] for row in rows]


key_a = run(["nak", "key", "generate"], timeout=10).stdout.strip()
key_b = run(["nak", "key", "generate"], timeout=10).stdout.strip()
seed_port = reserve_port()
seed_relay_url = f"ws://127.0.0.1:{seed_port}"
seed_relay = subprocess.Popen(
    [
        "nak",
        "serve",
        "--hostname",
        "127.0.0.1",
        "--port",
        str(seed_port),
    ],
    cwd=REPO_ROOT,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)
relay = None
try:
    wait_for_relay(seed_relay, "temporary seed relay")
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
    SEED_EVENTS_PATH.write_text("\n".join(event_lines) + "\n", encoding="utf-8")
finally:
    seed_relay.terminate()
    try:
        seed_relay.wait(timeout=3)
    except subprocess.TimeoutExpired:
        seed_relay.kill()
        seed_relay.wait(timeout=3)

relay = subprocess.Popen(
    [
        "nak",
        "serve",
        "--hostname",
        "127.0.0.1",
        "--port",
        str(RELAY_PORT),
        "--events",
        str(SEED_EVENTS_PATH),
    ],
    cwd=REPO_ROOT,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)
try:
    wait_for_relay(relay, "seeded local relay")
    relay_dump = query_relay_via_websocket(RELAY_URL, timeout=10)
    RELAY_MESSAGES_PATH.write_text(relay_dump + "\n", encoding="utf-8")
    for fragment in ("relay smoke alpha", "relay smoke beta"):
        if fragment not in relay_dump:
            raise SystemExit(
                "pixel-runtime-app-nostr-timeline-local-smoke: seeded relay websocket query "
                f"missing note: {fragment}",
            )

    adb("reverse", f"tcp:{RELAY_PORT}", f"tcp:{RELAY_PORT}", timeout=10)
    try:
        env = os.environ.copy()
        env.update(
            {
                "PIXEL_SERIAL": SERIAL,
                "PIXEL_GUEST_RUN_DIR": str(SESSION_RUN_DIR),
                "SHADOW_RUNTIME_APP_CONFIG_JSON": RUNTIME_APP_CONFIG_JSON,
                "PIXEL_RUNTIME_APP_EXTRA_FORBIDDEN_MARKERS": EXTRA_FORBIDDEN_MARKERS,
                "PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV": prepend_guest_env_line(
                    env.get("PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV"),
                    AUTO_CLICK_ENV,
                ),
                "PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS": append_required_marker(
                    env.get("PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS"),
                    AUTO_CLICK_MARKER,
                ),
                "PIXEL_GUEST_SESSION_TIMEOUT_SECS": SESSION_TIMEOUT,
                "PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS": EXIT_DELAY_MS,
            }
        )
        if RUN_ONLY:
            env["PIXEL_RUNTIME_APP_RUN_ONLY"] = "1"
        run(
            [str(SCRIPT_DIR / "pixel_runtime_app_nostr_timeline_drm.sh")],
            env=env,
            timeout=600,
        )
    finally:
        subprocess.run(
            ["adb", "-s", SERIAL, "reverse", "--remove", f"tcp:{RELAY_PORT}"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    adb("pull", RUNTIME_NOSTR_DB_DEVICE_PATH, str(DB_COPY_PATH), timeout=20)
    db_contents = query_db_contents(DB_COPY_PATH)
    for fragment in ("relay smoke alpha", "relay smoke beta", "GM"):
        if fragment not in db_contents:
            raise SystemExit(
                "pixel-runtime-app-nostr-timeline-local-smoke: device db missing expected note: "
                f"{fragment}",
            )

    summary = {
        "dbCopyPath": str(DB_COPY_PATH),
        "relayPort": RELAY_PORT,
        "relayUrl": RELAY_URL,
        "result": "pixel-runtime-app-nostr-timeline-local-ok",
        "runDir": str(RUN_DIR),
        "serial": SERIAL,
        "sessionRunDir": str(SESSION_RUN_DIR),
        "deviceDbPath": RUNTIME_NOSTR_DB_DEVICE_PATH,
    }
    SUMMARY_PATH.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
finally:
    if relay is not None:
        relay.terminate()
        try:
            relay.wait(timeout=3)
        except subprocess.TimeoutExpired:
            relay.kill()
            relay.wait(timeout=3)
PY
