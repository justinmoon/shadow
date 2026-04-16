#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./ui_vm_common.sh
source "$SCRIPT_DIR/ui_vm_common.sh"
LOG_DIR="$REPO_ROOT/build/ui-vm"
RUN_LOG="$LOG_DIR/ui-vm-smoke.log"
SHOT_PATH="$LOG_DIR/ui-vm-smoke.png"
VM_SOCKET_PATH="$REPO_ROOT/.shadow-vm/shadow-ui-vm.sock"
VM_STATE_IMAGE_PATH="$REPO_ROOT/.shadow-vm/shadow-ui-state.img"
UI_VM_PREP_TIMEOUT_SECS="${SHADOW_UI_VM_SMOKE_PREP_TIMEOUT:-900}"
# Fresh worktrees can trigger cold VM artifact preparation before the compositor
# is ready. Keep the required pre-merge smoke tolerant of that path.
UI_VM_READY_TIMEOUT_SECS="${SHADOW_UI_VM_SMOKE_READY_TIMEOUT:-1200}"
UI_VM_APP_TIMEOUT_SECS="${SHADOW_UI_VM_SMOKE_APP_TIMEOUT:-90}"
ui_vm_run_pid=""

wait_for_open_state() {
  local app_id="$1"
  local label="$2"
  local deadline=$((SECONDS + UI_VM_APP_TIMEOUT_SECS))
  local state_json=""

  while true; do
    state_json="$("$SCRIPT_DIR/shadowctl" state -t vm --json)"
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
      echo "ui-vm-smoke: timed out waiting for ${label}" >&2
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

  while true; do
    state_json="$("$SCRIPT_DIR/shadowctl" state -t vm --json)"
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
      echo "ui-vm-smoke: timed out waiting for ${label}" >&2
      printf '%s\n' "$state_json" >&2
      return 1
    fi

    sleep 1
  done
}

dump_failure_context() {
  if [[ -f "$RUN_LOG" ]]; then
    printf '\n== ui-vm-smoke run log ==\n' >&2
    sed -n '1,240p' "$RUN_LOG" >&2 || true
  fi

  printf '\n== ui-vm doctor ==\n' >&2
  "$SCRIPT_DIR/shadowctl" doctor -t vm >&2 || true

  printf '\n== ui-vm logs ==\n' >&2
  "$SCRIPT_DIR/shadowctl" logs -t vm --lines 200 >&2 || true

  printf '\n== ui-vm journal ==\n' >&2
  "$SCRIPT_DIR/shadowctl" journal -t vm --lines 120 >&2 || true
}

finish() {
  local status="$1"

  if (( status != 0 )); then
    "$SCRIPT_DIR/shadowctl" screenshot -t vm "$SHOT_PATH" >/dev/null 2>&1 || true
    dump_failure_context
  fi

  "$SCRIPT_DIR/ui_vm_stop.sh" >/dev/null 2>&1 || true
  if [[ -n "$ui_vm_run_pid" ]]; then
    wait "$ui_vm_run_pid" 2>/dev/null || true
  fi
}

trap 'status=$?; finish "$status"; exit "$status"' EXIT

mkdir -p "$LOG_DIR"
: >"$RUN_LOG"
"$SCRIPT_DIR/ui_vm_stop.sh" >/dev/null 2>&1 || true
# The branch gate should prove a clean boot/session lifecycle, not inherit
# whichever apps happened to be warm in the previous VM run.
rm -f "$VM_STATE_IMAGE_PATH"

(
  cd "$REPO_ROOT"
  SHADOW_RUNTIME_AUDIO_BACKEND=memory "$SCRIPT_DIR/ui_vm_run.sh"
) >"$RUN_LOG" 2>&1 &
ui_vm_run_pid=$!

prep_start="$(date +%s)"
while true; do
  if [[ -S "$VM_SOCKET_PATH" ]]; then
    break
  fi

  if ! kill -0 "$ui_vm_run_pid" 2>/dev/null; then
    echo "ui-vm-smoke: ui_vm_run exited before the VM started" >&2
    wait "$ui_vm_run_pid"
    exit 1
  fi

  prep_now="$(date +%s)"
  if (( prep_now - prep_start > UI_VM_PREP_TIMEOUT_SECS )); then
    echo "ui-vm-smoke: timed out waiting for VM bootstrap" >&2
    exit 1
  fi

  sleep 1
done

"$SCRIPT_DIR/shadowctl" wait-ready -t vm --timeout "$UI_VM_READY_TIMEOUT_SECS"

doctor_json="$("$SCRIPT_DIR/shadowctl" doctor -t vm --json)"
REPO_ROOT="$REPO_ROOT" \
EXPECTED_ARTIFACT_SHARE="$REPO_ROOT/.shadow-vm/runtime-artifacts" \
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
repo_root = Path(os.environ["REPO_ROOT"]).resolve()

if issues:
    raise SystemExit(f"ui-vm-smoke: doctor reported issues: {issues!r}")
if artifact_share is None:
    raise SystemExit(
        f"ui-vm-smoke: expected artifact share {str(expected)!r}, got {artifact_share!r}"
    )
artifact_share_path = Path(artifact_share)
if not artifact_share_path.is_absolute():
    artifact_share_path = (repo_root / artifact_share_path).resolve()
if artifact_share_path != expected:
    raise SystemExit(
        f"ui-vm-smoke: expected artifact share {str(expected)!r}, got {artifact_share!r}"
    )
PY

echo "ui-vm-smoke: open timeline"
"$SCRIPT_DIR/shadowctl" open timeline -t vm >/dev/null
state_after_timeline_open="$(wait_for_open_state timeline "timeline open")"

echo "ui-vm-smoke: home timeline"
"$SCRIPT_DIR/shadowctl" home -t vm >/dev/null
state_after_timeline_home="$(wait_for_home_state timeline "timeline home")"

echo "ui-vm-smoke: reopen timeline"
"$SCRIPT_DIR/shadowctl" open timeline -t vm >/dev/null
state_after_timeline_reopen="$(wait_for_open_state timeline "timeline reopen")"

echo "ui-vm-smoke: home timeline again"
"$SCRIPT_DIR/shadowctl" home -t vm >/dev/null
wait_for_home_state timeline "timeline second home" >/dev/null

echo "ui-vm-smoke: open camera"
"$SCRIPT_DIR/shadowctl" open camera -t vm >/dev/null
state_after_camera_open="$(wait_for_open_state camera "camera open")"

echo "ui-vm-smoke: home camera"
"$SCRIPT_DIR/shadowctl" home -t vm >/dev/null
state_after_camera_home="$(wait_for_home_state camera "camera home")"

echo "ui-vm-smoke: open podcast"
"$SCRIPT_DIR/shadowctl" open podcast -t vm >/dev/null
state_after_podcast_open="$(wait_for_open_state podcast "podcast open")"

echo "ui-vm-smoke: screenshot"
"$SCRIPT_DIR/shadowctl" screenshot -t vm "$SHOT_PATH" >/dev/null

STATE_AFTER_TIMELINE_OPEN="$state_after_timeline_open" \
STATE_AFTER_TIMELINE_HOME="$state_after_timeline_home" \
STATE_AFTER_TIMELINE_REOPEN="$state_after_timeline_reopen" \
STATE_AFTER_CAMERA_OPEN="$state_after_camera_open" \
STATE_AFTER_CAMERA_HOME="$state_after_camera_home" \
STATE_AFTER_PODCAST_OPEN="$state_after_podcast_open" \
SHOT_PATH="$SHOT_PATH" \
python3 - <<'PY'
import json
import os

timeline_open = json.loads(os.environ["STATE_AFTER_TIMELINE_OPEN"])
timeline_home = json.loads(os.environ["STATE_AFTER_TIMELINE_HOME"])
timeline_reopen = json.loads(os.environ["STATE_AFTER_TIMELINE_REOPEN"])
camera_open = json.loads(os.environ["STATE_AFTER_CAMERA_OPEN"])
camera_home = json.loads(os.environ["STATE_AFTER_CAMERA_HOME"])
podcast_open = json.loads(os.environ["STATE_AFTER_PODCAST_OPEN"])


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"ui-vm-smoke: {message}")


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


expect_open(timeline_open, "timeline", "timeline open")
expect_home(timeline_home, "timeline", "timeline home")
expect_open(timeline_reopen, "timeline", "timeline reopen")
expect_open(camera_open, "camera", "camera open")
expect_home(camera_home, "camera", "camera home")
expect_open(podcast_open, "podcast", "podcast open")

print(
    json.dumps(
        {
            "result": "ui-vm-smoke-ok",
            "screenshot": os.environ["SHOT_PATH"],
        },
        indent=2,
    )
)
PY
