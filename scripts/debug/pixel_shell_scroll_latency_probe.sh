#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
app_id="${PIXEL_SCROLL_LATENCY_APP_ID:-timeline}"
run_root="${PIXEL_SCROLL_LATENCY_RUN_ROOT:-$(pixel_touch_runs_dir)}"
run_dir="${PIXEL_SCROLL_LATENCY_RUN_DIR-}"
session_output_path=""
summary_path=""
wrapper_log_path=""
session_host_pid_path=""
control_socket_path="$(pixel_shell_control_socket_path)"
session_pid=""
restore_timeout_secs="${PIXEL_SHELL_SMOKE_RESTORE_TIMEOUT_SECS:-60}"

if [[ -z "$run_dir" ]]; then
  run_dir="$(pixel_prepare_named_run_dir "$run_root")"
else
  mkdir -p "$run_dir"
fi

session_output_path="$run_dir/session-output.txt"
summary_path="$run_dir/latency-summary.json"
wrapper_log_path="$run_dir/probe-driver.log"
session_host_pid_path="$run_dir/guest-ui-host.pid"

touch_session_output_has_marker() {
  local marker="$1"
  [[ -f "$session_output_path" ]] && grep -Fq "$marker" "$session_output_path"
}

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
  local pids pid seen
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

  for pid in "${pids[@]}"; do
    kill_process_tree "$pid" TERM
  done
  sleep 1
  for pid in "${pids[@]}"; do
    kill_process_tree "$pid" KILL
  done
}

cleanup() {
  stop_session_process
  pixel_stop_shadow_session_best_effort "$serial"
  pixel_restore_android_best_effort "$serial" "$restore_timeout_secs"
}

trap cleanup EXIT

wait_for_marker() {
  local description="$1"
  local marker="$2"
  local timeout_secs="${3:-240}"
  local deadline=$((SECONDS + timeout_secs))
  while (( SECONDS < deadline )); do
    if touch_session_output_has_marker "$marker"; then
      return 0
    fi
    if ! session_still_running; then
      if [[ -f "$wrapper_log_path" ]]; then
        printf '\n== pixel-shell-scroll-latency log ==\n' >&2
        sed -n '1,260p' "$wrapper_log_path" >&2
      fi
      echo "pixel_shell_scroll_latency_probe: session exited before ${description}" >&2
      exit 1
    fi
    sleep 1
  done

  if touch_session_output_has_marker "$marker"; then
    return 0
  fi
  if [[ -f "$wrapper_log_path" ]]; then
    printf '\n== pixel-shell-scroll-latency log ==\n' >&2
    sed -n '1,260p' "$wrapper_log_path" >&2
  fi
  echo "pixel_shell_scroll_latency_probe: timed out waiting for ${description}" >&2
  exit 1
}

panel_size="${PIXEL_SCROLL_LATENCY_PANEL_SIZE-}"
if [[ -z "$panel_size" ]]; then
  panel_size="$(pixel_display_size "$serial" 2>/dev/null || true)"
fi
if [[ -z "$panel_size" ]]; then
  panel_size="1080x2340"
fi
panel_width="${panel_size%x*}"
panel_height="${panel_size#*x}"
swipe_start_x="${PIXEL_SCROLL_LATENCY_SWIPE_START_X:-$((panel_width / 2))}"
swipe_end_x="${PIXEL_SCROLL_LATENCY_SWIPE_END_X:-$swipe_start_x}"
swipe_start_y="${PIXEL_SCROLL_LATENCY_SWIPE_START_Y:-$((panel_height * 78 / 100))}"
swipe_end_y="${PIXEL_SCROLL_LATENCY_SWIPE_END_Y:-$((panel_height * 22 / 100))}"
swipe_duration_ms="${PIXEL_SCROLL_LATENCY_SWIPE_DURATION_MS:-900}"
swipe_steps="${PIXEL_SCROLL_LATENCY_SWIPE_STEPS:-60}"
swipe_count="${PIXEL_SCROLL_LATENCY_SWIPE_COUNT:-3}"
swipe_gap_secs="${PIXEL_SCROLL_LATENCY_SWIPE_GAP_SECS:-0.25}"
ready_timeout_secs="${PIXEL_SCROLL_LATENCY_READY_TIMEOUT_SECS:-240}"

guest_extra_env="${PIXEL_SHELL_EXTRA_GUEST_CLIENT_ENV-}"
session_extra_env="${PIXEL_SHELL_EXTRA_SESSION_ENV-}"
if [[ -n "$session_extra_env" ]]; then
  session_extra_env="${session_extra_env}"$'\n'"SHADOW_GUEST_TOUCH_LATENCY_TRACE=1"
else
  session_extra_env="SHADOW_GUEST_TOUCH_LATENCY_TRACE=1"
fi
if [[ "${PIXEL_SCROLL_LATENCY_GPU_PROFILE_TRACE:-1}" == "1" ]]; then
  session_extra_env="${session_extra_env}"$'\n'"SHADOW_GUEST_COMPOSITOR_GPU_PROFILE_TRACE=1"
fi

printf 'pixel shell scroll latency probe: run_dir=%s app=%s panel=%s duration_ms=%s steps=%s count=%s\n' \
  "$run_dir" \
  "$app_id" \
  "$panel_size" \
  "$swipe_duration_ms" \
  "$swipe_steps" \
  "$swipe_count" | tee "$wrapper_log_path"

pixel_stop_shadow_session_best_effort "$serial"
pixel_restore_android_best_effort "$serial" "$restore_timeout_secs"

(
  cd "$REPO_ROOT"
  PIXEL_SERIAL="$serial" \
  PIXEL_GUEST_RUN_DIR="$run_dir" \
  PIXEL_GUEST_UI_HOST_PID_PATH="$session_host_pid_path" \
  PIXEL_GUEST_FRAME_CAPTURE_MODE=off \
  PIXEL_SHELL_EXTRA_GUEST_CLIENT_ENV="$guest_extra_env" \
  PIXEL_SHELL_EXTRA_SESSION_ENV="$session_extra_env" \
    "$SCRIPT_DIR/pixel/pixel_shell_drm_hold.sh" --no-camera-runtime --app "$app_id"
) >>"$wrapper_log_path" 2>&1 &
session_pid="$!"

wait_for_marker "touch-ready" "[shadow-guest-compositor] touch-ready" "$ready_timeout_secs"
wait_for_marker "${app_id} hosted app track" "[shadow-guest-compositor] surface-app-tracked app=$app_id transport=hosted" "$ready_timeout_secs"

sleep 1
for attempt in $(seq 1 "$swipe_count"); do
  printf 'inject sustained swipe index=%s start=%s,%s end=%s,%s duration_ms=%s steps=%s\n' \
    "$attempt" \
    "$swipe_start_x" \
    "$swipe_start_y" \
    "$swipe_end_x" \
    "$swipe_end_y" \
    "$swipe_duration_ms" \
    "$swipe_steps" | tee -a "$wrapper_log_path"
  pixel_touchscreen_swipe_panel \
    "$serial" \
    "$swipe_start_x" \
    "$swipe_start_y" \
    "$swipe_end_x" \
    "$swipe_end_y" \
    "$panel_size" \
    "$swipe_duration_ms" \
    "$swipe_steps"
  sleep "$swipe_gap_secs"
done

sleep 2
stop_session_process
set +e
wait "$session_pid"
session_status="$?"
set -e
session_pid=""

python3 "$SCRIPT_DIR/pixel/pixel_runtime_summary.py" \
  "$run_dir" \
  --renderer gpu \
  --output "$summary_path"

printf 'pixel shell scroll latency summary: %s\n' "$summary_path"

if [[ "$session_status" != "0" && "$session_status" != "143" && "$session_status" != "137" ]]; then
  exit "$session_status"
fi
