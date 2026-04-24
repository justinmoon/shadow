#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pixel-audio-backend.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

startup_config_path="$tmp_dir/guest-startup.json"
run_config_path="$tmp_dir/guest-run-config.json"
materialized_path="$tmp_dir/guest-run-config.env"
runtime_services_json="$(PIXEL_RUNTIME_ENABLE_LINUX_AUDIO=1 pixel_runtime_app_services_json)"
client_env=$(
  cat <<EOF
SHADOW_RUNTIME_AUDIO_BACKEND=memory
SHADOW_RUNTIME_APP_BUNDLE_PATH=$(pixel_runtime_app_bundle_dst)
$(pixel_system_env_lines)
$(pixel_runtime_linux_user_env_lines)
EOF
)
session_env=$(
  cat <<EOF
SHADOW_SYSTEM_BINARY_PATH=$(pixel_system_binary_dst)
EOF
)

pixel_write_guest_ui_startup_config \
  "$startup_config_path" \
  "$(pixel_runtime_dir)" \
  "$(pixel_guest_client_dst)" \
  "" \
  "1" \
  "" \
  "$client_env" \
  "$session_env" \
  "$(pixel_frame_path)" \
  "off" \
  "$runtime_services_json"

pixel_write_guest_run_config \
  "$run_config_path" \
  "$startup_config_path" \
  "$(pixel_system_bundle_artifact_dir)" \
  "$(pixel_runtime_app_asset_artifact_dir)" \
  "$(pixel_runtime_app_bundle_artifact)" \
  "" \
  "" \
  "" \
  "" \
  "$(pixel_runtime_precreate_dirs_lines)" \
  "" \
  "" \
  "" \
  "" \
  "1" \
  "1" \
  "1" \
  "1" \
  "" \
  "" \
  "" \
  "" \
  "" \
  "" \
  "" \
  "1" \
  "1" \
  "0" \
  "0" \
  ""
pixel_materialize_guest_run_config "$run_config_path" "$materialized_path"

python3 - "$startup_config_path" "$run_config_path" <<'PY'
import json
import sys

startup_config_path, run_config_path = sys.argv[1:3]
with open(startup_config_path, encoding="utf-8") as handle:
    startup = json.load(handle)
with open(run_config_path, encoding="utf-8") as handle:
    run_config = json.load(handle)

assert startup["services"] == {
    "audioBackend": "linux_bridge",
    "nostrDbPath": "/data/local/tmp/shadow-runtime/runtime-nostr.sqlite3",
    "nostrServiceSocket": "/data/local/tmp/shadow-runtime/runtime-nostr.sock",
}, startup
assert not any(
    assignment["key"] == "SHADOW_RUNTIME_AUDIO_BACKEND"
    for assignment in startup["client"]["envAssignments"]
), startup
assert run_config["services"]["audioBackend"] == "linux_bridge", run_config
assert not any(
    assignment["key"] == "SHADOW_RUNTIME_AUDIO_BACKEND"
    for assignment in run_config["client"]["envAssignments"]
), run_config
PY

(
  set -euo pipefail
  # shellcheck source=/dev/null
  source "$materialized_path"

  [[ "$pixel_guest_run_config_startup_config_path" == "$run_config_path" ]]
  [[ "$pixel_guest_run_config_runtime_dir" == "$(pixel_runtime_dir)" ]]
  [[ "$pixel_guest_run_config_client_launch_path" == "$(pixel_guest_client_dst)" ]]
)

printf 'pixel_audio_backend_config_smoke: ok\n'
