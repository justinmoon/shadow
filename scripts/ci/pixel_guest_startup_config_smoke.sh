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
run_config_path="$tmp_dir/guest-run-config.json"
materialized_path="$tmp_dir/guest-run-config.env"
manual_run_config_path="$tmp_dir/manual-guest-run-config.json"
manual_materialized_path="$tmp_dir/manual-guest-run-config.env"
alias_run_config_path="$tmp_dir/alias-guest-run-config.json"
alias_materialized_path="$tmp_dir/alias-guest-run-config.env"
legacy_run_config_path="$tmp_dir/legacy-guest-run-config.json"
legacy_materialized_path="$tmp_dir/legacy-guest-run-config.env"
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
combined_launch_env="$(cat "$launch_env_path")"
overlay_launch_env="$(cat "$overlay_launch_env_path")"
if [[ -n "$overlay_launch_env" ]]; then
  if [[ -n "$combined_launch_env" ]]; then
    combined_launch_env="${combined_launch_env}"$'\n'"$overlay_launch_env"
  else
    combined_launch_env="$overlay_launch_env"
  fi
fi

pixel_write_guest_run_config \
  "$run_config_path" \
  "$config_path" \
  "" \
  "" \
  "" \
  "$combined_launch_env" \
  $'OVERLAY_CLIENT=debug\nSHADOW_RUNTIME_DEBUG=1' \
  $'required-marker-1\nrequired-marker-2' \
  'forbidden-marker-1' \
  $'/runtime/home\n/runtime/cache' \
  'echo pre' \
  'echo post' \
  '[shadow-guest-compositor] presented-frame' \
  'runtime-document-ready' \
  "" \
  "1" \
  "1" \
  "" \
  "25" \
  "30" \
  "40" \
  "50" \
  "60" \
  "70" \
  "80" \
  "0" \
  "0" \
  "1" \
  "0" \
  "" \
  ""
pixel_materialize_guest_run_config "$run_config_path" "$materialized_path"

cat >"$manual_run_config_path" <<'EOF'
{
  "schemaVersion": 1,
  "startup": {
    "mode": "client"
  },
  "client": {
    "appClientPath": "/manual/client",
    "runtimeDir": "/manual/runtime"
  },
  "compositor": {
    "frameCapture": {
      "mode": "off",
      "artifactPath": "/manual/frame.ppm"
    }
  },
  "session": {
    "launchEnvAssignments": [
      { "key": "A", "value": "1" }
    ],
    "clientEnvOverlayAssignments": [
      { "key": "B", "value": "2" }
    ]
  },
  "verify": {
    "expectClientProcess": true
  },
  "takeover": {
    "restoreAndroid": true,
    "restoreInSession": true,
    "stopAllocator": true
  }
}
EOF
pixel_materialize_guest_run_config "$manual_run_config_path" "$manual_materialized_path"

cat >"$alias_run_config_path" <<'EOF'
{
  "schemaVersion": 1,
  "startup": {
    "mode": "client"
  },
  "client": {
    "appClientPath": "/alias/client",
    "runtimeDir": "/alias/runtime"
  },
  "compositor": {
    "frameCapture": {
      "mode": "every_frame",
      "artifactPath": "/alias/frame.ppm"
    }
  }
}
EOF
pixel_materialize_guest_run_config "$alias_run_config_path" "$alias_materialized_path"

cat >"$legacy_run_config_path" <<'EOF'
{
  "schemaVersion": 1,
  "startup": {
    "mode": "client"
  },
  "client": {
    "appClientPath": "/legacy/client"
  },
  "runtime": {
    "runtimeDir": "/legacy/runtime"
  },
  "compositor": {
    "frameCapture": {
      "enabled": true,
      "writeEveryFrame": true,
      "artifactPath": "/legacy/frame.ppm"
    }
  }
}
EOF
pixel_materialize_guest_run_config "$legacy_run_config_path" "$legacy_materialized_path"

python3 - "$config_path" "$run_config_path" "$launch_env_path" "$overlay_launch_env_path" <<'PY'
import json
import sys

config_path, run_config_path, launch_env_path, overlay_launch_env_path = sys.argv[1:5]
with open(config_path, encoding="utf-8") as handle:
    data = json.load(handle)
with open(run_config_path, encoding="utf-8") as handle:
    run_config = json.load(handle)
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

assert run_config["schemaVersion"] == 1, run_config
assert "startupConfigPath" not in run_config, run_config
assert run_config["startup"] == {"mode": "shell", "shellStartAppId": "timeline"}, run_config
assert run_config["client"]["appClientPath"] == "/runtime/alt-client", run_config
assert run_config["compositor"]["frameCapture"] == {
    "mode": "first-frame",
    "artifactPath": "/tmp/shadow-frame-test.ppm",
}, run_config
assert run_config["session"] == {
    "timeoutSecs": 25,
    "exitTimeoutSecs": 30,
    "launchEnvAssignments": [
        {"key": "SHADOW_GUEST_COMPOSITOR_BIN", "value": "/runtime/alt-compositor"},
        {"key": "SHADOW_SESSION_APP_PROFILE", "value": "pixel-shell"},
        {"key": "SHADOW_RUNTIME_DIR_MODE", "value": "0711"},
        {"key": "SHADOW_COMPOSITOR_CONTROL_SOCKET_MODE", "value": "0666"},
        {"key": "SHADOW_TIMELINE_APP_BUNDLE_PATH", "value": "/runtime/timeline.js"},
        {"key": "SHADOW_GUEST_COMPOSITOR_GPU_PROFILE_TRACE", "value": "1"},
    ],
    "clientEnvOverlayAssignments": [
        {"key": "OVERLAY_CLIENT", "value": "debug"},
        {"key": "SHADOW_RUNTIME_DEBUG", "value": "1"},
    ],
    "precreateDirs": ["/runtime/home", "/runtime/cache"],
    "preSessionDeviceScript": "echo pre",
    "postSessionDeviceScript": "echo post",
}, run_config
assert run_config["verify"] == {
    "compositorMarker": "[shadow-guest-compositor] presented-frame",
    "clientMarker": "runtime-document-ready",
    "requiredMarkers": ["required-marker-1", "required-marker-2"],
    "forbiddenMarkers": ["forbidden-marker-1"],
    "expectCompositorProcess": False,
    "expectClientProcess": True,
    "expectClientMarker": True,
    "requireClientMarker": False,
    "compositorMarkerTimeoutSecs": 40,
    "requiredMarkerTimeoutSecs": 50,
    "frameCheckpointTimeoutSecs": 60,
}, run_config
assert run_config["takeover"] == {
    "restoreAndroid": False,
    "restoreInSession": False,
    "rebootOnRestoreFailure": True,
    "stopAllocator": False,
    "restoreCheckpointTimeoutSecs": 70,
    "restoreRebootTimeoutSecs": 80,
}, run_config
PY

(
  set -euo pipefail
  # shellcheck source=/dev/null
  source "$materialized_path"

  [[ "$pixel_guest_run_config_startup_config_path" == "$run_config_path" ]]
  [[ "$pixel_guest_run_config_runtime_dir" == "/data/local/tmp/shadow-runtime" ]]
  [[ "$pixel_guest_run_config_client_launch_path" == "/runtime/alt-client" ]]
  [[ "$pixel_guest_run_config_frame_capture_mode" == "publish" ]]
  [[ "$pixel_guest_run_config_frame_artifact_path" == "/tmp/shadow-frame-test.ppm" ]]
  [[ "$pixel_guest_run_config_session_timeout_secs" == "25" ]]
  [[ "$pixel_guest_run_config_session_exit_timeout_secs" == "30" ]]
  [[ "$pixel_guest_run_config_session_launch_env" == $'SHADOW_GUEST_COMPOSITOR_BIN=/runtime/alt-compositor\nSHADOW_SESSION_APP_PROFILE=pixel-shell\nSHADOW_RUNTIME_DIR_MODE=0711\nSHADOW_COMPOSITOR_CONTROL_SOCKET_MODE=0666\nSHADOW_TIMELINE_APP_BUNDLE_PATH=/runtime/timeline.js\nSHADOW_GUEST_COMPOSITOR_GPU_PROFILE_TRACE=1' ]]
  [[ "$pixel_guest_run_config_client_env_overlay" == $'OVERLAY_CLIENT=debug\nSHADOW_RUNTIME_DEBUG=1' ]]
  [[ "$pixel_guest_run_config_required_markers" == $'required-marker-1\nrequired-marker-2' ]]
  [[ "$pixel_guest_run_config_forbidden_markers" == "forbidden-marker-1" ]]
  [[ -z "$pixel_guest_run_config_expect_compositor_process" ]]
  [[ "$pixel_guest_run_config_expect_client_process" == "1" ]]
  [[ "$pixel_guest_run_config_expect_client_marker" == "1" ]]
  [[ -z "$pixel_guest_run_config_verify_require_client_marker" ]]
  [[ "$pixel_guest_run_config_compositor_marker_timeout_secs" == "40" ]]
  [[ "$pixel_guest_run_config_required_marker_timeout_secs" == "50" ]]
  [[ "$pixel_guest_run_config_frame_checkpoint_timeout_secs" == "60" ]]
  [[ "$pixel_guest_run_config_restore_checkpoint_timeout_secs" == "70" ]]
  [[ "$pixel_guest_run_config_restore_reboot_timeout_secs" == "80" ]]
  [[ -z "$pixel_guest_run_config_restore_android" ]]
  [[ -z "$pixel_guest_run_config_restore_in_session" ]]
  [[ "$pixel_guest_run_config_reboot_on_restore_failure" == "1" ]]
  [[ -z "$pixel_guest_run_config_stop_allocator" ]]
)

(
  set -euo pipefail
  # shellcheck source=/dev/null
  source "$manual_materialized_path"

  [[ "$pixel_guest_run_config_startup_config_path" == "$manual_run_config_path" ]]
  [[ "$pixel_guest_run_config_runtime_dir" == "/manual/runtime" ]]
  [[ "$pixel_guest_run_config_client_launch_path" == "/manual/client" ]]
  [[ "$pixel_guest_run_config_frame_capture_mode" == "off" ]]
  [[ "$pixel_guest_run_config_frame_artifact_path" == "/manual/frame.ppm" ]]
  [[ "$pixel_guest_run_config_session_launch_env" == "A=1" ]]
  [[ "$pixel_guest_run_config_client_env_overlay" == "B=2" ]]
  [[ "$pixel_guest_run_config_expect_client_process" == "1" ]]
  [[ "$pixel_guest_run_config_restore_android" == "1" ]]
  [[ "$pixel_guest_run_config_restore_in_session" == "1" ]]
  [[ "$pixel_guest_run_config_stop_allocator" == "1" ]]
)

(
  set -euo pipefail
  # shellcheck source=/dev/null
  source "$alias_materialized_path"

  [[ "$pixel_guest_run_config_startup_config_path" == "$alias_run_config_path" ]]
  [[ "$pixel_guest_run_config_frame_capture_mode" == "publish" ]]
  [[ "$pixel_guest_run_config_frame_artifact_path" == "/alias/frame.ppm" ]]
)

(
  set -euo pipefail
  # shellcheck source=/dev/null
  source "$legacy_materialized_path"

  [[ "$pixel_guest_run_config_startup_config_path" == "$legacy_run_config_path" ]]
  [[ "$pixel_guest_run_config_runtime_dir" == "/legacy/runtime" ]]
  [[ "$pixel_guest_run_config_client_launch_path" == "/legacy/client" ]]
  [[ "$pixel_guest_run_config_frame_capture_mode" == "publish" ]]
  [[ "$pixel_guest_run_config_frame_artifact_path" == "/legacy/frame.ppm" ]]
)
