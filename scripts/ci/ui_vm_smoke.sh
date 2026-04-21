#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./ui_vm_common.sh
source "$SCRIPT_DIR/lib/ui_vm_common.sh"
# shellcheck source=./ci_vm_smoke_common.sh
source "$SCRIPT_DIR/lib/ci_vm_smoke_common.sh"
# shellcheck source=./session_apps.sh
source "$SCRIPT_DIR/lib/session_apps.sh"
LOG_DIR="$REPO_ROOT/build/ui-vm"
RUN_LOG="$LOG_DIR/ui-vm-smoke.log"
SHOT_PATH="$LOG_DIR/ui-vm-smoke.png"
HOME_SURFACE_SHOT_PATH="$LOG_DIR/ui-vm-home-surface.ppm"
VM_SOCKET_PATH="$REPO_ROOT/.shadow-vm/shadow-ui-vm.sock"
VM_STATE_IMAGE_PATH="$REPO_ROOT/.shadow-vm/shadow-ui-state.img"
RUNTIME_ARTIFACT_DIR="$(ui_vm_runtime_artifact_dir)"
RUNTIME_GUEST_DIR="$(ui_vm_runtime_guest_dir)"
UI_VM_PREP_TIMEOUT_SECS="${SHADOW_UI_VM_SMOKE_PREP_TIMEOUT:-900}"
# Fresh worktrees can trigger cold VM artifact preparation before the compositor
# is ready. Keep the required pre-merge smoke tolerant of that path.
UI_VM_READY_TIMEOUT_SECS="${SHADOW_UI_VM_SMOKE_READY_TIMEOUT:-1200}"
UI_VM_APP_TIMEOUT_SECS="${SHADOW_UI_VM_SMOKE_APP_TIMEOUT:-90}"
UI_VM_CONTROL_TIMEOUT_SECS="${SHADOW_UI_VM_SMOKE_CONTROL_TIMEOUT:-20}"
UI_VM_STOP_TIMEOUT_SECS="${SHADOW_UI_VM_SMOKE_STOP_TIMEOUT:-20}"
UI_VM_PROMPT_TIMEOUT_SECS="${SHADOW_UI_VM_SMOKE_PROMPT_TIMEOUT:-30}"
UI_VM_RELAY_TIMEOUT_SECS="${SHADOW_UI_VM_SMOKE_RELAY_TIMEOUT:-30}"
# Counter is the first launcher tile in the current shell-local home grid.
COUNTER_TILE_LOCAL_CENTER_X=104
COUNTER_TILE_LOCAL_CENTER_Y=617
RUST_TIMELINE_TOP_NOTE_LOCAL_CENTER_X=270
RUST_TIMELINE_TOP_NOTE_LOCAL_CENTER_Y=363
ui_vm_run_pid=""
prepared_inputs_path="${SHADOW_UI_VM_PREPARED_INPUTS:-}"
vm_smoke_succeeded=0
prompt_request_pid=""
prompt_request_response_path=""
relay_pid=""
relay_temp_dir=""
vm_extra_env_path=""
relay_host_port=""
relay_guest_url=""
relay_publish_secret=""
VM_OVERRIDE_ROOT="/tmp/shadow-vm-smoke-env-override"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prepared-inputs)
        prepared_inputs_path="${2:-}"
        shift 2
        ;;
      *)
        echo "vm-smoke: unsupported argument $1" >&2
        exit 1
        ;;
    esac
  done
}

parse_args "$@"
if [[ -z "$prepared_inputs_path" ]]; then
  prepared_inputs_path="$(vm_smoke_inputs_path "$REPO_ROOT")"
fi

run_with_timeout() {
  local timeout_secs="$1"
  shift

  COMMAND_TIMEOUT_SECS="$timeout_secs" python3 - "$@" <<'PY'
import os
import subprocess
import sys

timeout = float(os.environ["COMMAND_TIMEOUT_SECS"])
cmd = sys.argv[1:]

try:
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
except subprocess.TimeoutExpired:
    joined = " ".join(cmd)
    sys.stderr.write(
        f"vm-smoke: command timed out after {timeout:g}s: {joined}\n"
    )
    raise SystemExit(124)

sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
raise SystemExit(result.returncode)
PY
}

run_shadowctl() {
  run_with_timeout "$UI_VM_CONTROL_TIMEOUT_SECS" "$SCRIPT_DIR/shadowctl" "$@"
}

run_vm_stop() {
  run_with_timeout "$UI_VM_STOP_TIMEOUT_SECS" "$SCRIPT_DIR/vm/ui_vm_stop.sh"
}

reserve_local_port() {
  python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

wait_for_open_state() {
  local app_id="$1"
  local label="$2"
  local deadline=$((SECONDS + UI_VM_APP_TIMEOUT_SECS))
  local state_json=""
  local probe_status=0

  while true; do
    probe_status=0
    state_json="$(run_shadowctl state -t vm --json)" || probe_status=$?
    if (( probe_status != 0 )); then
      if (( SECONDS >= deadline )); then
        echo "vm-smoke: timed out waiting for ${label}" >&2
        echo "vm-smoke: state probe failed with status ${probe_status}" >&2
        return 1
      fi
      sleep 1
      continue
    fi
    if STATE_JSON="$state_json" APP_ID="$app_id" python3 - <<'PY'
import json
import os
import sys

state = json.loads(os.environ["STATE_JSON"])
app = os.environ["APP_ID"]
ok = (
    state.get("focused") == app
    and app in state.get("launched", [])
    and app in state.get("mapped", [])
    and app not in state.get("shelved", [])
)
sys.exit(0 if ok else 1)
PY
    then
      printf '%s\n' "$state_json"
      return 0
    fi

    if (( SECONDS >= deadline )); then
      echo "vm-smoke: timed out waiting for ${label}" >&2
      printf '%s\n' "$state_json" >&2
      return 1
    fi

    sleep 1
  done
}

wait_for_home_state() {
  local app_id="$1"
  local label="$2"
  local deadline=$((SECONDS + UI_VM_APP_TIMEOUT_SECS))
  local state_json=""
  local probe_status=0

  while true; do
    probe_status=0
    state_json="$(run_shadowctl state -t vm --json)" || probe_status=$?
    if (( probe_status != 0 )); then
      if (( SECONDS >= deadline )); then
        echo "vm-smoke: timed out waiting for ${label}" >&2
        echo "vm-smoke: state probe failed with status ${probe_status}" >&2
        return 1
      fi
      sleep 1
      continue
    fi
    if STATE_JSON="$state_json" APP_ID="$app_id" python3 - <<'PY'
import json
import os
import sys

state = json.loads(os.environ["STATE_JSON"])
app = os.environ["APP_ID"]
ok = (
    state.get("focused") in ("", None)
    and app in state.get("launched", [])
    and app not in state.get("mapped", [])
    and app in state.get("shelved", [])
)
sys.exit(0 if ok else 1)
PY
    then
      printf '%s\n' "$state_json"
      return 0
    fi

    if (( SECONDS >= deadline )); then
      echo "vm-smoke: timed out waiting for ${label}" >&2
      printf '%s\n' "$state_json" >&2
      return 1
    fi

    sleep 1
  done
}

wait_for_log_marker() {
  local marker="$1"
  local label="$2"
  local failure_marker="${3:-}"
  local deadline=$((SECONDS + UI_VM_APP_TIMEOUT_SECS))
  local logs=""

  while true; do
    if logs="$(run_shadowctl logs -t vm --lines 200)"; then
      if grep -Fq "$marker" <<<"$logs"; then
        return 0
      fi
      if [[ -n "$failure_marker" ]] && grep -Fq "$failure_marker" <<<"$logs"; then
        echo "vm-smoke: observed failure marker while waiting for ${label}" >&2
        printf '%s\n' "$logs" >&2
        return 1
      fi
    fi

    if (( SECONDS >= deadline )); then
      echo "vm-smoke: timed out waiting for ${label}" >&2
      if [[ -n "$logs" ]]; then
        printf '%s\n' "$logs" >&2
      fi
      return 1
    fi

    sleep 1
  done
}

wait_for_prompt_state() {
  local expected_active="$1"
  local label="$2"
  local deadline=$((SECONDS + UI_VM_PROMPT_TIMEOUT_SECS))
  local state_json=""
  local probe_status=0

  while true; do
    probe_status=0
    state_json="$(run_shadowctl state -t vm --json)" || probe_status=$?
    if (( probe_status != 0 )); then
      if (( SECONDS >= deadline )); then
        echo "vm-smoke: timed out waiting for ${label}" >&2
        echo "vm-smoke: state probe failed with status ${probe_status}" >&2
        return 1
      fi
      sleep 1
      continue
    fi
    if STATE_JSON="$state_json" EXPECTED_ACTIVE="$expected_active" python3 - <<'PY'
import json
import os
import sys

state = json.loads(os.environ["STATE_JSON"])
expected = os.environ["EXPECTED_ACTIVE"] == "1"
sys.exit(0 if state.get("prompt_active") is expected else 1)
PY
    then
      printf '%s\n' "$state_json"
      return 0
    fi

    if (( SECONDS >= deadline )); then
      echo "vm-smoke: timed out waiting for ${label}" >&2
      printf '%s\n' "$state_json" >&2
      return 1
    fi

    sleep 1
  done
}

wait_for_relay_ready() {
  local stderr_path="$1"
  local label="$2"
  local deadline=$((SECONDS + UI_VM_RELAY_TIMEOUT_SECS))

  while true; do
    if [[ -f "$stderr_path" ]] && grep -Fq "relay running at" "$stderr_path"; then
      return 0
    fi

    if (( SECONDS >= deadline )); then
      echo "vm-smoke: timed out waiting for ${label}" >&2
      if [[ -f "$stderr_path" ]]; then
        sed -n '1,120p' "$stderr_path" >&2 || true
      fi
      return 1
    fi

    sleep 1
  done
}

relay_query_dump() {
  local relay_url="$1"

  RELAY_URL="$relay_url" node - <<'JS'
const relayUrl = process.env.RELAY_URL;
if (!relayUrl) {
  throw new Error("missing RELAY_URL");
}
const ws = new WebSocket(relayUrl);
const messages = [];
ws.onopen = () => ws.send(JSON.stringify(["REQ", "sub1", { kinds: [1], limit: 50 }]));
ws.onmessage = (event) => {
  messages.push(String(event.data));
  if (String(event.data).includes('"EOSE"')) {
    console.log(JSON.stringify(messages));
    ws.close();
  }
};
ws.onclose = () => process.exit(0);
setTimeout(() => {
  console.log(JSON.stringify(messages));
  ws.close();
}, 2500);
JS
}

wait_for_relay_note() {
  local relay_url="$1"
  local needle="$2"
  local label="$3"
  local deadline=$((SECONDS + UI_VM_RELAY_TIMEOUT_SECS))
  local dump=""

  while true; do
    dump="$(relay_query_dump "$relay_url" 2>/dev/null || true)"
    if [[ "$dump" == *"$needle"* ]]; then
      return 0
    fi

    if (( SECONDS >= deadline )); then
      echo "vm-smoke: timed out waiting for ${label}" >&2
      if [[ -n "$dump" ]]; then
        printf '%s\n' "$dump" >&2
      fi
      return 1
    fi

    sleep 1
  done
}

wait_for_timeline_publish_result() {
  local preview="$1"
  local label="$2"

  wait_for_log_marker \
    "shadow-rust-timeline: publish_result=success preview=${preview}" \
    "$label" \
    "shadow-rust-timeline: publish_result=error preview=${preview}"
}

start_seeded_local_relay() {
  relay_temp_dir="$(mktemp -d "$LOG_DIR/vm-smoke-nostr.XXXXXX")"
  relay_host_port="$(reserve_local_port)"
  relay_guest_url="ws://10.0.2.2:${relay_host_port}"
  relay_publish_secret="$(nak key generate)"
  local key_a key_b seed_port seed_url seed_err seed_out relay_err relay_out events_path
  local event_a event_b

  key_a="$(nak key generate)"
  key_b="$(nak key generate)"
  seed_port="$(reserve_local_port)"
  seed_url="ws://127.0.0.1:${seed_port}"
  seed_err="$relay_temp_dir/seed-relay.err"
  seed_out="$relay_temp_dir/seed-relay.out"
  relay_err="$relay_temp_dir/relay.err"
  relay_out="$relay_temp_dir/relay.out"
  events_path="$relay_temp_dir/relay-events.jsonl"

  nak serve --hostname 127.0.0.1 --port "$seed_port" >"$seed_out" 2>"$seed_err" &
  local seed_pid=$!
  wait_for_relay_ready "$seed_err" "seed relay"

  event_a="$(printf 'vm smoke seed alpha\n' | nak publish --sec "$key_a" "$seed_url")"
  event_b="$(printf 'vm smoke seed beta\n' | nak publish --sec "$key_b" "$seed_url")"
  relay_query_dump "$seed_url" >/dev/null
  printf '%s\n%s\n' "$event_a" "$event_b" >"$events_path"

  kill "$seed_pid" >/dev/null 2>&1 || true
  wait "$seed_pid" 2>/dev/null || true

  nak serve --hostname 0.0.0.0 --port "$relay_host_port" --events "$events_path" >"$relay_out" 2>"$relay_err" &
  relay_pid=$!
  wait_for_relay_ready "$relay_err" "vm relay"
  wait_for_relay_note "ws://127.0.0.1:${relay_host_port}" "vm smoke seed alpha" "seed note alpha on vm relay"
  wait_for_relay_note "ws://127.0.0.1:${relay_host_port}" "vm smoke seed beta" "seed note beta on vm relay"
}

prepare_vm_extra_env() {
  vm_extra_env_path="$(mktemp "$LOG_DIR/vm-extra-env.XXXXXX.sh")"
  {
    printf 'export SHADOW_RUNTIME_NOSTR_DB_PATH=%q\n' "$VM_OVERRIDE_ROOT/runtime-nostr.sqlite3"
    printf 'export SHADOW_RUNTIME_NOSTR_SERVICE_SOCKET=%q\n' "$VM_OVERRIDE_ROOT/runtime-nostr.sock"
    printf 'export SHADOW_RUNTIME_CASHU_DATA_DIR=%q\n' "$VM_OVERRIDE_ROOT/runtime-cashu"
    printf 'export SHADOW_RUNTIME_NOSTR_ACCOUNT_NSEC=%q\n' "$relay_publish_secret"
    printf 'export SHADOW_RUST_TIMELINE_RELAY_URLS=%q\n' "$relay_guest_url"
    printf 'export SHADOW_RUST_TIMELINE_SYNC_ON_START=%q\n' "1"
    printf 'export SHADOW_RUST_TIMELINE_LIMIT=%q\n' "8"
  } >"$vm_extra_env_path"
}

assert_guest_tcp_connectivity() {
  local host="$1"
  local port="$2"

  ui_vm_ssh python3 - "$host" "$port" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
with socket.create_connection((host, port), timeout=5):
    pass
PY
}

start_synthetic_system_prompt() {
  prompt_request_response_path="$(mktemp "$LOG_DIR/system-prompt-response.XXXXXX")"
  ui_vm_ssh python3 - >"$prompt_request_response_path" 2>>"$RUN_LOG" <<'PY' &
import json
import os
import socket
from pathlib import Path

runtime_dir = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}")
socket_path = runtime_dir / "shadow-system-prompt.sock"
payload = {
    "sourceAppId": "vm-smoke",
    "sourceAppTitle": "VM Smoke",
    "title": "Allow publish?",
    "message": "Synthetic system prompt request for VM smoke.",
    "detailLines": ["Account: npub1vmtest", "Preview: smoke prompt"],
    "actions": [
        {"id": "deny", "label": "Deny", "style": "danger"},
        {"id": "allow_once", "label": "Allow Once", "style": "default"},
        {"id": "allow_always", "label": "Always Allow", "style": "normal"},
    ],
}
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.connect(str(socket_path))
    client.sendall((json.dumps(payload) + "\n").encode("utf-8"))
    client.shutdown(socket.SHUT_WR)
    chunks = []
    while True:
        chunk = client.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)
print(b"".join(chunks).decode("utf-8"), end="")
PY
  prompt_request_pid=$!
}

finish_synthetic_system_prompt() {
  if [[ -z "$prompt_request_pid" || -z "$prompt_request_response_path" ]]; then
    return 0
  fi

  wait "$prompt_request_pid"
  RESPONSE_PATH="$prompt_request_response_path" python3 - <<'PY'
import json
import os
from pathlib import Path

response = Path(os.environ["RESPONSE_PATH"]).read_text(encoding="utf-8").strip()
if not response:
    raise SystemExit("vm-smoke: synthetic system prompt request returned an empty response")
payload = json.loads(response)
if payload.get("status") != "ok":
    raise SystemExit(f"vm-smoke: synthetic system prompt returned {payload!r}")
action_id = payload.get("payload", {}).get("actionId")
if action_id != "allow_once":
    raise SystemExit(
        f"vm-smoke: synthetic system prompt resolved unexpected action {action_id!r}"
    )
PY
  rm -f "$prompt_request_response_path"
  prompt_request_pid=""
  prompt_request_response_path=""
}

run_app_platform_request_checked() {
  local app_id="$1"
  shift
  local request="$*"
  local request_b64=""
  local response=""

  request_b64="$(printf '%s' "$request" | base64 | tr -d '\n')"

  response="$(
    ui_vm_ssh python3 - "$app_id" "$request_b64" <<'PY'
import base64
import os
import sys
import socket
from pathlib import Path

app_id = sys.argv[1]
request_line = base64.b64decode(sys.argv[2]).decode("utf-8")
runtime_dir = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}")
socket_path = runtime_dir / f"shadow-{app_id}-platform.sock"
payload = request_line.encode("utf-8") + b"\n"

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
    client.connect(str(socket_path))
    client.sendall(payload)
    client.shutdown(socket.SHUT_WR)
    chunks = []
    while True:
        chunk = client.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)

print(b"".join(chunks).decode("utf-8"), end="")
PY
  )"

  RESPONSE_TEXT="$response" REQUEST_LINE="$request" python3 - <<'PY'
import os

fields = {}
for line in os.environ["RESPONSE_TEXT"].splitlines():
    if "=" in line:
        key, value = line.split("=", 1)
        fields[key] = value

if fields.get("handled") != "1":
    raise SystemExit(
        "vm-smoke: app platform request was not handled "
        f"for {os.environ['REQUEST_LINE']!r}: {os.environ['RESPONSE_TEXT']!r}"
    )
PY

  printf '%s\n' "$response"
}

counter_launcher_tap() {
  local shell_state
  local tap_coords

  shell_state="$(run_shadowctl state -t vm --json)"
  tap_coords="$(
    COUNTER_TILE_LOCAL_CENTER_X="$COUNTER_TILE_LOCAL_CENTER_X" \
      COUNTER_TILE_LOCAL_CENTER_Y="$COUNTER_TILE_LOCAL_CENTER_Y" \
      python3 -c '
import json
import os
import sys

state = json.load(sys.stdin)
shell_x = state.get("shell_x")
shell_y = state.get("shell_y")
if shell_x is None or shell_y is None:
    raise SystemExit("vm-smoke: missing shell geometry in shadowctl state -t vm --json")
counter_tile_local_center_x = int(os.environ["COUNTER_TILE_LOCAL_CENTER_X"])
counter_tile_local_center_y = int(os.environ["COUNTER_TILE_LOCAL_CENTER_Y"])
print(f"{shell_x + counter_tile_local_center_x} {shell_y + counter_tile_local_center_y}")
      ' <<<"$shell_state"
  )"

  local tap_x
  local tap_y
  read -r tap_x tap_y <<<"$tap_coords"
  run_shadowctl tap -t vm "$tap_x" "$tap_y" >/dev/null
}

rust_timeline_top_note_tap() {
  local shell_state
  local tap_coords

  shell_state="$(run_shadowctl state -t vm --json)"
  tap_coords="$(
    RUST_TIMELINE_TOP_NOTE_LOCAL_CENTER_X="$RUST_TIMELINE_TOP_NOTE_LOCAL_CENTER_X" \
      RUST_TIMELINE_TOP_NOTE_LOCAL_CENTER_Y="$RUST_TIMELINE_TOP_NOTE_LOCAL_CENTER_Y" \
      python3 -c '
import json
import os
import sys

state = json.load(sys.stdin)
shell_x = state.get("shell_x")
shell_y = state.get("shell_y")
if shell_x is None or shell_y is None:
    raise SystemExit("vm-smoke: missing shell geometry in shadowctl state -t vm --json")
note_local_x = int(os.environ["RUST_TIMELINE_TOP_NOTE_LOCAL_CENTER_X"])
note_local_y = int(os.environ["RUST_TIMELINE_TOP_NOTE_LOCAL_CENTER_Y"])
print(f"{shell_x + note_local_x} {shell_y + note_local_y}")
      ' <<<"$shell_state"
  )"

  local tap_x
  local tap_y
  read -r tap_x tap_y <<<"$tap_coords"
  run_shadowctl tap -t vm "$tap_x" "$tap_y" >/dev/null
}

assert_home_surface_visible() {
  local shell_state

  shell_state="$(run_shadowctl state -t vm --json)"
  run_shadowctl screenshot -t vm "$HOME_SURFACE_SHOT_PATH" >/dev/null
  STATE_JSON="$shell_state" HOME_SURFACE_SHOT_PATH="$HOME_SURFACE_SHOT_PATH" python3 - <<'PY'
import json
import os
from pathlib import Path

state = json.loads(os.environ["STATE_JSON"])
shell_x = state.get("shell_x")
shell_y = state.get("shell_y")
if shell_x is None or shell_y is None:
    raise SystemExit("vm-smoke: missing shell geometry for home-surface assertion")

payload = Path(os.environ["HOME_SURFACE_SHOT_PATH"]).read_bytes()
if not payload.startswith(b"P6\n"):
    raise SystemExit("vm-smoke: expected QMP screendump P6 frame")

rest = payload[3:]
header = []
index = 0
while len(header) < 3:
    while rest[index:index + 1] in b" \n\r\t":
        index += 1
    start = index
    while rest[index:index + 1] not in b" \n\r\t":
        index += 1
    header.append(rest[start:index])
while rest[index:index + 1] in b" \n\r\t":
    index += 1
width, height, max_value = map(int, header)
if max_value != 255:
    raise SystemExit(f"vm-smoke: unsupported PPM max value {max_value}")
pixels = memoryview(rest[index:])

def pixel(x: int, y: int) -> tuple[int, int, int]:
    offset = (y * width + x) * 3
    return tuple(pixels[offset:offset + 3])

background = pixel(shell_x + 10, shell_y + 10)
samples = {
    "top_strip": pixel(shell_x + 270, shell_y + 25),
    "clock_card": pixel(shell_x + 120, shell_y + 160),
    "app_panel": pixel(shell_x + 270, shell_y + 520),
    "bottom_pill": pixel(shell_x + 270, shell_y + 1113),
}
required = ("top_strip", "app_panel", "bottom_pill")
missing = {name: samples[name] for name in required if samples[name] == background}
if missing:
    raise SystemExit(
        "vm-smoke: home surface screenshot is missing expected launcher/chrome surfaces "
        f"(background={background}, missing={missing}, samples={samples})"
    )
PY
}

dump_failure_context() {
  if [[ -f "$RUN_LOG" ]]; then
    printf '\n== vm-smoke run log ==\n' >&2
    sed -n '1,240p' "$RUN_LOG" >&2 || true
  fi

  printf '\n== vm doctor ==\n' >&2
  run_shadowctl doctor -t vm >&2 || true

  printf '\n== vm logs ==\n' >&2
  run_shadowctl logs -t vm --lines 200 >&2 || true

  printf '\n== vm journal ==\n' >&2
  run_shadowctl journal -t vm --lines 120 >&2 || true
}

finish() {
  local status="$1"

  if (( status != 0 )); then
    run_shadowctl screenshot -t vm "$SHOT_PATH" >/dev/null 2>&1 || true
    dump_failure_context
  fi

  run_vm_stop >/dev/null 2>&1 || true
  if [[ -n "$relay_pid" ]] && kill -0 "$relay_pid" >/dev/null 2>&1; then
    kill "$relay_pid" >/dev/null 2>&1 || true
    wait "$relay_pid" 2>/dev/null || true
  fi
  if [[ -n "$prompt_request_pid" ]] && kill -0 "$prompt_request_pid" >/dev/null 2>&1; then
    kill "$prompt_request_pid" >/dev/null 2>&1 || true
    wait "$prompt_request_pid" 2>/dev/null || true
  fi
  if [[ -n "$prompt_request_response_path" ]]; then
    rm -f "$prompt_request_response_path" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ui_vm_run_pid" ]]; then
    if kill -0 "$ui_vm_run_pid" >/dev/null 2>&1; then
      local deadline=$((SECONDS + UI_VM_STOP_TIMEOUT_SECS))
      kill "$ui_vm_run_pid" >/dev/null 2>&1 || true
      while kill -0 "$ui_vm_run_pid" >/dev/null 2>&1; do
        if (( SECONDS >= deadline )); then
          kill -9 "$ui_vm_run_pid" >/dev/null 2>&1 || true
          break
        fi
        sleep 1
      done
    fi
    wait "$ui_vm_run_pid" 2>/dev/null || true
  fi
  if [[ -n "$vm_extra_env_path" ]]; then
    rm -f "$vm_extra_env_path" >/dev/null 2>&1 || true
  fi
  if [[ -n "$relay_temp_dir" ]]; then
    rm -rf "$relay_temp_dir" >/dev/null 2>&1 || true
  fi

  if (( status == 0 && vm_smoke_succeeded == 1 )); then
    vm_smoke_record_success "$prepared_inputs_path" "$REPO_ROOT"
  fi
}

trap 'status=$?; finish "$status"; exit "$status"' EXIT

mkdir -p "$LOG_DIR"
: >"$RUN_LOG"
start_seeded_local_relay
prepare_vm_extra_env
run_vm_stop >/dev/null 2>&1 || true
# The branch gate should prove a clean boot/session lifecycle, not inherit
# whichever apps happened to be warm in the previous VM run.
rm -f "$VM_STATE_IMAGE_PATH"

(
  cd "$REPO_ROOT"
  SHADOW_RUNTIME_AUDIO_BACKEND=memory \
    SHADOW_UI_VM_EXTRA_ENV_PATH="$vm_extra_env_path" \
    "$SCRIPT_DIR/vm/ui_vm_run.sh" --prepared-inputs "$prepared_inputs_path"
) >"$RUN_LOG" 2>&1 &
ui_vm_run_pid=$!

prep_start="$(date +%s)"
while true; do
  if [[ -S "$VM_SOCKET_PATH" ]]; then
    break
  fi

  if ! kill -0 "$ui_vm_run_pid" 2>/dev/null; then
    echo "vm-smoke: VM runner exited before the VM started" >&2
    wait "$ui_vm_run_pid"
    exit 1
  fi

  prep_now="$(date +%s)"
  if (( prep_now - prep_start > UI_VM_PREP_TIMEOUT_SECS )); then
    echo "vm-smoke: timed out waiting for VM bootstrap" >&2
    exit 1
  fi

  sleep 1
done

"$SCRIPT_DIR/shadowctl" wait-ready -t vm --timeout "$UI_VM_READY_TIMEOUT_SECS"
assert_guest_tcp_connectivity "10.0.2.2" "$relay_host_port"

doctor_json="$("$SCRIPT_DIR/shadowctl" doctor -t vm --json)"
shadow_load_typescript_runtime_apps "vm-shell"
expected_runtime_app_ids="$(IFS=,; printf '%s' "${shadow_session_apps[*]}")"
REPO_ROOT="$REPO_ROOT" \
EXPECTED_ARTIFACT_SHARE="$RUNTIME_ARTIFACT_DIR" \
EXPECTED_ARTIFACT_GUEST_ROOT="$RUNTIME_GUEST_DIR" \
EXPECTED_RUNTIME_APP_IDS="$expected_runtime_app_ids" \
DOCTOR_JSON="$doctor_json" \
python3 - <<'PY'
import json
import os
from pathlib import Path

payload = json.loads(os.environ["DOCTOR_JSON"])
issues = payload.get("issues", [])
status = payload["status"]
artifact_share = status["local"].get("artifact_share")
expected = Path(os.environ["EXPECTED_ARTIFACT_SHARE"]).resolve()
expected_guest_root = os.environ["EXPECTED_ARTIFACT_GUEST_ROOT"]
repo_root = Path(os.environ["REPO_ROOT"]).resolve()

if issues:
    raise SystemExit(f"vm-smoke: doctor reported issues: {issues!r}")
if artifact_share is None:
    raise SystemExit(
        f"vm-smoke: expected artifact share {str(expected)!r}, got {artifact_share!r}"
    )
artifact_share_path = Path(artifact_share)
if not artifact_share_path.is_absolute():
    artifact_share_path = (repo_root / artifact_share_path).resolve()
if artifact_share_path != expected:
    raise SystemExit(
        f"vm-smoke: expected artifact share {str(expected)!r}, got {artifact_share!r}"
    )

manifest_path = expected / "artifact-manifest.json"
if not manifest_path.is_file():
    raise SystemExit(f"vm-smoke: missing runtime artifact manifest {manifest_path}")
session_config_path = expected / "session-config.json"
if not session_config_path.is_file():
    raise SystemExit(f"vm-smoke: missing runtime session config {session_config_path}")

with manifest_path.open("r", encoding="utf-8") as handle:
    manifest = json.load(handle)
with session_config_path.open("r", encoding="utf-8") as handle:
    session_config = json.load(handle)

if manifest.get("schemaVersion") != 1:
    raise SystemExit("vm-smoke: runtime artifact manifest schemaVersion must be 1")
if manifest.get("profile") != "vm-shell":
    raise SystemExit(
        f"vm-smoke: runtime artifact manifest profile must be vm-shell, got {manifest.get('profile')!r}"
    )
if manifest.get("artifactGuestRoot") != expected_guest_root:
    raise SystemExit(
        f"vm-smoke: runtime artifact manifest guest root must be {expected_guest_root!r}"
    )

if session_config.get("schemaVersion") != 1:
    raise SystemExit("vm-smoke: runtime session config schemaVersion must be 1")
if session_config.get("profile") != "vm-shell":
    raise SystemExit(
        f"vm-smoke: runtime session config profile must be vm-shell, got {session_config.get('profile')!r}"
    )
if session_config.get("stateDir") != manifest.get("stateDir"):
    raise SystemExit("vm-smoke: runtime session config stateDir mismatch")

artifacts = session_config.get("artifacts")
if not isinstance(artifacts, dict):
    raise SystemExit("vm-smoke: runtime session config artifacts must be an object")
if artifacts.get("guestRoot") != expected_guest_root:
    raise SystemExit(
        f"vm-smoke: runtime session config guest root must be {expected_guest_root!r}"
    )
if artifacts.get("root") != str(expected):
    raise SystemExit("vm-smoke: runtime session config artifact root mismatch")

system = session_config.get("system")
if not isinstance(system, dict):
    raise SystemExit("vm-smoke: runtime session config system must be an object")
if system.get("binaryPath") != manifest.get("systemBinaryPath"):
    raise SystemExit("vm-smoke: runtime session config system binary path mismatch")
if system.get("packageAttr") != manifest.get("systemPackageAttr"):
    raise SystemExit("vm-smoke: runtime session config system package attr mismatch")

services = session_config.get("services")
if not isinstance(services, dict):
    raise SystemExit("vm-smoke: runtime session config services must be an object")
state_dir = Path(session_config["stateDir"])
if services.get("cashuDataDir") != str(state_dir / "runtime-cashu"):
    raise SystemExit("vm-smoke: runtime session config cashu dir mismatch")
if services.get("nostrDbPath") != str(state_dir / "runtime-nostr.sqlite3"):
    raise SystemExit("vm-smoke: runtime session config nostr db path mismatch")
if services.get("nostrServiceSocket") != str(state_dir / "runtime-nostr.sock"):
    raise SystemExit("vm-smoke: runtime session config nostr socket mismatch")

apps = manifest.get("apps")
if not isinstance(apps, dict):
    raise SystemExit("vm-smoke: runtime artifact manifest apps must be an object")

expected_apps = {
    app_id
    for app_id in os.environ["EXPECTED_RUNTIME_APP_IDS"].split(",")
    if app_id
}
actual_apps = set(apps)
if actual_apps != expected_apps:
    missing = sorted(expected_apps - actual_apps)
    extra = sorted(actual_apps - expected_apps)
    details = []
    if missing:
        details.append("missing=" + ",".join(missing))
    if extra:
        details.append("extra=" + ",".join(extra))
    raise SystemExit(
        "vm-smoke: runtime artifact manifest app set mismatch: "
        + " ".join(details)
    )

runtime = session_config.get("runtime")
if not isinstance(runtime, dict):
    raise SystemExit("vm-smoke: runtime session config runtime must be an object")
runtime_apps = runtime.get("apps")
if not isinstance(runtime_apps, dict):
    raise SystemExit("vm-smoke: runtime session config runtime.apps must be an object")
if set(runtime_apps) != expected_apps:
    raise SystemExit("vm-smoke: runtime session config app set mismatch")
expected_default_app_id = "counter" if "counter" in expected_apps else next(iter(apps), None)
expected_default_bundle_path = (
    apps[expected_default_app_id]["guestBundlePath"]
    if expected_default_app_id is not None
    else None
)
if runtime.get("defaultAppId") != expected_default_app_id:
    raise SystemExit("vm-smoke: runtime session config default app mismatch")
if runtime.get("defaultBundlePath") != expected_default_bundle_path:
    raise SystemExit("vm-smoke: runtime session config default bundle mismatch")
for app_id in sorted(expected_apps):
    runtime_app = runtime_apps[app_id]
    manifest_app = apps[app_id]
    if runtime_app.get("bundleEnv") != manifest_app.get("bundleEnv"):
        raise SystemExit(f"vm-smoke: runtime session config bundle env mismatch for {app_id}")
    if runtime_app.get("bundlePath") != manifest_app.get("guestBundlePath"):
        raise SystemExit(f"vm-smoke: runtime session config bundle path mismatch for {app_id}")
    if runtime_app.get("config") != manifest_app.get("runtimeAppConfig"):
        raise SystemExit(f"vm-smoke: runtime session config runtime config mismatch for {app_id}")

for app_id in sorted(expected_apps):
    app = apps[app_id]
    effective_bundle = app.get("effectiveBundlePath")
    guest_bundle = app.get("guestBundlePath")
    expected_guest_bundle = f"{expected_guest_root}/apps/{app_id}/bundle.js"
    if guest_bundle != expected_guest_bundle:
        raise SystemExit(
            f"vm-smoke: app {app_id} guest bundle {guest_bundle!r} != {expected_guest_bundle!r}"
        )
    if not isinstance(effective_bundle, str) or not effective_bundle:
        raise SystemExit(f"vm-smoke: app {app_id} missing effectiveBundlePath")
    effective_bundle_path = Path(effective_bundle)
    if not effective_bundle_path.is_absolute():
        effective_bundle_path = (repo_root / effective_bundle_path).resolve()
    try:
        effective_bundle_path.relative_to(expected)
    except ValueError as error:
        raise SystemExit(
            f"vm-smoke: app {app_id} host bundle is outside artifact share: {effective_bundle}"
        ) from error
    if not effective_bundle_path.is_file():
        raise SystemExit(
            f"vm-smoke: app {app_id} host bundle does not exist: {effective_bundle_path}"
        )
PY

session_env_text="$(run_shadowctl ssh -t vm -- cat /var/lib/shadow-ui/shadow-ui-session-env.sh)"
if [[ "$session_env_text" != *'export SHADOW_RUNTIME_SESSION_CONFIG="/opt/shadow-runtime/session-config.json"'* ]]; then
  echo "vm-smoke: session env missing SHADOW_RUNTIME_SESSION_CONFIG export" >&2
  exit 1
fi
if [[ "$session_env_text" != *"export SHADOW_RUNTIME_NOSTR_DB_PATH=\"$VM_OVERRIDE_ROOT/runtime-nostr.sqlite3\""* ]]; then
  echo "vm-smoke: session env missing overridden SHADOW_RUNTIME_NOSTR_DB_PATH export" >&2
  exit 1
fi
if [[ "$session_env_text" != *"export SHADOW_RUNTIME_NOSTR_SERVICE_SOCKET=\"$VM_OVERRIDE_ROOT/runtime-nostr.sock\""* ]]; then
  echo "vm-smoke: session env missing overridden SHADOW_RUNTIME_NOSTR_SERVICE_SOCKET export" >&2
  exit 1
fi
if [[ "$session_env_text" != *"export SHADOW_RUNTIME_CASHU_DATA_DIR=\"$VM_OVERRIDE_ROOT/runtime-cashu\""* ]]; then
  echo "vm-smoke: session env missing overridden SHADOW_RUNTIME_CASHU_DATA_DIR export" >&2
  exit 1
fi

echo "vm-smoke: tap counter launcher tile"
counter_launcher_tap
state_after_counter_open="$(wait_for_open_state counter "counter open")"
wait_for_log_marker \
  "[shadow-runtime-counter] window_metrics surface=540x1042 safe_area=l0 t0 r0 b0" \
  "counter window metrics"

echo "vm-smoke: home counter"
run_shadowctl home -t vm >/dev/null
state_after_counter_home="$(wait_for_home_state counter "counter home")"
assert_home_surface_visible
wait_for_log_marker \
  "[shadow-runtime-counter] lifecycle_state=background" \
  "counter lifecycle background"

echo "vm-smoke: reopen counter"
counter_launcher_tap
state_after_counter_reopen="$(wait_for_open_state counter "counter reopen")"
wait_for_log_marker \
  "[shadow-runtime-counter] lifecycle_state=foreground" \
  "counter lifecycle foreground"

echo "vm-smoke: home counter again"
run_shadowctl home -t vm >/dev/null
wait_for_home_state counter "counter second home" >/dev/null

echo "vm-smoke: open timeline"
run_shadowctl open timeline -t vm >/dev/null
state_after_timeline_open="$(wait_for_open_state timeline "timeline open")"

echo "vm-smoke: home timeline"
run_shadowctl home -t vm >/dev/null
state_after_timeline_home="$(wait_for_home_state timeline "timeline home")"

echo "vm-smoke: reopen timeline"
run_shadowctl open timeline -t vm >/dev/null
state_after_timeline_reopen="$(wait_for_open_state timeline "timeline reopen")"

echo "vm-smoke: home timeline again"
run_shadowctl home -t vm >/dev/null
wait_for_home_state timeline "timeline second home" >/dev/null

echo "vm-smoke: open cashu"
run_shadowctl open cashu -t vm >/dev/null
state_after_cashu_open="$(wait_for_open_state cashu "cashu open")"

echo "vm-smoke: home cashu"
run_shadowctl home -t vm >/dev/null
state_after_cashu_home="$(wait_for_home_state cashu "cashu home")"

echo "vm-smoke: reopen cashu"
run_shadowctl open cashu -t vm >/dev/null
state_after_cashu_reopen="$(wait_for_open_state cashu "cashu reopen")"

echo "vm-smoke: home cashu again"
run_shadowctl home -t vm >/dev/null
wait_for_home_state cashu "cashu second home" >/dev/null

echo "vm-smoke: open camera"
run_shadowctl open camera -t vm >/dev/null
state_after_camera_open="$(wait_for_open_state camera "camera open")"

echo "vm-smoke: home camera"
run_shadowctl home -t vm >/dev/null
state_after_camera_home="$(wait_for_home_state camera "camera home")"

echo "vm-smoke: open rust-demo"
"$SCRIPT_DIR/shadowctl" open rust-demo -t vm >/dev/null
state_after_rust_demo_open="$(wait_for_open_state rust-demo "rust-demo open")"
wait_for_log_marker \
  "shadow-rust-demo: window_metrics surface=540x1042 safe_area=l0 t0 r0 b0" \
  "rust-demo window metrics"
wait_for_log_marker \
  "shadow-rust-demo: camera_probe=ok" \
  "rust-demo camera probe" \
  "shadow-rust-demo: camera_probe=error"

echo "vm-smoke: home rust-demo"
"$SCRIPT_DIR/shadowctl" home -t vm >/dev/null
state_after_rust_demo_home="$(wait_for_home_state rust-demo "rust-demo home")"
wait_for_log_marker \
  "shadow-rust-demo: lifecycle_state=background" \
  "rust-demo lifecycle background"

echo "vm-smoke: reopen rust-demo"
"$SCRIPT_DIR/shadowctl" open rust-demo -t vm >/dev/null
state_after_rust_demo_reopen="$(wait_for_open_state rust-demo "rust-demo reopen")"
wait_for_log_marker \
  "shadow-rust-demo: lifecycle_state=foreground" \
  "rust-demo lifecycle foreground"

echo "vm-smoke: home rust-demo again"
"$SCRIPT_DIR/shadowctl" home -t vm >/dev/null
wait_for_home_state rust-demo "rust-demo second home" >/dev/null

echo "vm-smoke: open rust-timeline"
"$SCRIPT_DIR/shadowctl" open rust-timeline -t vm >/dev/null
state_after_rust_timeline_open="$(wait_for_open_state rust-timeline "rust-timeline open")"
wait_for_log_marker \
  "shadow-rust-timeline: window_metrics surface=540x1042 safe_area=l0 t0 r0 b0" \
  "rust-timeline window metrics"
wait_for_log_marker \
  "shadow-rust-timeline: lifecycle_state=foreground" \
  "rust-timeline lifecycle foreground"

echo "vm-smoke: home rust-timeline"
"$SCRIPT_DIR/shadowctl" home -t vm >/dev/null
state_after_rust_timeline_home="$(wait_for_home_state rust-timeline "rust-timeline home")"
wait_for_log_marker \
  "shadow-rust-timeline: lifecycle_state=background" \
  "rust-timeline lifecycle background"

echo "vm-smoke: reopen rust-timeline"
"$SCRIPT_DIR/shadowctl" open rust-timeline -t vm >/dev/null
state_after_rust_timeline_reopen="$(wait_for_open_state rust-timeline "rust-timeline reopen")"
wait_for_log_marker \
  "shadow-rust-timeline: lifecycle_state=foreground" \
  "rust-timeline lifecycle foreground again"

echo "vm-smoke: open rust-timeline seeded note"
rust_timeline_top_note_tap

echo "vm-smoke: rust-timeline publish with allow_always"
run_app_platform_request_checked rust-timeline automation open_reply >/dev/null
run_app_platform_request_checked \
  rust-timeline \
  automation set_reply_content "vm smoke reply allow always" >/dev/null
run_app_platform_request_checked rust-timeline automation publish_reply >/dev/null
rust_timeline_prompt_open_state="$(wait_for_prompt_state 1 "rust-timeline signer prompt open")"
PROMPT_OPEN_STATE="$rust_timeline_prompt_open_state" python3 - <<'PY'
import json
import os

state = json.loads(os.environ["PROMPT_OPEN_STATE"])
if state.get("prompt_source_app_id") != "rust-timeline":
    raise SystemExit(
        "vm-smoke: expected rust-timeline signer prompt source app id, "
        f"got {state.get('prompt_source_app_id')!r}"
    )
actions = state.get("prompt_actions") or []
if actions != ["deny", "allow_once", "allow_always"]:
    raise SystemExit(f"vm-smoke: unexpected rust-timeline prompt actions {actions!r}")
PY
run_shadowctl prompt -t vm allow_always >/dev/null
wait_for_prompt_state 0 "rust-timeline signer prompt close" >/dev/null
wait_for_timeline_publish_result \
  "vm smoke reply allow always" \
  "rust-timeline publish completion after allow_always"
wait_for_relay_note \
  "ws://127.0.0.1:${relay_host_port}" \
  "vm smoke reply allow always" \
  "rust-timeline published reply after allow_always"

echo "vm-smoke: rust-timeline publish with cached signer policy"
run_app_platform_request_checked rust-timeline automation open_reply >/dev/null
run_app_platform_request_checked \
  rust-timeline \
  automation set_reply_content "vm smoke reply cached policy" >/dev/null
run_app_platform_request_checked rust-timeline automation publish_reply >/dev/null
sleep 2
prompt_after_cached_publish="$(run_shadowctl state -t vm --json)"
PROMPT_CLOSED_STATE="$prompt_after_cached_publish" python3 - <<'PY'
import json
import os

state = json.loads(os.environ["PROMPT_CLOSED_STATE"])
if state.get("prompt_active"):
    raise SystemExit("vm-smoke: signer prompt should stay inactive after allow_always policy")
PY
wait_for_timeline_publish_result \
  "vm smoke reply cached policy" \
  "rust-timeline publish completion after cached-policy approval"
wait_for_relay_note \
  "ws://127.0.0.1:${relay_host_port}" \
  "vm smoke reply cached policy" \
  "rust-timeline published cached-policy reply"

ui_vm_ssh python3 - "$VM_OVERRIDE_ROOT" <<'PY'
import json
import stat
import sys
from pathlib import Path

override_root = Path(sys.argv[1])
config_path = Path("/opt/shadow-runtime/session-config.json")
with config_path.open("r", encoding="utf-8") as handle:
    config = json.load(handle)

services = config.get("services")
if not isinstance(services, dict):
    raise SystemExit("vm-smoke: runtime session config services must be an object")

nostr_db_path = Path(services["nostrDbPath"])
nostr_socket_path = Path(services["nostrServiceSocket"])
cashu_data_dir = Path(services["cashuDataDir"])
signer_policy_path = nostr_db_path.parent / "runtime-nostr-signer-policy.json"
override_signer_policy_path = override_root / "runtime-nostr-signer-policy.json"

if nostr_db_path == override_root / "runtime-nostr.sqlite3":
    raise SystemExit("vm-smoke: runtime session config nostr db unexpectedly matches env override")
if nostr_socket_path == override_root / "runtime-nostr.sock":
    raise SystemExit("vm-smoke: runtime session config nostr socket unexpectedly matches env override")
if cashu_data_dir == override_root / "runtime-cashu":
    raise SystemExit("vm-smoke: runtime session config cashu dir unexpectedly matches env override")

if not nostr_db_path.is_file():
    raise SystemExit(f"vm-smoke: expected config-backed nostr db {nostr_db_path} to exist")
if not cashu_data_dir.is_dir():
    raise SystemExit(f"vm-smoke: expected config-backed cashu dir {cashu_data_dir} to exist")
if not nostr_socket_path.exists():
    raise SystemExit(f"vm-smoke: expected config-backed nostr socket {nostr_socket_path} to exist")
if not stat.S_ISSOCK(nostr_socket_path.stat().st_mode):
    raise SystemExit(f"vm-smoke: expected config-backed nostr socket {nostr_socket_path} to be a unix socket")
if not signer_policy_path.is_file():
    raise SystemExit(f"vm-smoke: expected config-backed signer policy {signer_policy_path} to exist")
if (override_root / "runtime-nostr.sqlite3").exists():
    raise SystemExit("vm-smoke: env override unexpectedly owns the live nostr db path")
if (override_root / "runtime-nostr.sock").exists():
    raise SystemExit("vm-smoke: env override unexpectedly owns the live nostr socket path")
if (override_root / "runtime-cashu").exists():
    raise SystemExit("vm-smoke: env override unexpectedly owns the live cashu dir")
if override_signer_policy_path.exists():
    raise SystemExit("vm-smoke: env override unexpectedly owns the live signer policy path")
PY

echo "vm-smoke: home rust-timeline again"
"$SCRIPT_DIR/shadowctl" home -t vm >/dev/null
wait_for_home_state rust-timeline "rust-timeline second home" >/dev/null

echo "vm-smoke: synthetic system prompt"
start_synthetic_system_prompt
prompt_open_state="$(wait_for_prompt_state 1 "system prompt open")"
PROMPT_OPEN_STATE="$prompt_open_state" python3 - <<'PY'
import json
import os

state = json.loads(os.environ["PROMPT_OPEN_STATE"])
if state.get("prompt_source_app_id") != "vm-smoke":
    raise SystemExit(
        f"vm-smoke: expected prompt source app id 'vm-smoke', got {state.get('prompt_source_app_id')!r}"
    )
actions = state.get("prompt_actions") or []
if actions != ["deny", "allow_once", "allow_always"]:
    raise SystemExit(f"vm-smoke: unexpected prompt actions {actions!r}")
PY
run_shadowctl prompt -t vm allow_once >/dev/null
prompt_closed_state="$(wait_for_prompt_state 0 "system prompt close")"
finish_synthetic_system_prompt
PROMPT_CLOSED_STATE="$prompt_closed_state" python3 - <<'PY'
import json
import os

state = json.loads(os.environ["PROMPT_CLOSED_STATE"])
if state.get("prompt_active"):
    raise SystemExit("vm-smoke: prompt should be inactive after resolution")
PY

echo "vm-smoke: open podcast"
run_shadowctl open podcast -t vm >/dev/null
state_after_podcast_open="$(wait_for_open_state podcast "podcast open")"

echo "vm-smoke: screenshot"
run_shadowctl screenshot -t vm "$SHOT_PATH" >/dev/null

STATE_AFTER_TIMELINE_OPEN="$state_after_timeline_open" \
STATE_AFTER_COUNTER_OPEN="$state_after_counter_open" \
STATE_AFTER_COUNTER_HOME="$state_after_counter_home" \
STATE_AFTER_COUNTER_REOPEN="$state_after_counter_reopen" \
STATE_AFTER_TIMELINE_HOME="$state_after_timeline_home" \
STATE_AFTER_TIMELINE_REOPEN="$state_after_timeline_reopen" \
STATE_AFTER_CASHU_OPEN="$state_after_cashu_open" \
STATE_AFTER_CASHU_HOME="$state_after_cashu_home" \
STATE_AFTER_CASHU_REOPEN="$state_after_cashu_reopen" \
STATE_AFTER_CAMERA_OPEN="$state_after_camera_open" \
STATE_AFTER_CAMERA_HOME="$state_after_camera_home" \
STATE_AFTER_RUST_DEMO_OPEN="$state_after_rust_demo_open" \
STATE_AFTER_RUST_DEMO_HOME="$state_after_rust_demo_home" \
STATE_AFTER_RUST_DEMO_REOPEN="$state_after_rust_demo_reopen" \
STATE_AFTER_RUST_TIMELINE_OPEN="$state_after_rust_timeline_open" \
STATE_AFTER_RUST_TIMELINE_HOME="$state_after_rust_timeline_home" \
STATE_AFTER_RUST_TIMELINE_REOPEN="$state_after_rust_timeline_reopen" \
STATE_AFTER_PODCAST_OPEN="$state_after_podcast_open" \
SHOT_PATH="$SHOT_PATH" \
python3 - <<'PY'
import json
import os

counter_open = json.loads(os.environ["STATE_AFTER_COUNTER_OPEN"])
counter_home = json.loads(os.environ["STATE_AFTER_COUNTER_HOME"])
counter_reopen = json.loads(os.environ["STATE_AFTER_COUNTER_REOPEN"])
timeline_open = json.loads(os.environ["STATE_AFTER_TIMELINE_OPEN"])
timeline_home = json.loads(os.environ["STATE_AFTER_TIMELINE_HOME"])
timeline_reopen = json.loads(os.environ["STATE_AFTER_TIMELINE_REOPEN"])
cashu_open = json.loads(os.environ["STATE_AFTER_CASHU_OPEN"])
cashu_home = json.loads(os.environ["STATE_AFTER_CASHU_HOME"])
cashu_reopen = json.loads(os.environ["STATE_AFTER_CASHU_REOPEN"])
camera_open = json.loads(os.environ["STATE_AFTER_CAMERA_OPEN"])
camera_home = json.loads(os.environ["STATE_AFTER_CAMERA_HOME"])
rust_demo_open = json.loads(os.environ["STATE_AFTER_RUST_DEMO_OPEN"])
rust_demo_home = json.loads(os.environ["STATE_AFTER_RUST_DEMO_HOME"])
rust_demo_reopen = json.loads(os.environ["STATE_AFTER_RUST_DEMO_REOPEN"])
rust_timeline_open = json.loads(os.environ["STATE_AFTER_RUST_TIMELINE_OPEN"])
rust_timeline_home = json.loads(os.environ["STATE_AFTER_RUST_TIMELINE_HOME"])
rust_timeline_reopen = json.loads(os.environ["STATE_AFTER_RUST_TIMELINE_REOPEN"])
podcast_open = json.loads(os.environ["STATE_AFTER_PODCAST_OPEN"])


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"vm-smoke: {message}")


def expect_open(state: dict, app_id: str, label: str) -> None:
    expect(state.get("focused") == app_id, f"{label} focused={state.get('focused')!r}")
    expect(app_id in state.get("launched", []), f"{label} launched={state.get('launched')!r}")
    expect(app_id in state.get("mapped", []), f"{label} mapped={state.get('mapped')!r}")
    expect(app_id not in state.get("shelved", []), f"{label} shelved={state.get('shelved')!r}")


def expect_home(state: dict, app_id: str, label: str) -> None:
    expect(state.get("focused") in ("", None), f"{label} focused={state.get('focused')!r}")
    expect(app_id in state.get("launched", []), f"{label} launched={state.get('launched')!r}")
    expect(app_id not in state.get("mapped", []), f"{label} mapped={state.get('mapped')!r}")
    expect(app_id in state.get("shelved", []), f"{label} shelved={state.get('shelved')!r}")


expect_open(counter_open, "counter", "counter open")
expect_home(counter_home, "counter", "counter home")
expect_open(counter_reopen, "counter", "counter reopen")
expect_open(timeline_open, "timeline", "timeline open")
expect_home(timeline_home, "timeline", "timeline home")
expect_open(timeline_reopen, "timeline", "timeline reopen")
expect_open(cashu_open, "cashu", "cashu open")
expect_home(cashu_home, "cashu", "cashu home")
expect_open(cashu_reopen, "cashu", "cashu reopen")
expect_open(camera_open, "camera", "camera open")
expect_home(camera_home, "camera", "camera home")
expect_open(rust_demo_open, "rust-demo", "rust-demo open")
expect_home(rust_demo_home, "rust-demo", "rust-demo home")
expect_open(rust_demo_reopen, "rust-demo", "rust-demo reopen")
expect_open(rust_timeline_open, "rust-timeline", "rust-timeline open")
expect_home(rust_timeline_home, "rust-timeline", "rust-timeline home")
expect_open(rust_timeline_reopen, "rust-timeline", "rust-timeline reopen")
expect_open(podcast_open, "podcast", "podcast open")

print(
    json.dumps(
        {
            "result": "vm-smoke-ok",
            "screenshot": os.environ["SHOT_PATH"],
        },
        indent=2,
    )
)
PY

vm_smoke_succeeded=1
