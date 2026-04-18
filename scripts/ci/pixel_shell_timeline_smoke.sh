#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
restore_timeout_secs="${PIXEL_SHELL_SMOKE_RESTORE_TIMEOUT_SECS:-60}"
session_pid=""
latest_state_json=""
app_id="${PIXEL_SHELL_LIFECYCLE_APP_ID:-timeline}"
run_only=0

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run-only)
        run_only=1
        shift
        ;;
      --app)
        app_id="${2:?pixel_shell_timeline_smoke: --app requires a value}"
        shift 2
        ;;
      app=*)
        app_id="${1#app=}"
        shift
        ;;
      *)
        echo "pixel_shell_timeline_smoke: unsupported argument $1" >&2
        exit 64
        ;;
    esac
  done
}

parse_args "$@"

run_dir="$(pixel_prepare_named_run_dir "$(pixel_shell_runs_dir)")"
run_log="$run_dir/pixel-shell-${app_id}-smoke.log"
state_after_open_path="$run_dir/state-after-${app_id}-open.json"
state_after_home_path="$run_dir/state-after-${app_id}-home.json"
state_after_reopen_path="$run_dir/state-after-${app_id}-reopen.json"
session_host_pid_path="$run_dir/guest-ui-host.pid"
control_socket_path="$(pixel_shell_control_socket_path)"
launcher_args=(--no-camera-runtime)
if (( run_only == 1 )); then
  launcher_args=(--run-only "${launcher_args[@]}")
fi

restore_android_best_effort() {
  if pixel_android_display_stack_restored "$serial"; then
    return 0
  fi
  timeout "${PIXEL_RESTORE_ANDROID_TIMEOUT_SECS:-30}" \
    env PIXEL_SERIAL="$serial" "$SCRIPT_DIR/pixel/pixel_restore_android.sh" >/dev/null 2>&1 || true
}

dump_run_log() {
  if [[ -f "$run_log" ]]; then
    printf '\n== pixel-shell-%s-smoke log ==\n' "$app_id" >&2
    sed -n '1,260p' "$run_log" >&2
  fi
}

cleanup() {
  stop_session_process
  pixel_stop_shadow_session_best_effort "$serial"
  pixel_restore_android_best_effort "$serial" "$restore_timeout_secs"
  if [[ -n "${session_pid:-}" ]]; then
    stop_session_process
  fi
}

trap cleanup EXIT

session_still_running() {
  if [[ -n "${session_pid:-}" ]] && kill -0 "$session_pid" >/dev/null 2>&1; then
    return 0
  fi
  if [[ -f "$session_host_pid_path" ]]; then
    local host_pid
    host_pid="$(tr -cd '0-9' <"$session_host_pid_path")"
    if [[ -n "$host_pid" ]] && kill -0 "$host_pid" >/dev/null 2>&1; then
      return 0
    fi
  fi
  pixel_shell_socket_exists "$serial" "$control_socket_path"
}

stop_session_process() {
  local pid pids seen
  pids=()
  seen=" "

  add_session_pid() {
    local candidate="$1"
    [[ "$candidate" =~ ^[0-9]+$ ]] || return 0
    if [[ "$seen" != *" $candidate "* ]]; then
      pids+=("$candidate")
      seen="${seen}${candidate} "
    fi
  }

  kill_process_tree() {
    local tree_pid="$1"
    local signal="$2"
    local child
    for child in $(pgrep -P "$tree_pid" 2>/dev/null || true); do
      kill_process_tree "$child" "$signal"
    done
    kill "-$signal" "$tree_pid" >/dev/null 2>&1 || true
  }

  add_session_pid "${session_pid:-}"
  if [[ -f "$session_host_pid_path" ]]; then
    add_session_pid "$(tr -cd '0-9' <"$session_host_pid_path")"
  fi
  if ((${#pids[@]} == 0)); then
    return 0
  fi

  for pid in "${pids[@]}"; do
    kill_process_tree "$pid" TERM
  done

  local deadline=$((SECONDS + 10))
  while (( SECONDS < deadline )); do
    local any_running=0
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" >/dev/null 2>&1; then
        any_running=1
        break
      fi
    done
    if (( any_running == 0 )); then
      break
    fi
    sleep 0.2
  done

  for pid in "${pids[@]}"; do
    kill_process_tree "$pid" KILL
  done
  if [[ -n "${session_pid:-}" ]]; then
    wait "$session_pid" >/dev/null 2>&1 || true
  fi
}

capture_state_json() {
  local output
  if ! session_still_running; then
    return 1
  fi
  if ! output="$("$SCRIPT_DIR/shadowctl" --target "$serial" state --json 2>/dev/null)"; then
    return 1
  fi
  latest_state_json="$output"
}

state_matches() {
  local expected_focused="$1"
  local mapped_contains="$2"
  local mapped_absent="$3"
  local shelved_contains="$4"
  local shelved_absent="$5"

  capture_state_json || return 1

  STATE_JSON="$latest_state_json" \
  EXPECTED_FOCUSED="$expected_focused" \
  MAPPED_CONTAINS="$mapped_contains" \
  MAPPED_ABSENT="$mapped_absent" \
  SHELVED_CONTAINS="$shelved_contains" \
  SHELVED_ABSENT="$shelved_absent" \
  python3 - <<'PY' >/dev/null
import json
import os
import sys

state = json.loads(os.environ["STATE_JSON"])
focused = state.get("focused")
expected_focused = os.environ["EXPECTED_FOCUSED"]
mapped = state.get("mapped", [])
shelved = state.get("shelved", [])

if expected_focused:
    if focused != expected_focused:
        sys.exit(1)
else:
    if focused not in ("", None):
        sys.exit(1)

mapped_contains = os.environ["MAPPED_CONTAINS"]
if mapped_contains and mapped_contains not in mapped:
    sys.exit(1)

mapped_absent = os.environ["MAPPED_ABSENT"]
if mapped_absent and mapped_absent in mapped:
    sys.exit(1)

shelved_contains = os.environ["SHELVED_CONTAINS"]
if shelved_contains and shelved_contains not in shelved:
    sys.exit(1)

shelved_absent = os.environ["SHELVED_ABSENT"]
if shelved_absent and shelved_absent in shelved:
    sys.exit(1)
PY
}

wait_for_state() {
  local description="$1"
  local timeout_secs="$2"
  shift 2

  local deadline=$((SECONDS + timeout_secs))
  while (( SECONDS < deadline )); do
    if "$@"; then
      return 0
    fi
    if ! session_still_running; then
      dump_run_log
      echo "pixel-shell-${app_id}-smoke: session exited before ${description}" >&2
      exit 1
    fi
    sleep 1
  done

  if "$@"; then
    return 0
  fi

  dump_run_log
  echo "pixel-shell-${app_id}-smoke: timed out waiting for ${description}" >&2
  exit 1
}

shell_control_socket_ready() {
  pixel_shell_socket_exists "$serial" "$control_socket_path"
}

pixel_stop_shadow_session_best_effort "$serial"
pixel_restore_android_best_effort "$serial" "$restore_timeout_secs"

(
  cd "$REPO_ROOT"
  PIXEL_SERIAL="$serial" \
  PIXEL_GUEST_UI_HOST_PID_PATH="$session_host_pid_path" \
  PIXEL_GUEST_FRAME_CAPTURE_MODE=off \
    "$SCRIPT_DIR/pixel/pixel_shell_drm_hold.sh" "${launcher_args[@]}"
) >"$run_log" 2>&1 &
session_pid="$!"

wait_for_state "rooted Pixel shell control socket" 300 shell_control_socket_ready
"$SCRIPT_DIR/shadowctl" --target "$serial" open "$app_id" >/dev/null
wait_for_state "${app_id} launch through rooted Pixel shell" 60 \
  state_matches "$app_id" "$app_id" '' '' "$app_id"
printf '%s\n' "$latest_state_json" >"$state_after_open_path"

"$SCRIPT_DIR/shadowctl" --target "$serial" home >/dev/null
wait_for_state "${app_id} shelved after home" 30 \
  state_matches '' '' "$app_id" "$app_id" ''
printf '%s\n' "$latest_state_json" >"$state_after_home_path"

"$SCRIPT_DIR/shadowctl" --target "$serial" open "$app_id" >/dev/null
wait_for_state "${app_id} reopen through rooted Pixel shell" 30 \
  state_matches "$app_id" "$app_id" '' '' "$app_id"
printf '%s\n' "$latest_state_json" >"$state_after_reopen_path"

STATE_AFTER_OPEN="$(cat "$state_after_open_path")" \
STATE_AFTER_HOME="$(cat "$state_after_home_path")" \
STATE_AFTER_REOPEN="$(cat "$state_after_reopen_path")" \
RUN_LOG="$run_log" \
SERIAL="$serial" \
APP_ID="$app_id" \
python3 - <<'PY'
import json
import os

open_state = json.loads(os.environ["STATE_AFTER_OPEN"])
home_state = json.loads(os.environ["STATE_AFTER_HOME"])
reopen_state = json.loads(os.environ["STATE_AFTER_REOPEN"])
app_id = os.environ["APP_ID"]
prefix = f"pixel-shell-{app_id}-smoke"


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"{prefix}: {message}")


expect(open_state.get("focused") == app_id, f"open focused={open_state.get('focused')!r}")
expect(app_id in open_state.get("launched", []), f"open launched={open_state.get('launched')!r}")
expect(app_id in open_state.get("mapped", []), f"open mapped={open_state.get('mapped')!r}")
expect(app_id not in open_state.get("shelved", []), f"open shelved={open_state.get('shelved')!r}")

expect(home_state.get("focused") in ("", None), f"home focused={home_state.get('focused')!r}")
expect(app_id in home_state.get("launched", []), f"home launched={home_state.get('launched')!r}")
expect(app_id not in home_state.get("mapped", []), f"home mapped={home_state.get('mapped')!r}")
expect(app_id in home_state.get("shelved", []), f"home shelved={home_state.get('shelved')!r}")

expect(reopen_state.get("focused") == app_id, f"reopen focused={reopen_state.get('focused')!r}")
expect(app_id in reopen_state.get("launched", []), f"reopen launched={reopen_state.get('launched')!r}")
expect(app_id in reopen_state.get("mapped", []), f"reopen mapped={reopen_state.get('mapped')!r}")
expect(app_id not in reopen_state.get("shelved", []), f"reopen shelved={reopen_state.get('shelved')!r}")

print(
    json.dumps(
        {
            "app": app_id,
            "serial": os.environ["SERIAL"],
            "log": os.environ["RUN_LOG"],
            "result": f"pixel-shell-{app_id}-ok",
        },
        indent=2,
    )
)
PY
