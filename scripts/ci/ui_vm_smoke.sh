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
ui_vm_run_pid=""
prepared_inputs_path="${SHADOW_UI_VM_PREPARED_INPUTS:-}"

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

wait_for_open_state() {
  local app_id="$1"
  local label="$2"
  local deadline=$((SECONDS + UI_VM_APP_TIMEOUT_SECS))
  local state_json=""
  local probe_status=0

  while true; do
    if ! state_json="$(run_shadowctl state -t vm --json)"; then
      probe_status=$?
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
    if ! state_json="$(run_shadowctl state -t vm --json)"; then
      probe_status=$?
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
  if [[ -n "$ui_vm_run_pid" ]]; then
    kill "$ui_vm_run_pid" >/dev/null 2>&1 || true
    wait "$ui_vm_run_pid" 2>/dev/null || true
  fi
}

trap 'status=$?; finish "$status"; exit "$status"' EXIT

mkdir -p "$LOG_DIR"
: >"$RUN_LOG"
run_vm_stop >/dev/null 2>&1 || true
# The branch gate should prove a clean boot/session lifecycle, not inherit
# whichever apps happened to be warm in the previous VM run.
rm -f "$VM_STATE_IMAGE_PATH"

(
  cd "$REPO_ROOT"
  SHADOW_RUNTIME_AUDIO_BACKEND=memory \
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

with manifest_path.open("r", encoding="utf-8") as handle:
    manifest = json.load(handle)

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

echo "vm-smoke: home rust-demo"
"$SCRIPT_DIR/shadowctl" home -t vm >/dev/null
state_after_rust_demo_home="$(wait_for_home_state rust-demo "rust-demo home")"

echo "vm-smoke: open podcast"
run_shadowctl open podcast -t vm >/dev/null
state_after_podcast_open="$(wait_for_open_state podcast "podcast open")"

echo "vm-smoke: screenshot"
run_shadowctl screenshot -t vm "$SHOT_PATH" >/dev/null

STATE_AFTER_TIMELINE_OPEN="$state_after_timeline_open" \
STATE_AFTER_TIMELINE_HOME="$state_after_timeline_home" \
STATE_AFTER_TIMELINE_REOPEN="$state_after_timeline_reopen" \
STATE_AFTER_CASHU_OPEN="$state_after_cashu_open" \
STATE_AFTER_CASHU_HOME="$state_after_cashu_home" \
STATE_AFTER_CASHU_REOPEN="$state_after_cashu_reopen" \
STATE_AFTER_CAMERA_OPEN="$state_after_camera_open" \
STATE_AFTER_CAMERA_HOME="$state_after_camera_home" \
STATE_AFTER_RUST_DEMO_OPEN="$state_after_rust_demo_open" \
STATE_AFTER_RUST_DEMO_HOME="$state_after_rust_demo_home" \
STATE_AFTER_PODCAST_OPEN="$state_after_podcast_open" \
SHOT_PATH="$SHOT_PATH" \
python3 - <<'PY'
import json
import os

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

vm_smoke_record_success "$prepared_inputs_path" "$REPO_ROOT"
