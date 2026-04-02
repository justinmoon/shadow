#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
# shellcheck source=./guest_ui_common.sh
source "$SCRIPT_DIR/guest_ui_common.sh"
ensure_bootimg_shell "$@"

EXPECTED_FRAME_CHECKSUM="${SHADOW_GUEST_COUNTER_EXPECTED_CHECKSUM:-dd64a1693b87ade5}"
EXPECTED_FRAME_SIZE="${SHADOW_GUEST_COUNTER_EXPECTED_SIZE:-220x120}"
ENABLE_DRM="${SHADOW_GUEST_COMPOSITOR_ENABLE_DRM:-0}"
if [[ "$ENABLE_DRM" == "1" ]]; then
  DEFAULT_COMPOSITOR_MARKER="[shadow-guest-compositor] presented-frame"
else
  DEFAULT_COMPOSITOR_MARKER="[shadow-guest-compositor] captured-frame checksum=${EXPECTED_FRAME_CHECKSUM} size=${EXPECTED_FRAME_SIZE}"
fi
COMPOSITOR_MARKER="${SHADOW_GUEST_COMPOSITOR_WAIT_FOR:-$DEFAULT_COMPOSITOR_MARKER}"
DEFAULT_CLIENT_MARKER="[shadow-guest-counter] frame-committed checksum=${EXPECTED_FRAME_CHECKSUM} size=${EXPECTED_FRAME_SIZE}"
CLIENT_MARKER="${SHADOW_GUEST_CLIENT_WAIT_FOR:-$DEFAULT_CLIENT_MARKER}"
GUEST_TIMEOUT_SECS="${SHADOW_GUEST_UI_TIMEOUT:-180}"
SHADOW_SESSION_BIN="${SHADOW_SESSION_BIN:-$(build_dir)/shadow-session}"
ADB_WAIT_TIMEOUT="${SHADOW_ADB_WAIT_TIMEOUT:-30}"
ADB_REMOTE_TMP=""
REMOTE_UI_REPO=""
REMOTE_FRAME_COPY=""
LOCAL_FRAME_PATH=""

cleanup() {
  if [[ -n "$ADB_REMOTE_TMP" ]]; then
    remote_shell "rm -rf $(printf '%q' "$ADB_REMOTE_TMP")" >/dev/null 2>&1 || true
  fi
  if [[ -n "$REMOTE_UI_REPO" && "$REMOTE_UI_REPO" == "$(remote_home)/.cache/shadow-guest-ui-"* ]]; then
    remote_shell "rm -rf $(printf '%q' "$REMOTE_UI_REPO")" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

if [[ ! -f "$SHADOW_SESSION_BIN" ]]; then
  "$SCRIPT_DIR/build_shadow_session.sh"
fi

"$SCRIPT_DIR/cf_stock.sh"

INSTANCE="$(active_instance_name)"
ADB_PORT="$(adb_port_for_instance "$INSTANCE")"
ADB_SERIAL="0.0.0.0:${ADB_PORT}"
LOCAL_FRAME_PATH="${SHADOW_GUEST_FRAME_ARTIFACT:-$(build_dir)/guest-ui/instance-${INSTANCE}/shadow-frame.ppm}"

ADB_REMOTE_TMP="$(remote_shell 'mktemp -d "${TMPDIR:-/tmp}/shadow-adb-guest-ui-XXXXXX"')"
REMOTE_FRAME_COPY="${ADB_REMOTE_TMP}/shadow-frame.ppm"
copy_to_remote "$SHADOW_SESSION_BIN" "${ADB_REMOTE_TMP}/shadow-session"

if is_local_host; then
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "cf_guest_ui_smoke: local guest-ui build requires Linux; use a remote host such as hetzner" >&2
    exit 1
  fi

  COMPOSITOR_BIN="$(local_store_bin shadow-compositor-guest shadow-compositor-guest)"
  COUNTER_BIN="$(local_store_bin shadow-counter-guest shadow-counter-guest)"
  copy_to_remote "$COMPOSITOR_BIN" "${ADB_REMOTE_TMP}/shadow-compositor-guest"
  copy_to_remote "$COUNTER_BIN" "${ADB_REMOTE_TMP}/shadow-counter-guest"
else
  REMOTE_UI_REPO="$(sync_remote_guest_ui_tree)"
  COMPOSITOR_BIN="$(remote_store_bin "$REMOTE_UI_REPO" shadow-compositor-guest shadow-compositor-guest)"
  COUNTER_BIN="$(remote_store_bin "$REMOTE_UI_REPO" shadow-counter-guest shadow-counter-guest)"
fi

REMOTE_SCRIPT="$(cat <<EOF
set -euo pipefail
serial=$(printf '%q' "$ADB_SERIAL")
session_src=$(printf '%q' "${ADB_REMOTE_TMP}/shadow-session")
session_dst="/data/local/tmp/shadow-session"
compositor_dst="/data/local/tmp/shadow-compositor-guest"
counter_dst="/data/local/tmp/shadow-counter-guest"
log_path="/data/local/tmp/shadow-session.log"
frame_path="/data/local/tmp/shadow-frame.ppm"
runtime_dir="/data/local/tmp/shadow-runtime"
compositor_marker=$(printf '%q' "$COMPOSITOR_MARKER")
client_marker=$(printf '%q' "$CLIENT_MARKER")
enable_drm=$(printf '%q' "$ENABLE_DRM")
artifact_copy=$(printf '%q' "$REMOTE_FRAME_COPY")

timeout $(printf '%q' "$ADB_WAIT_TIMEOUT") adb -s "\$serial" wait-for-device
adb -s "\$serial" root >/dev/null 2>&1 || true
sleep 2
timeout $(printf '%q' "$ADB_WAIT_TIMEOUT") adb -s "\$serial" wait-for-device
adb -s "\$serial" push "\$session_src" "\$session_dst" >/dev/null
adb -s "\$serial" push "$(printf '%q' "$COMPOSITOR_BIN")" "\$compositor_dst" >/dev/null
adb -s "\$serial" push "$(printf '%q' "$COUNTER_BIN")" "\$counter_dst" >/dev/null
adb -s "\$serial" shell chmod 0755 "\$session_dst" "\$compositor_dst" "\$counter_dst"
if [[ "\$enable_drm" == "1" ]]; then
  adb -s "\$serial" shell stop surfaceflinger || true
  adb -s "\$serial" shell stop bootanim || true
  adb -s "\$serial" shell stop vendor.hwcomposer-3 || true
  sleep 2
  timeout $(printf '%q' "$ADB_WAIT_TIMEOUT") adb -s "\$serial" wait-for-device || true
fi
adb -s "\$serial" shell 'setenforce 0 >/dev/null 2>&1 || true'
adb -s "\$serial" shell "rm -rf \$runtime_dir && mkdir -p \$runtime_dir && chmod 700 \$runtime_dir && rm -f \$log_path \$frame_path"
if [[ "\$enable_drm" == "1" ]]; then
  drm_env='SHADOW_GUEST_COMPOSITOR_ENABLE_DRM=1 '
else
  drm_env=''
fi
set +e
output="\$(adb -s "\$serial" shell "env SHADOW_SESSION_MODE=guest-ui SHADOW_RUNTIME_DIR=\$runtime_dir SHADOW_GUEST_COMPOSITOR_BIN=\$compositor_dst SHADOW_GUEST_CLIENT=\$counter_dst SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME=1 SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE=1 SHADOW_GUEST_COUNTER_LINGER_MS=500 \${drm_env}SHADOW_GUEST_FRAME_PATH=\$frame_path RUST_LOG=shadow_compositor_guest=info,shadow_counter_guest=info,smithay=warn \$session_dst" 2>&1)"
command_status="\$?"
set -e
printf '%s\n' "\$output"
if [[ "\$command_status" -eq 0 ]] && printf '%s\n' "\$output" | grep -Fq "\$compositor_marker" && printf '%s\n' "\$output" | grep -Fq "\$client_marker"; then
  adb -s "\$serial" pull "\$frame_path" "\$artifact_copy" >/dev/null
  exit 0
fi
exit 1
EOF
)"

printf 'Launching guest UI via adb on instance %s (%s)\n' "$INSTANCE" "$ADB_SERIAL"
remote_nix_bash "$REMOTE_SCRIPT"
mkdir -p "$(dirname "$LOCAL_FRAME_PATH")"
if is_local_host; then
  cp "$REMOTE_FRAME_COPY" "$LOCAL_FRAME_PATH"
else
  scp_retry "${REMOTE_HOST}:$REMOTE_FRAME_COPY" "$LOCAL_FRAME_PATH"
fi
printf 'Saved guest frame artifact to %s\n' "$LOCAL_FRAME_PATH"
