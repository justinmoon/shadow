#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
run_dir="$(pixel_prepare_named_run_dir "$(pixel_drm_runs_dir)")"
logcat_path="$run_dir/logcat.txt"
session_output_path="$run_dir/session-output.txt"
status_path="$run_dir/status.json"
drm_artifact="$(pixel_artifact_path drm-rect)"
session_artifact="$(pixel_session_artifact)"
restore_android="${PIXEL_TAKEOVER_RESTORE_ANDROID-1}"
restore_delay_secs="${PIXEL_TAKEOVER_RESTORE_DELAY_SECS-}"
drm_hold_secs="${SHADOW_DRM_RECT_HOLD_SECS-}"
logcat_pid=""

cleanup() {
  if [[ -n "${logcat_pid:-}" ]]; then
    kill "$logcat_pid" >/dev/null 2>&1 || true
    wait "$logcat_pid" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

build_device_binary() {
  local attr binary out_link output_path file_output
  attr="$1"
  binary="$2"
  out_link="$(pixel_dir)/${binary}-result"
  output_path="$(pixel_artifact_path "$binary")"

  rm -f "$out_link"
  nix build "$(repo_root)#${attr}" --out-link "$out_link"
  cp "$out_link/bin/$binary" "$output_path"
  chmod 0755 "$output_path"

  file_output="$(file "$output_path")"
  printf '%s\n' "$file_output"
  if [[ "$file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_drm_rect: expected an arm64 binary, got: $file_output" >&2
    exit 1
  fi
  if [[ "$file_output" == *"dynamically linked"* ]]; then
    echo "pixel_drm_rect: expected a static binary, got a dynamic one: $file_output" >&2
    exit 1
  fi
}

if [[ ! -f "$session_artifact" ]]; then
  build_device_binary shadow-session-device shadow-session
fi

build_device_binary drm-rect-device drm-rect

pixel_adb "$serial" push "$session_artifact" /data/local/tmp/shadow-session >/dev/null
pixel_adb "$serial" push "$drm_artifact" /data/local/tmp/drm-rect >/dev/null
pixel_adb "$serial" shell chmod 0755 /data/local/tmp/shadow-session /data/local/tmp/drm-rect

pixel_capture_props "$serial" "$run_dir/device-props.txt"
pixel_adb "$serial" logcat -c || true
pixel_adb "$serial" logcat -v threadtime >"$logcat_path" 2>&1 &
logcat_pid="$!"

phone_script="$(
  cat <<EOF
$(pixel_takeover_stop_services_script)
${drm_hold_secs:+SHADOW_DRM_RECT_HOLD_SECS=$drm_hold_secs }SHADOW_SESSION_MODE=drm-rect SHADOW_DRM_RECT_BIN=/data/local/tmp/drm-rect /data/local/tmp/shadow-session
status=\$?
${restore_delay_secs:+sleep $restore_delay_secs}
$(if [[ -n "$restore_android" ]]; then pixel_takeover_start_services_script; fi)
exit \$status
EOF
)"

set +e
session_output="$(pixel_root_shell "$serial" "$phone_script" 2>&1)"
session_status="$?"
set -e

printf '%s\n' "$session_output" | tee "$session_output_path"

sleep 3
cleanup
logcat_pid=""

drm_success=false
if [[ "$session_status" -eq 0 ]] && grep -Fq "[shadow-drm] success" "$session_output_path"; then
  drm_success=true
elif [[ -z "$restore_android" ]] && grep -Fq "[shadow-drm] success" "$session_output_path"; then
  drm_success=true
fi

pixel_write_status_json "$status_path" \
  run_dir="$run_dir" \
  session_exit="$session_status" \
  android_restored="$([[ -n "$restore_android" ]] && echo true || echo false)" \
  drm_success="$drm_success"

cat "$status_path"

if [[ "$drm_success" != true ]]; then
  exit 1
fi

printf 'Pixel DRM takeover succeeded: %s\n' "$run_dir"
