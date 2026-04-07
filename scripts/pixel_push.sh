#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
runtime_host_bundle_artifact_dir="${PIXEL_RUNTIME_HOST_BUNDLE_ARTIFACT_DIR-}"
runtime_app_bundle_artifact="${PIXEL_RUNTIME_APP_BUNDLE_ARTIFACT-}"
runtime_bundle_archive_host=""
runtime_bundle_archive_device=""

cleanup() {
  if [[ -n "$runtime_bundle_archive_host" && -f "$runtime_bundle_archive_host" ]]; then
    rm -f "$runtime_bundle_archive_host"
  fi
}

trap cleanup EXIT

if ! pixel_require_runtime_artifacts; then
  "$SCRIPT_DIR/pixel_build.sh"
fi

printf 'Pushing device artifacts to %s\n' "$serial"
if [[ -n "$runtime_host_bundle_artifact_dir" || -n "$runtime_app_bundle_artifact" ]]; then
  runtime_linux_dir="$(pixel_runtime_linux_dir)"
  printf 'Pushing runtime support to %s\n' "$serial"
  if [[ -n "$runtime_host_bundle_artifact_dir" ]]; then
    runtime_bundle_archive_host="$(mktemp "${TMPDIR:-/tmp}/shadow-runtime-bundle.XXXXXX.tar")"
    runtime_bundle_archive_device="/data/local/tmp/$(basename "$runtime_bundle_archive_host")"
    tar -C "$runtime_host_bundle_artifact_dir" -cf "$runtime_bundle_archive_host" .
    pixel_root_shell "$serial" "rm -rf '$runtime_linux_dir' '$runtime_bundle_archive_device'"
    pixel_adb "$serial" push "$runtime_bundle_archive_host" "$runtime_bundle_archive_device" >/dev/null
    pixel_root_shell "$serial" "mkdir -p '$runtime_linux_dir' && /system/bin/tar -xf '$runtime_bundle_archive_device' -C '$runtime_linux_dir' && chown -R shell:shell '$runtime_linux_dir' && find '$runtime_linux_dir' -type d -exec chmod 0755 {} + && find '$runtime_linux_dir' -type f -exec chmod 0755 {} + && rm -f '$runtime_bundle_archive_device'"
  else
    pixel_root_shell "$serial" "rm -rf '$runtime_linux_dir'"
    pixel_adb "$serial" shell "mkdir -p '$runtime_linux_dir'"
  fi
  if [[ -n "$runtime_app_bundle_artifact" ]]; then
    pixel_adb "$serial" push "$runtime_app_bundle_artifact" "$(pixel_runtime_app_bundle_dst)" >/dev/null
  fi
  pixel_root_shell "$serial" "find '$runtime_linux_dir' -type f -exec chmod 0755 {} +"
  printf 'Pushed runtime helper dir -> %s\n' "$runtime_linux_dir"
  if [[ -n "$runtime_app_bundle_artifact" ]]; then
    printf 'Pushed runtime app bundle -> %s\n' "$(pixel_runtime_app_bundle_dst)"
  fi
fi

pixel_adb "$serial" push "$(pixel_session_artifact)" "$(pixel_session_dst)" >/dev/null
pixel_adb "$serial" push "$(pixel_compositor_artifact)" "$(pixel_compositor_dst)" >/dev/null
pixel_adb "$serial" push "$(pixel_guest_client_artifact)" "$(pixel_guest_client_dst)" >/dev/null
pixel_adb "$serial" shell chmod 0755 \
  "$(pixel_session_dst)" \
  "$(pixel_compositor_dst)" \
  "$(pixel_guest_client_dst)"

printf 'Pushed %s\n' "$(pixel_session_dst)"
printf 'Pushed %s\n' "$(pixel_compositor_dst)"
printf 'Pushed %s\n' "$(pixel_guest_client_dst)"
