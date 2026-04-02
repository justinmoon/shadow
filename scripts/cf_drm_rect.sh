#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

DRM_RECT_BIN="${DRM_RECT_BIN:-$(build_dir)/drm-rect}"
SHADOW_SESSION_BIN="${SHADOW_SESSION_BIN:-$(build_dir)/shadow-session}"
ADB_REMOTE_TMP=""
TAKEOVER_DRM="${SHADOW_GUEST_TAKEOVER_DRM:-1}"
DRM_RECT_MARKER="${SHADOW_DRM_RECT_WAIT_FOR:-[shadow-drm] success}"
DRM_RECT_SESSION_TIMEOUT="${SHADOW_DRM_RECT_SESSION_TIMEOUT:-45}"
ADB_WAIT_TIMEOUT="${SHADOW_ADB_WAIT_TIMEOUT:-30}"

cleanup() {
  if [[ -n "$ADB_REMOTE_TMP" ]]; then
    remote_shell "rm -rf $(printf '%q' "$ADB_REMOTE_TMP")" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

if [[ ! -f "$DRM_RECT_BIN" ]]; then
  "$SCRIPT_DIR/build_drm_rect.sh"
fi

if [[ ! -f "$SHADOW_SESSION_BIN" ]]; then
  "$SCRIPT_DIR/build_shadow_session.sh"
fi

"$SCRIPT_DIR/cf_stock.sh"

INSTANCE="$(active_instance_name)"
ADB_PORT="$(adb_port_for_instance "$INSTANCE")"
ADB_SERIAL="0.0.0.0:${ADB_PORT}"

ADB_REMOTE_TMP="$(remote_shell 'mktemp -d "${TMPDIR:-/tmp}/shadow-adb-drm-rect-XXXXXX"')"
copy_to_remote "$SHADOW_SESSION_BIN" "${ADB_REMOTE_TMP}/shadow-session"
copy_to_remote "$DRM_RECT_BIN" "${ADB_REMOTE_TMP}/drm-rect"

REMOTE_SCRIPT="$(cat <<EOF
set -euo pipefail
serial="$(printf '%q' "$ADB_SERIAL")"
timeout $(printf '%q' "$ADB_WAIT_TIMEOUT") adb -s "\$serial" wait-for-device
adb -s "\$serial" root >/dev/null 2>&1 || true
sleep 2
timeout $(printf '%q' "$ADB_WAIT_TIMEOUT") adb -s "\$serial" wait-for-device
adb -s "\$serial" push "$(printf '%q' "${ADB_REMOTE_TMP}/shadow-session")" /data/local/tmp/shadow-session >/dev/null
adb -s "\$serial" push "$(printf '%q' "${ADB_REMOTE_TMP}/drm-rect")" /data/local/tmp/drm-rect >/dev/null
adb -s "\$serial" shell chmod 0755 /data/local/tmp/shadow-session /data/local/tmp/drm-rect
if [[ "$(printf '%q' "$TAKEOVER_DRM")" == "1" ]]; then
  adb -s "\$serial" shell stop surfaceflinger || true
  adb -s "\$serial" shell stop bootanim || true
  adb -s "\$serial" shell stop vendor.hwcomposer-3 || true
  sleep 2
  timeout $(printf '%q' "$ADB_WAIT_TIMEOUT") adb -s "\$serial" wait-for-device || true
fi
adb -s "\$serial" shell 'setenforce 0 >/dev/null 2>&1 || true'
set +e
output="\$(timeout $(printf '%q' "$DRM_RECT_SESSION_TIMEOUT") adb -s "\$serial" shell 'SHADOW_SESSION_MODE=drm-rect SHADOW_DRM_RECT_BIN=/data/local/tmp/drm-rect /data/local/tmp/shadow-session' 2>&1)"
command_status="\$?"
set -e
printf '%s\n' "\$output"
if printf '%s\n' "\$output" | grep -Fq "$(printf '%q' "$DRM_RECT_MARKER")"; then
  exit 0
fi
exit "\$command_status"
EOF
)"

printf 'Launching drm_rect via adb on instance %s (%s)\n' "$INSTANCE" "$ADB_SERIAL"
remote_nix_bash "$REMOTE_SCRIPT"
