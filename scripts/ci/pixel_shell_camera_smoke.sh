#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./pixel_camera_runtime_common.sh
source "$SCRIPT_DIR/lib/pixel_camera_runtime_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
run_dir="$(pixel_prepare_named_run_dir "$(pixel_shell_runs_dir)")"
launcher_args=(--app camera)
render_latency_budget_ms="${PIXEL_SHELL_CAMERA_RENDER_LATENCY_BUDGET_MS:-12000}"
preview_run_log=""
preview_broker_log_path=""
preview_session_output_path=""
preview_logcat_path=""
capture_run_log=""
capture_broker_log_path=""
capture_session_output_path=""
capture_logcat_path=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --run-only)
        launcher_args=(--run-only "${launcher_args[@]}")
        shift
        ;;
      *)
        echo "pixel_shell_camera_smoke: unsupported argument $1" >&2
        exit 64
        ;;
    esac
  done
}

parse_args "$@"

dump_run_log() {
  local path="$1"
  if [[ -f "$path" ]]; then
    printf '\n== pixel-shell-camera-smoke log ==\n' >&2
    sed -n '1,260p' "$path" >&2
  fi
}

cleanup() {
  pixel_stop_shadow_session_best_effort "$serial"
  pixel_restore_android_best_effort "$serial" 60
}

trap cleanup EXIT

pixel_stop_shadow_session_best_effort "$serial"
pixel_restore_android_best_effort "$serial" 60

capture_launcher_args=("${launcher_args[@]}")
if [[ " ${launcher_args[*]} " != *" --run-only "* ]]; then
  capture_launcher_args=(--run-only "${capture_launcher_args[@]}")
fi

run_camera_session() {
  local label="$1"
  local auto_click_target="$2"
  local required_marker="$3"
  local out_run_log_var="$4"
  local out_broker_log_var="$5"
  local out_session_output_var="$6"
  local out_logcat_var="$7"
  local run_log_path="$run_dir/pixel-shell-camera-${label}.log"
  local broker_log_path="$run_dir/shadow-camera-provider-host-serve-${label}.log"
  local -a step_launcher_args=("${@:8}")
  local session_output_path=""
  local logcat_path=""

  pixel_stop_shadow_session_best_effort "$serial"
  pixel_restore_android_best_effort "$serial" 60

  (
    cd "$REPO_ROOT"
    PIXEL_SERIAL="$serial" \
    PIXEL_SHELL_EXTRA_SESSION_ENV="SHADOW_GUEST_FRAME_CHECKSUM=1" \
    PIXEL_SHELL_EXTRA_GUEST_CLIENT_ENV="SHADOW_BLITZ_RUNTIME_AUTO_CLICK_TARGET=$auto_click_target" \
    PIXEL_SHELL_EXTRA_REQUIRED_MARKERS="$required_marker" \
    PIXEL_GUEST_REQUIRED_MARKER_TIMEOUT_SECS="${PIXEL_GUEST_REQUIRED_MARKER_TIMEOUT_SECS:-60}" \
    PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS="${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS:-10000}" \
    PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-90}" \
      "$SCRIPT_DIR/pixel/pixel_shell_drm.sh" "${step_launcher_args[@]}"
  ) >"$run_log_path" 2>&1 || {
    dump_run_log "$run_log_path"
    exit 1
  }

  session_output_path="$(
    RUN_LOG="$run_log_path" python3 - <<'PY'
import json
import os
import re
import sys

log = open(os.environ["RUN_LOG"], "r", encoding="utf-8").read()
matches = re.findall(r'\{\n(?:.*\n)*?\}', log)
for block in reversed(matches):
    try:
        data = json.loads(block)
    except json.JSONDecodeError:
        continue
    run_dir = data.get("run_dir")
    if run_dir:
        print(os.path.join(run_dir, "session-output.txt"))
        break
else:
    raise SystemExit("pixel-shell-camera-smoke: failed to locate run_dir in shell log")
PY
  )"

  logcat_path="$(dirname "$session_output_path")/logcat.txt"
  pixel_root_shell "$serial" "cat '$(pixel_camera_runtime_daemon_log_path)' 2>/dev/null || true" >"$broker_log_path"

  printf -v "$out_run_log_var" '%s' "$run_log_path"
  printf -v "$out_broker_log_var" '%s' "$broker_log_path"
  printf -v "$out_session_output_var" '%s' "$session_output_path"
  printf -v "$out_logcat_var" '%s' "$logcat_path"
}

run_camera_session \
  preview \
  preview-toggle \
  'runtime-event-dispatched source=auto type=click target=preview-toggle' \
  preview_run_log \
  preview_broker_log_path \
  preview_session_output_path \
  preview_logcat_path \
  "${launcher_args[@]}"

run_camera_session \
  capture \
  capture \
  'runtime-event-dispatched source=auto type=click target=capture' \
  capture_run_log \
  capture_broker_log_path \
  capture_session_output_path \
  capture_logcat_path \
  "${capture_launcher_args[@]}"

PREVIEW_SESSION_OUTPUT_PATH="$preview_session_output_path" \
PREVIEW_LOGCAT_PATH="$preview_logcat_path" \
PREVIEW_BROKER_LOG_PATH="$preview_broker_log_path" \
CAPTURE_SESSION_OUTPUT_PATH="$capture_session_output_path" \
CAPTURE_LOGCAT_PATH="$capture_logcat_path" \
CAPTURE_BROKER_LOG_PATH="$capture_broker_log_path" \
SERIAL="$serial" \
PREVIEW_RUN_LOG="$preview_run_log" \
CAPTURE_RUN_LOG="$capture_run_log" \
RENDER_LATENCY_BUDGET_MS="$render_latency_budget_ms" \
python3 - <<'PY'
import json
import os
import re

preview_session_output = open(os.environ["PREVIEW_SESSION_OUTPUT_PATH"], "r", encoding="utf-8").read()
preview_logcat = open(os.environ["PREVIEW_LOGCAT_PATH"], "r", encoding="utf-8").read()
preview_broker_log = open(os.environ["PREVIEW_BROKER_LOG_PATH"], "r", encoding="utf-8").read()
capture_session_output = open(os.environ["CAPTURE_SESSION_OUTPUT_PATH"], "r", encoding="utf-8").read()
capture_logcat = open(os.environ["CAPTURE_LOGCAT_PATH"], "r", encoding="utf-8").read()
capture_broker_log = open(os.environ["CAPTURE_BROKER_LOG_PATH"], "r", encoding="utf-8").read()
render_latency_budget_ms = int(os.environ["RENDER_LATENCY_BUDGET_MS"])
preview_session_lines = preview_session_output.splitlines()
capture_session_lines = capture_session_output.splitlines()

def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"pixel-shell-camera-smoke: {message}")

def line_index_after(lines: list[str], start: int, needle: str) -> int | None:
    for index, line in enumerate(lines[start:], start):
        if needle in line:
            return index
    return None

def line_index_matching_after(lines: list[str], start: int, pattern: str) -> int | None:
    regex = re.compile(pattern)
    for index, line in enumerate(lines[start:], start):
        if regex.search(line):
            return index
    return None

def line_regex_group(lines: list[str], line_index: int | None, pattern: str, group: int = 1) -> str | None:
    if line_index is None:
        return None
    match = re.search(pattern, lines[line_index])
    if not match:
        return None
    return match.group(group)

def runtime_offset_ms_at(lines: list[str], line_index: int) -> int | None:
    if line_index is None:
        return None
    match = re.search(r"\+\s*(\d+)ms\]", lines[line_index])
    if not match:
        return None
    return int(match.group(1))

preview_click_line_index = line_index_after(
    preview_session_lines,
    0,
    "runtime-event-dispatched source=auto type=click target=preview-toggle",
)
expect(preview_click_line_index is not None, "missing auto preview click dispatch marker")
expect(
    "[shadow-guest-compositor] surface-app-tracked app=camera" in preview_session_output,
    "camera app was not tracked by the guest compositor during preview proof",
)
expect(
    preview_broker_log.count("socket-server-accepted") >= 2,
    f"expected camera broker list+preview requests, got log: {preview_broker_log!r}",
)
expect(
    "GCH_CameraDeviceSession: Create: Created a device session for camera 0" in preview_logcat,
    "missing live preview camera device-session logcat marker",
)

preview_complete_line_index = line_index_after(
    preview_session_lines,
    preview_click_line_index + 1,
    "[shadow-runtime-camera] camera-preview-live",
)
expect(preview_complete_line_index is not None, "missing preview completion marker")
expect(
    "isMock=false" in preview_session_lines[preview_complete_line_index],
    "preview completion marker reported a mock frame",
)

preview_error_line_index = line_index_after(
    preview_session_lines,
    preview_complete_line_index + 1,
    "[shadow-runtime-camera] camera-preview-error",
)
expect(
    preview_error_line_index is None or preview_error_line_index > preview_complete_line_index,
    "preview error was reported before preview completed",
)

preview_home_frame_line_index = line_index_after(
    preview_session_lines,
    0,
    "[shadow-guest-compositor] shell-home-frame",
)
preview_home_frame_checksum = line_regex_group(
    preview_session_lines,
    preview_home_frame_line_index,
    r"checksum=([0-9a-f]+)",
)
expect(preview_home_frame_checksum is not None, "missing shell home frame checksum before preview")

preview_frame_after_click_line_index = line_index_matching_after(
    preview_session_lines,
    preview_click_line_index + 1,
    r"\[shadow-guest-compositor\] captured-frame checksum=",
)
preview_frame_after_click_checksum = line_regex_group(
    preview_session_lines,
    preview_frame_after_click_line_index,
    r"checksum=([0-9a-f]+)",
)
expect(
    preview_frame_after_click_checksum is not None,
    "missing compositor captured-frame checksum after preview click",
)
expect(
    preview_frame_after_click_checksum != preview_home_frame_checksum,
    "preview click did not change the composed frame checksum",
)

preview_click_offset_ms = runtime_offset_ms_at(preview_session_lines, preview_click_line_index)
expect(preview_click_offset_ms is not None, "missing runtime preview click timing marker")

capture_click_line_index = line_index_after(
    capture_session_lines,
    0,
    "runtime-event-dispatched source=auto type=click target=capture",
)
expect(capture_click_line_index is not None, "missing auto capture click dispatch marker")
expect(
    "[shadow-guest-compositor] surface-app-tracked app=camera" in capture_session_output,
    "camera app was not tracked by the guest compositor during capture proof",
)
expect(
    capture_broker_log.count("socket-server-accepted") >= 2,
    f"expected camera broker list+capture requests, got log: {capture_broker_log!r}",
)
expect(
    "GCH_CameraDeviceSession: Create: Created a device session for camera 0" in capture_logcat,
    "missing live camera capture device-session logcat marker",
)
expect(
    "run-app-error:" not in capture_session_output,
    "runtime app exited with an error before smoke completion",
)

capture_complete_line_index = line_index_after(
    capture_session_lines,
    capture_click_line_index + 1,
    "[shadow-runtime-camera] camera-capture-complete",
)
expect(capture_complete_line_index is not None, "missing camera capture completion marker")
expect(
    "isMock=false" in capture_session_lines[capture_complete_line_index],
    "camera capture completion marker reported a mock frame",
)

dirty_render_line_index = line_index_after(
    capture_session_lines,
    capture_complete_line_index + 1,
    "runtime-dirty-render-applied",
)

click_offset_ms = runtime_offset_ms_at(capture_session_lines, capture_click_line_index)
dirty_render_offset_ms = runtime_offset_ms_at(capture_session_lines, dirty_render_line_index)
expect(click_offset_ms is not None, "missing runtime auto capture click timing marker")
expect(
    dirty_render_offset_ms is not None,
    "missing runtime dirty render marker after live capture completion",
)
expect(
    dirty_render_offset_ms >= click_offset_ms,
    "dirty render marker appeared before the capture click marker",
)
expect(
    dirty_render_offset_ms - click_offset_ms <= render_latency_budget_ms,
    f"capture result did not render within {render_latency_budget_ms}ms (delta={dirty_render_offset_ms - click_offset_ms}ms)",
)

print(
    json.dumps(
        {
            "captureBrokerLog": os.environ["CAPTURE_BROKER_LOG_PATH"],
            "captureLog": os.environ["CAPTURE_RUN_LOG"],
            "previewBrokerLog": os.environ["PREVIEW_BROKER_LOG_PATH"],
            "previewLog": os.environ["PREVIEW_RUN_LOG"],
            "previewFrameChecksum": preview_frame_after_click_checksum,
            "previewHomeFrameChecksum": preview_home_frame_checksum,
            "renderLatencyBudgetMs": render_latency_budget_ms,
            "renderLatencyDeltaMs": dirty_render_offset_ms - click_offset_ms,
            "result": "pixel-shell-camera-ok",
            "serial": os.environ["SERIAL"],
            "captureSessionOutput": os.environ["CAPTURE_SESSION_OUTPUT_PATH"],
            "previewSessionOutput": os.environ["PREVIEW_SESSION_OUTPUT_PATH"],
        },
        indent=2,
    )
)
PY
