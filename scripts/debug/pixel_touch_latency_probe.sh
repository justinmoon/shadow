#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./pixel_runtime_linux_bundle_common.sh
source "$SCRIPT_DIR/lib/pixel_runtime_linux_bundle_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
gpu_profile="${PIXEL_RUNTIME_APP_GPU_PROFILE-}"
probe_app="${PIXEL_TOUCH_LATENCY_APP:-timeline}"
if [[ "${PIXEL_TOUCH_LATENCY_RUST_COUNTER:-}" == "1" ]]; then
  probe_app="rust-counter"
fi
case "$probe_app" in
  timeline | rust-counter | rust-demo) ;;
  *)
    echo "pixel_touch_latency_probe: unsupported PIXEL_TOUCH_LATENCY_APP=$probe_app" >&2
    exit 2
    ;;
esac
if [[ "$probe_app" == "rust-demo" ]]; then
  probe_app="rust-counter"
fi
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

touch_session_output_has_post_touch_frame_artifact() {
  python3 - "$session_output_path" "$(pixel_frame_path)" <<'PY'
import sys
from pathlib import Path

session_output_path = Path(sys.argv[1])
frame_path = sys.argv[2]
if not session_output_path.is_file():
    raise SystemExit(1)

text = session_output_path.read_text(encoding="utf-8", errors="replace")
markers = [
    "shadow-rust-demo: counter_incremented count=1",
    "shadow-rust-demo: frame_committed counter=1",
    f"[shadow-guest-compositor] wrote-frame-artifact path={frame_path}",
]
position = 0
for marker in markers:
    found = text.find(marker, position)
    if found < 0:
        raise SystemExit(1)
    position = found + len(marker)
PY
}

cleanup() {
  if touch_probe_session_running; then
    kill "$session_pid" >/dev/null 2>&1 || true
    wait "$session_pid" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

prepare_rust_counter_bundle() {
  local repo package_system package_ref bundle_dir bundle_out_link launcher_artifact

  repo="$(repo_root)"
  package_system="${PIXEL_GUEST_BUILD_SYSTEM:-aarch64-linux}"
  package_ref="$repo#packages.${package_system}.shadow-rust-demo"
  bundle_dir="$(pixel_system_bundle_artifact_dir)"
  bundle_out_link="$(pixel_dir)/shadow-rust-demo-${package_system}-result"
  launcher_artifact="$(pixel_guest_client_artifact)"

  stage_system_linux_bundle "$package_ref" "$bundle_out_link" "$bundle_dir" "shadow-rust-demo"
  chmod -R u+w "$bundle_dir" 2>/dev/null || true
  fill_linux_bundle_runtime_deps "$bundle_dir"
  stage_runtime_bundle_xkb_config "$bundle_dir"
  mkdir -p "$(dirname "$launcher_artifact")"
  cat >"$launcher_artifact" <<EOF
#!/system/bin/sh
set -e
DIR=\$(cd "\$(dirname "\$0")" && pwd)

export HOME="\$DIR/home"
export XDG_CACHE_HOME="\$HOME/.cache"
export XDG_CONFIG_HOME="\$HOME/.config"
export LD_LIBRARY_PATH="\$DIR/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export XKB_CONFIG_EXTRA_PATH="\${XKB_CONFIG_EXTRA_PATH:-\$DIR/etc/xkb}"
export XKB_CONFIG_ROOT="\${XKB_CONFIG_ROOT:-\$DIR/share/X11/xkb}"
mkdir -p "\$HOME" "\$XDG_CACHE_HOME" "\$XDG_CONFIG_HOME"

exec "\$DIR/lib/$PIXEL_RUNTIME_STAGE_LOADER_NAME" --library-path "\$DIR/lib" "\$DIR/shadow-rust-demo" "\$@"
EOF
  chmod 0755 "$launcher_artifact"
}

write_rust_counter_summary() {
  local post_touch_frame_path="$1"

  python3 - \
    "$summary_path" \
    "$session_output_path" \
    "$post_touch_frame_path" <<'PY'
import json
import re
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
session_output_path = Path(sys.argv[2])
post_touch_frame_path = Path(sys.argv[3])

try:
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
except (FileNotFoundError, json.JSONDecodeError):
    summary = {}

session_output = session_output_path.read_text(encoding="utf-8", errors="replace")
increments = [
    int(match.group(1))
    for match in re.finditer(r"shadow-rust-demo: counter_incremented count=(\d+)", session_output)
]
frame_commits = [
    {
        "counter": int(match.group(1)),
        "checksum": match.group(2),
        "size": match.group(3),
    }
    for match in re.finditer(
        r"shadow-rust-demo: frame_committed counter=(\d+) checksum=([0-9a-f]+) size=([0-9]+x[0-9]+)",
        session_output,
    )
]
input_observed = (
    "[shadow-guest-compositor] touch-app-tap-dispatch" in session_output
    or "[shadow-guest-compositor] touch-input phase=Down" in session_output
)
artifact_markers = [
    "shadow-rust-demo: counter_incremented count=1",
    "shadow-rust-demo: frame_committed counter=1",
    "[shadow-guest-compositor] wrote-frame-artifact",
]
artifact_position = 0
post_touch_frame_artifact_logged = True
for artifact_marker in artifact_markers:
    artifact_found = session_output.find(artifact_marker, artifact_position)
    if artifact_found < 0:
        post_touch_frame_artifact_logged = False
        break
    artifact_position = artifact_found + len(artifact_marker)
post_touch_frame_bytes = (
    post_touch_frame_path.stat().st_size if post_touch_frame_path.is_file() else 0
)
app_incremented = bool(increments and max(increments) >= 1)
post_touch_frame_captured = post_touch_frame_bytes > 0

summary["rust_counter_probe"] = {
    "input_observed": input_observed,
    "app_incremented": app_incremented,
    "max_counter": max(increments) if increments else 0,
    "frame_commits": frame_commits,
    "post_touch_frame_artifact_logged": post_touch_frame_artifact_logged,
    "post_touch_frame_captured": post_touch_frame_captured,
    "post_touch_frame_path": str(post_touch_frame_path),
    "post_touch_frame_bytes": post_touch_frame_bytes,
}
summary["rust_counter_probe_ok"] = (
    input_observed
    and app_incremented
    and post_touch_frame_artifact_logged
    and post_touch_frame_captured
)
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
if not summary["rust_counter_probe_ok"]:
    raise SystemExit("rust counter probe did not prove input, increment, and post-touch frame")
PY
}

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

run_rust_counter_probe() {
  local rust_client_env rust_session_env rust_required_markers post_touch_frame_path session_status
  local rust_surface_width rust_surface_height

  rust_surface_width="${PIXEL_TOUCH_LATENCY_RUST_SURFACE_WIDTH:-540}"
  rust_surface_height="${PIXEL_TOUCH_LATENCY_RUST_SURFACE_HEIGHT:-1042}"

  printf 'pixel touch latency probe: app=rust-counter direct-app=rust-demo\n' \
    | tee -a "$wrapper_log_path"

  prepare_rust_counter_bundle

  rust_client_env="$(
    cat <<EOF
SHADOW_APP_SURFACE_WIDTH=$rust_surface_width
SHADOW_APP_SURFACE_HEIGHT=$rust_surface_height
SHADOW_APP_UNDECORATED=1
EOF
  )"
  if [[ -n "${PIXEL_TOUCH_LATENCY_RUST_CLIENT_ENV-}" ]]; then
    rust_client_env="${rust_client_env}"$'\n'"${PIXEL_TOUCH_LATENCY_RUST_CLIENT_ENV}"
  fi

  rust_session_env="$(
    cat <<EOF
SHADOW_GUEST_START_APP_ID=rust-demo
SHADOW_GUEST_TOUCH_LATENCY_TRACE=1
SHADOW_GUEST_COMPOSITOR_BOOT_SPLASH_DRM=1
SHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH=$rust_surface_width
SHADOW_GUEST_COMPOSITOR_TOPLEVEL_HEIGHT=$rust_surface_height
SHADOW_GUEST_FRAME_PATH=$(pixel_frame_path)
SHADOW_GUEST_FRAME_ARTIFACTS=1
SHADOW_GUEST_FRAME_WRITE_EVERY_FRAME=1
SHADOW_GUEST_FRAME_CHECKSUM=1
EOF
  )"
  if [[ -n "${PIXEL_TOUCH_LATENCY_RUST_SESSION_ENV-}" ]]; then
    rust_session_env="${rust_session_env}"$'\n'"${PIXEL_TOUCH_LATENCY_RUST_SESSION_ENV}"
  fi
  rust_required_markers="$(
    cat <<'EOF'
[shadow-guest-compositor] touch-app-tap-dispatch
shadow-rust-demo: counter_incremented count=1
shadow-rust-demo: frame_committed counter=1
[shadow-guest-compositor] touch-latency-present
EOF
  )"

  set +e
  env \
    PIXEL_GUEST_RUN_DIR="$run_dir" \
    PIXEL_SYSTEM_BUNDLE_ARTIFACT_DIR="$(pixel_system_bundle_artifact_dir)" \
    PIXEL_GUEST_CONFIG_CLIENT_ENV="$rust_client_env" \
    PIXEL_GUEST_CONFIG_SESSION_ENV="$rust_session_env" \
    PIXEL_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME= \
    PIXEL_GUEST_CLIENT_EXIT_ON_CONFIGURE= \
    PIXEL_GUEST_FRAME_CAPTURE_MODE=off \
    PIXEL_COMPOSITOR_MARKER='[shadow-guest-compositor] presented-frame' \
    PIXEL_CLIENT_MARKER='shadow-rust-demo: frame_committed counter=0' \
    PIXEL_GUEST_REQUIRED_MARKERS="$rust_required_markers" \
    PIXEL_GUEST_EXPECT_CLIENT_PROCESS= \
    PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-120}" \
    PIXEL_GUEST_SESSION_EXIT_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_EXIT_TIMEOUT_SECS:-15}" \
    PIXEL_GUEST_COMPOSITOR_MARKER_TIMEOUT_SECS="${PIXEL_GUEST_COMPOSITOR_MARKER_TIMEOUT_SECS:-45}" \
    PIXEL_GUEST_REQUIRED_MARKER_TIMEOUT_SECS="${PIXEL_GUEST_REQUIRED_MARKER_TIMEOUT_SECS:-$checkpoint_timeout_secs}" \
    PIXEL_RUNTIME_SUMMARY_RENDERER=rust-counter \
    "$SCRIPT_DIR/pixel/pixel_guest_ui_drm.sh" >>"$wrapper_log_path" 2>&1 &
  session_pid="$!"
  set -e

  if ! pixel_wait_for_condition "$checkpoint_timeout_secs" 1 touch_session_output_has_marker "shadow-rust-demo: frame_committed counter=0"; then
    echo "pixel_touch_latency_probe: rust-demo initial frame marker not observed" | tee -a "$wrapper_log_path" >&2
    wait "$session_pid" || true
    exit 1
  fi

  sleep 1
  printf 'inject rust-counter tap panel=%s,%s\n' "$tap_x" "$tap_y" | tee -a "$wrapper_log_path"
  pixel_touchscreen_tap_panel "$serial" "$tap_x" "$tap_y" "$panel_size"

  if ! pixel_wait_for_condition "$checkpoint_timeout_secs" 1 touch_session_output_has_marker "[shadow-guest-compositor] touch-app-tap-dispatch"; then
    echo "pixel_touch_latency_probe: compositor app tap dispatch marker not observed" | tee -a "$wrapper_log_path" >&2
    wait "$session_pid" || true
    exit 1
  fi
  if ! pixel_wait_for_condition "$checkpoint_timeout_secs" 1 touch_session_output_has_marker "shadow-rust-demo: counter_incremented count=1"; then
    echo "pixel_touch_latency_probe: rust-demo counter increment marker not observed" | tee -a "$wrapper_log_path" >&2
    wait "$session_pid" || true
    exit 1
  fi
  if ! pixel_wait_for_condition "$checkpoint_timeout_secs" 1 touch_session_output_has_marker "shadow-rust-demo: frame_committed counter=1"; then
    echo "pixel_touch_latency_probe: rust-demo post-touch frame marker not observed" | tee -a "$wrapper_log_path" >&2
    wait "$session_pid" || true
    exit 1
  fi
  if ! pixel_wait_for_condition "$checkpoint_timeout_secs" 1 touch_session_output_has_marker "[shadow-guest-compositor] touch-latency-present"; then
    echo "pixel_touch_latency_probe: post-touch compositor present marker not observed" | tee -a "$wrapper_log_path" >&2
    wait "$session_pid" || true
    exit 1
  fi

  post_touch_frame_path="$run_dir/shadow-frame.ppm"
  if ! pixel_wait_for_condition "$checkpoint_timeout_secs" 1 touch_session_output_has_post_touch_frame_artifact; then
    echo "pixel_touch_latency_probe: post-touch frame artifact marker not observed" | tee -a "$wrapper_log_path" >&2
    wait "$session_pid" || true
    exit 1
  fi
  pixel_adb "$serial" pull "$(pixel_frame_path)" "$post_touch_frame_path" >>"$wrapper_log_path" 2>&1

  set +e
  wait "$session_pid"
  session_status="$?"
  set -e
  session_pid=""

  python3 "$SCRIPT_DIR/pixel/pixel_runtime_summary.py" \
    "$run_dir" \
    --renderer rust-counter \
    --output "$summary_path"
  write_rust_counter_summary "$post_touch_frame_path"
  printf 'rust counter post-touch frame: %s\n' "$post_touch_frame_path" | tee -a "$wrapper_log_path"
  printf 'pixel touch latency summary: %s\n' "$summary_path"

  if [[ "$session_status" != "0" ]]; then
    exit "$session_status"
  fi
}

if [[ "$probe_app" == "rust-counter" ]]; then
  run_rust_counter_probe
  exit 0
fi

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
  "gpu" \
  "${gpu_profile:-default}" \
  "$panel_size" | tee "$wrapper_log_path"

set +e
env \
  PIXEL_GUEST_RUN_DIR="$run_dir" \
  PIXEL_RUNTIME_APP_PANEL_SIZE="$panel_size" \
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
  --renderer gpu \
  --output "$summary_path"

printf 'pixel touch latency summary: %s\n' "$summary_path"

if [[ "$session_status" != "0" ]]; then
  exit "$session_status"
fi
