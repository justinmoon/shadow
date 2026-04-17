#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
renderer="${PIXEL_RUNTIME_APP_RENDERER:-gpu_softbuffer}"
gpu_profile="${PIXEL_RUNTIME_APP_GPU_PROFILE-}"
run_root="${PIXEL_TOUCH_LATENCY_RUN_ROOT:-$(pixel_touch_runs_dir)}"
run_dir="${PIXEL_TOUCH_LATENCY_RUN_DIR-}"
session_output_path=""
checkpoint_log_path=""
session_pid=""

if [[ -z "$run_dir" ]]; then
  run_dir="$(pixel_prepare_named_run_dir "$run_root")"
else
  mkdir -p "$run_dir"
fi

session_output_path="$run_dir/session-output.txt"
checkpoint_log_path="$run_dir/checkpoints.txt"
wrapper_log_path="$run_dir/probe-driver.log"
summary_path="$run_dir/latency-summary.json"

touch_session_output_has_marker() {
  local marker="$1"
  [[ -f "$session_output_path" ]] && grep -Fq "$marker" "$session_output_path"
}

touch_probe_session_running() {
  [[ -n "$session_pid" ]] && kill -0 "$session_pid" >/dev/null 2>&1
}

touch_checkpoints_have() {
  local marker="$1"
  [[ -f "$checkpoint_log_path" ]] && grep -Fq "$marker" "$checkpoint_log_path"
}

cleanup() {
  if touch_probe_session_running; then
    kill "$session_pid" >/dev/null 2>&1 || true
    wait "$session_pid" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

panel_size="${PIXEL_TOUCH_LATENCY_PANEL_SIZE-}"
if [[ -z "$panel_size" ]]; then
  panel_size="$(pixel_display_size "$serial" 2>/dev/null || true)"
fi
if [[ -z "$panel_size" ]]; then
  panel_size="1080x2340"
  printf 'pixel touch latency probe: warning: using fallback panel size %s because wm size is unavailable\n' \
    "$panel_size" | tee -a "$wrapper_log_path" >&2
fi
panel_width="${panel_size%x*}"
panel_height="${panel_size#*x}"
tap_x="${PIXEL_TOUCH_LATENCY_TAP_X:-$((panel_width / 2))}"
tap_y="${PIXEL_TOUCH_LATENCY_TAP_Y:-$((panel_height * 55 / 100))}"
swipe_start_x="${PIXEL_TOUCH_LATENCY_SWIPE_START_X:-$((panel_width / 2))}"
swipe_end_x="${PIXEL_TOUCH_LATENCY_SWIPE_END_X:-$swipe_start_x}"
swipe_start_y="${PIXEL_TOUCH_LATENCY_SWIPE_START_Y:-$((panel_height * 78 / 100))}"
swipe_end_y="${PIXEL_TOUCH_LATENCY_SWIPE_END_Y:-$((panel_height * 32 / 100))}"
swipe_duration_ms="${PIXEL_TOUCH_LATENCY_SWIPE_DURATION_MS:-220}"
swipe_steps="${PIXEL_TOUCH_LATENCY_SWIPE_STEPS:-18}"
swipe_count="${PIXEL_TOUCH_LATENCY_SWIPE_COUNT:-3}"
checkpoint_timeout_secs="${PIXEL_TOUCH_LATENCY_CHECKPOINT_TIMEOUT_SECS:-240}"

guest_extra_env="${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}"
if [[ -n "$guest_extra_env" ]]; then
  guest_extra_env="${guest_extra_env}"$'\n'"SHADOW_BLITZ_LOG_WINIT_POINTER=1"
else
  guest_extra_env="SHADOW_BLITZ_LOG_WINIT_POINTER=1"
fi

session_extra_env="${PIXEL_RUNTIME_APP_EXTRA_SESSION_ENV-}"
if [[ -n "$session_extra_env" ]]; then
  session_extra_env="${session_extra_env}"$'\n'"SHADOW_GUEST_TOUCH_LATENCY_TRACE=1"
else
  session_extra_env="SHADOW_GUEST_TOUCH_LATENCY_TRACE=1"
fi

runtime_app_config_json="${SHADOW_RUNTIME_APP_CONFIG_JSON:-}"
if [[ -z "$runtime_app_config_json" ]]; then
  runtime_app_config_json='{"limit":24,"relayUrls":["wss://relay.primal.net/","wss://relay.damus.io/"],"syncOnStart":false}'
fi

printf 'pixel touch latency probe: run_dir=%s renderer=%s profile=%s panel=%s\n' \
  "$run_dir" \
  "$renderer" \
  "${gpu_profile:-default}" \
  "$panel_size" | tee "$wrapper_log_path"

set +e
env \
  PIXEL_GUEST_RUN_DIR="$run_dir" \
  PIXEL_RUNTIME_APP_PANEL_SIZE="$panel_size" \
  PIXEL_RUNTIME_APP_RENDERER="$renderer" \
  PIXEL_RUNTIME_APP_GPU_PROFILE="$gpu_profile" \
  PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS="${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS:-25000}" \
  PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-120}" \
  PIXEL_GUEST_SESSION_EXIT_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_EXIT_TIMEOUT_SECS:-90}" \
  PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV="$guest_extra_env" \
  PIXEL_RUNTIME_APP_EXTRA_SESSION_ENV="$session_extra_env" \
  SHADOW_RUNTIME_APP_CONFIG_JSON="$runtime_app_config_json" \
  "$SCRIPT_DIR/pixel/pixel_runtime_app_nostr_timeline_drm.sh" >>"$wrapper_log_path" 2>&1 &
session_pid="$!"
set -e

if ! pixel_wait_for_condition "$checkpoint_timeout_secs" 1 touch_checkpoints_have "observed: client marker seen"; then
  echo "pixel_touch_latency_probe: client marker checkpoint not observed" | tee -a "$wrapper_log_path" >&2
  wait "$session_pid" || true
  exit 1
fi

if ! pixel_wait_for_condition "$checkpoint_timeout_secs" 1 touch_checkpoints_have "observed: required marker seen"; then
  echo "pixel_touch_latency_probe: required marker checkpoint not observed" | tee -a "$wrapper_log_path" >&2
  wait "$session_pid" || true
  exit 1
fi

sleep 2
printf 'inject tap panel=%s,%s\n' "$tap_x" "$tap_y" | tee -a "$wrapper_log_path"
pixel_touchscreen_tap_panel "$serial" "$tap_x" "$tap_y" "$panel_size"

sleep 1
for attempt in $(seq 1 "$swipe_count"); do
  printf 'inject swipe index=%s start=%s,%s end=%s,%s duration_ms=%s steps=%s\n' \
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
  sleep 1
done

set +e
wait "$session_pid"
session_status="$?"
set -e
session_pid=""

python3 "$SCRIPT_DIR/pixel/pixel_runtime_summary.py" \
  "$run_dir" \
  --renderer "$renderer" \
  --output "$summary_path"

printf 'pixel touch latency summary: %s\n' "$summary_path"

if [[ "$session_status" != "0" ]]; then
  exit "$session_status"
fi
