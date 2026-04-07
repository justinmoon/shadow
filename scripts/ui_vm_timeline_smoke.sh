#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$REPO_ROOT/build/ui-vm"
RUN_LOG="$LOG_DIR/ui-vm-timeline-smoke.log"
SHOT_PATH="$LOG_DIR/ui-vm-timeline-smoke.png"

cleanup() {
  "$SCRIPT_DIR/ui_vm_stop.sh" >/dev/null 2>&1 || true
}

trap cleanup EXIT

mkdir -p "$LOG_DIR"
cleanup

(
  cd "$REPO_ROOT"
  SHADOW_UI_VM_REFRESH_RUNTIME_ENV=1 "$SCRIPT_DIR/ui_vm_run.sh"
) >"$RUN_LOG" 2>&1 &

"$SCRIPT_DIR/shadowctl" vm wait-ready
"$SCRIPT_DIR/shadowctl" vm open timeline >/dev/null
sleep 2
state_after_open="$("$SCRIPT_DIR/shadowctl" vm state --json)"
"$SCRIPT_DIR/shadowctl" vm home >/dev/null
sleep 1
state_after_home="$("$SCRIPT_DIR/shadowctl" vm state --json)"
"$SCRIPT_DIR/shadowctl" vm open timeline >/dev/null
sleep 2
state_after_reopen="$("$SCRIPT_DIR/shadowctl" vm state --json)"
"$SCRIPT_DIR/shadowctl" vm screenshot "$SHOT_PATH" >/dev/null

STATE_AFTER_OPEN="$state_after_open" \
STATE_AFTER_HOME="$state_after_home" \
STATE_AFTER_REOPEN="$state_after_reopen" \
SHOT_PATH="$SHOT_PATH" \
python3 - <<'PY'
import json
import os

open_state = json.loads(os.environ["STATE_AFTER_OPEN"])
home_state = json.loads(os.environ["STATE_AFTER_HOME"])
reopen_state = json.loads(os.environ["STATE_AFTER_REOPEN"])


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"ui-vm-timeline-smoke: {message}")


expect(open_state.get("focused") == "timeline", f"open focused={open_state.get('focused')!r}")
expect("timeline" in open_state.get("launched", []), f"open launched={open_state.get('launched')!r}")
expect("timeline" in open_state.get("mapped", []), f"open mapped={open_state.get('mapped')!r}")
expect("timeline" not in open_state.get("shelved", []), f"open shelved={open_state.get('shelved')!r}")

expect(home_state.get("focused") in ("", None), f"home focused={home_state.get('focused')!r}")
expect("timeline" in home_state.get("launched", []), f"home launched={home_state.get('launched')!r}")
expect("timeline" not in home_state.get("mapped", []), f"home mapped={home_state.get('mapped')!r}")
expect("timeline" in home_state.get("shelved", []), f"home shelved={home_state.get('shelved')!r}")

expect(reopen_state.get("focused") == "timeline", f"reopen focused={reopen_state.get('focused')!r}")
expect("timeline" in reopen_state.get("launched", []), f"reopen launched={reopen_state.get('launched')!r}")
expect("timeline" in reopen_state.get("mapped", []), f"reopen mapped={reopen_state.get('mapped')!r}")
expect("timeline" not in reopen_state.get("shelved", []), f"reopen shelved={reopen_state.get('shelved')!r}")

print(
    json.dumps(
        {
            "result": "ui-vm-timeline-ok",
            "screenshot": os.environ["SHOT_PATH"],
        },
        indent=2,
    )
)
PY
