#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$REPO_ROOT/build/ui-vm"
RUN_LOG="$LOG_DIR/ui-vm-camera-smoke.log"
SHOT_PATH="$LOG_DIR/ui-vm-camera-smoke.png"

cleanup() {
  "$SCRIPT_DIR/ui_vm_stop.sh" >/dev/null 2>&1 || true
}

trap cleanup EXIT

mkdir -p "$LOG_DIR"
cleanup

(
  cd "$REPO_ROOT"
  SHADOW_UI_VM_START_APP_ID=camera "$SCRIPT_DIR/ui_vm_run.sh"
) >"$RUN_LOG" 2>&1 &

"$SCRIPT_DIR/shadowctl" wait-ready -t vm
sleep 2
state_after_boot="$("$SCRIPT_DIR/shadowctl" state -t vm --json)"
"$SCRIPT_DIR/shadowctl" screenshot -t vm "$SHOT_PATH" >/dev/null

STATE_AFTER_BOOT="$state_after_boot" \
SHOT_PATH="$SHOT_PATH" \
python3 - <<'PY'
import json
import os

boot_state = json.loads(os.environ["STATE_AFTER_BOOT"])


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"ui-vm-camera-smoke: {message}")


expect(boot_state.get("focused") == "camera", f"boot focused={boot_state.get('focused')!r}")
expect("camera" in boot_state.get("launched", []), f"boot launched={boot_state.get('launched')!r}")
expect("camera" in boot_state.get("mapped", []), f"boot mapped={boot_state.get('mapped')!r}")
expect("camera" not in boot_state.get("shelved", []), f"boot shelved={boot_state.get('shelved')!r}")

print(
    json.dumps(
        {
            "result": "ui-vm-camera-ok",
            "screenshot": os.environ["SHOT_PATH"],
        },
        indent=2,
    )
)
PY
