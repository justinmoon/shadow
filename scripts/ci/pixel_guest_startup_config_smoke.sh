#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pixel-guest-startup.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

config_path="$tmp_dir/guest-startup.json"
launch_env_path="$tmp_dir/launch-env.txt"
overlay_launch_env_path="$tmp_dir/overlay-launch-env.txt"
base_session_env=$'SHADOW_GUEST_START_APP_ID=shell\nSHADOW_GUEST_SHELL_START_APP_ID=timeline\nSHADOW_GUEST_CLIENT=/runtime/alt-client\nSHADOW_GUEST_COMPOSITOR_BIN=/runtime/alt-compositor\nSHADOW_GUEST_COMPOSITOR_BOOT_SPLASH_DRM=1\nSHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH=1080\nSHADOW_GUEST_COMPOSITOR_TOPLEVEL_HEIGHT=2280\nSHADOW_SYSTEM_BINARY_PATH=/runtime/shadow-system\nSHADOW_SESSION_APP_PROFILE=pixel-shell\nSHADOW_RUNTIME_DIR_MODE=0711\nSHADOW_COMPOSITOR_CONTROL_SOCKET_MODE=0666\nSHADOW_TIMELINE_APP_BUNDLE_PATH=/runtime/timeline.js'
overlay_session_env=$'SHADOW_GUEST_COMPOSITOR_BACKGROUND_APP_LIMIT=2\nSHADOW_GUEST_COMPOSITOR_GPU_PROFILE_TRACE=1'
session_env_for_config="$base_session_env"
while IFS= read -r env_line; do
  [[ -n "$env_line" ]] || continue
  session_env_for_config="${session_env_for_config}"$'\n'"$env_line"
done < <(pixel_guest_session_overlay_config_env_lines "$overlay_session_env")

if [[ "$(pixel_guest_startup_config_dst run-token)" != "/data/local/tmp/shadow-guest-startup-run-token.json" ]]; then
  echo "pixel_guest_startup_config_smoke: tokenized startup config path mismatch" >&2
  exit 1
fi

pixel_write_guest_ui_startup_config \
  "$config_path" \
  "/data/local/tmp/shadow-runtime" \
  "/data/local/tmp/shadow-runtime-gnu/run-shadow-blitz-demo" \
  "1" \
  "" \
  "" \
  $'BASE_CLIENT=alpha\nSHADOW_RUNTIME_APP_BUNDLE_PATH=/runtime/base.js\nSHADOW_BLITZ_SOFTWARE_KEYBOARD=0' \
  "$session_env_for_config" \
  "/tmp/shadow-frame-test.ppm" \
  "publish"

pixel_guest_session_launch_env_lines \
  "$base_session_env" \
  >"$launch_env_path"
pixel_guest_session_overlay_passthrough_env_lines "$overlay_session_env" >"$overlay_launch_env_path"

python3 - "$config_path" "$launch_env_path" "$overlay_launch_env_path" <<'PY'
import json
import sys

config_path, launch_env_path, overlay_launch_env_path = sys.argv[1:4]
with open(config_path, encoding="utf-8") as handle:
    data = json.load(handle)
with open(launch_env_path, encoding="utf-8") as handle:
    launch_env_lines = [line.strip() for line in handle if line.strip()]
with open(overlay_launch_env_path, encoding="utf-8") as handle:
    overlay_launch_env_lines = [line.strip() for line in handle if line.strip()]

assert data["schemaVersion"] == 1, data
assert data["startup"] == {"mode": "shell", "shellStartAppId": "timeline"}, data
assert data["client"]["appClientPath"] == "/runtime/alt-client", data
assert data["client"]["runtimeDir"] == "/data/local/tmp/shadow-runtime", data
assert data["client"]["systemBinaryPath"] == "/runtime/shadow-system", data
assert data["client"]["lingerMs"] == 500, data
assert data["client"]["envAssignments"] == [
    {"key": "BASE_CLIENT", "value": "alpha"},
    {"key": "SHADOW_RUNTIME_APP_BUNDLE_PATH", "value": "/runtime/base.js"},
    {"key": "SHADOW_BLITZ_SOFTWARE_KEYBOARD", "value": "0"},
], data
assert data["compositor"]["transport"] == "direct", data
assert data["compositor"]["enableDrm"] is True, data
assert data["compositor"]["exitOnFirstFrame"] is True, data
assert data["compositor"]["bootSplashDrm"] is True, data
assert data["compositor"]["backgroundAppResidentLimit"] == 2, data
assert data["compositor"]["softwareKeyboardEnabled"] is False, data
assert data["compositor"]["frameCapture"] == {
    "mode": "first-frame",
    "artifactPath": "/tmp/shadow-frame-test.ppm",
}, data
assert data["window"] == {"surfaceWidth": 1080, "surfaceHeight": 2280}, data
assert launch_env_lines == [
    "SHADOW_GUEST_COMPOSITOR_BIN=/runtime/alt-compositor",
    "SHADOW_SESSION_APP_PROFILE=pixel-shell",
    "SHADOW_RUNTIME_DIR_MODE=0711",
    "SHADOW_COMPOSITOR_CONTROL_SOCKET_MODE=0666",
    "SHADOW_TIMELINE_APP_BUNDLE_PATH=/runtime/timeline.js",
], launch_env_lines
assert overlay_launch_env_lines == [
    "SHADOW_GUEST_COMPOSITOR_GPU_PROFILE_TRACE=1",
], overlay_launch_env_lines
PY
