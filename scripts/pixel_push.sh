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
runtime_manifest_path=""
runtime_device_manifest_path=""
runtime_app_bundle_manifest_host=""
runtime_app_bundle_manifest_device_path=""
runtime_helper_content_fingerprint=""
runtime_device_content_fingerprint=""
runtime_app_bundle_content_fingerprint=""
runtime_device_app_bundle_content_fingerprint=""
runtime_device_app_bundle_present=""

cleanup() {
  if [[ -n "$runtime_bundle_archive_host" && -f "$runtime_bundle_archive_host" ]]; then
    rm -f "$runtime_bundle_archive_host"
  fi
  if [[ -n "$runtime_app_bundle_manifest_host" && -f "$runtime_app_bundle_manifest_host" ]]; then
    rm -f "$runtime_app_bundle_manifest_host"
  fi
}

trap cleanup EXIT

if ! pixel_require_runtime_artifacts; then
  "$SCRIPT_DIR/pixel_build.sh"
fi

printf 'Pushing device artifacts to %s\n' "$serial"
if [[ -n "$runtime_host_bundle_artifact_dir" || -n "$runtime_app_bundle_artifact" ]]; then
  runtime_linux_dir="$(pixel_runtime_linux_dir)"
  runtime_manifest_path="$runtime_host_bundle_artifact_dir/.runtime-bundle-manifest.json"
  runtime_device_manifest_path="$runtime_linux_dir/.runtime-bundle-manifest.json"
  printf 'Pushing runtime support to %s\n' "$serial"
  if [[ -n "$runtime_host_bundle_artifact_dir" ]]; then
    if [[ -f "$runtime_manifest_path" ]]; then
      runtime_helper_content_fingerprint="$(
        python3 - "$runtime_manifest_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    print(json.load(handle).get("contentFingerprint", ""))
PY
      )"
      runtime_device_content_fingerprint="$(
        pixel_root_shell "$serial" "cat '$runtime_device_manifest_path' 2>/dev/null || true" \
          | python3 -c '
import json
import sys

data = sys.stdin.read().strip()
if not data:
    print("")
else:
    try:
        print(json.loads(data).get("contentFingerprint", ""))
    except json.JSONDecodeError:
        print("")
' || true
      )"
    fi

    if [[ -n "$runtime_helper_content_fingerprint" && "$runtime_helper_content_fingerprint" == "$runtime_device_content_fingerprint" ]]; then
      printf 'Runtime helper dir cacheHit -> %s\n' "$runtime_linux_dir"
    else
      runtime_bundle_archive_host="$(mktemp "${TMPDIR:-/tmp}/shadow-runtime-bundle.XXXXXX.tar")"
      runtime_bundle_archive_device="/data/local/tmp/$(basename "$runtime_bundle_archive_host")"
      COPYFILE_DISABLE=1 tar \
        --format=ustar \
        --numeric-owner \
        --owner=0 \
        --group=0 \
        --no-xattrs \
        -C "$runtime_host_bundle_artifact_dir" \
        -cf "$runtime_bundle_archive_host" \
        .
      pixel_root_shell "$serial" "rm -rf '$runtime_linux_dir' '$runtime_bundle_archive_device'"
      pixel_adb "$serial" push "$runtime_bundle_archive_host" "$runtime_bundle_archive_device" >/dev/null
      pixel_root_shell "$serial" "mkdir -p '$runtime_linux_dir' && /system/bin/tar -xf '$runtime_bundle_archive_device' -C '$runtime_linux_dir' && chown -R shell:shell '$runtime_linux_dir' && find '$runtime_linux_dir' -type d -exec chmod 0755 {} + && find '$runtime_linux_dir' -type f -exec chmod 0755 {} + && rm -f '$runtime_bundle_archive_device'"
    fi
  else
    pixel_root_shell "$serial" "rm -rf '$runtime_linux_dir'"
    pixel_adb "$serial" shell "mkdir -p '$runtime_linux_dir'"
  fi
  if [[ -n "$runtime_app_bundle_artifact" ]]; then
    runtime_app_bundle_manifest_device_path="$runtime_linux_dir/.runtime-app-bundle-manifest.json"
    runtime_app_bundle_content_fingerprint="$(
      shasum -a 256 "$runtime_app_bundle_artifact" | awk '{print $1}'
    )"
    runtime_device_app_bundle_present="$(
      pixel_root_shell "$serial" "test -f '$(pixel_runtime_app_bundle_dst)' && printf yes || true" \
        | tr -d '\r' || true
    )"
    runtime_device_app_bundle_content_fingerprint="$(
      pixel_root_shell "$serial" "cat '$runtime_app_bundle_manifest_device_path' 2>/dev/null || true" \
        | python3 -c '
import json
import sys

data = sys.stdin.read().strip()
if not data:
    print("")
else:
    try:
        print(json.loads(data).get("fingerprint", ""))
    except json.JSONDecodeError:
        print("")
' || true
    )"
    if [[ "$runtime_device_app_bundle_present" == "yes" && -n "$runtime_app_bundle_content_fingerprint" && "$runtime_app_bundle_content_fingerprint" == "$runtime_device_app_bundle_content_fingerprint" ]]; then
      printf 'Runtime app bundle cacheHit -> %s\n' "$(pixel_runtime_app_bundle_dst)"
    else
      runtime_app_bundle_manifest_host="$(mktemp "${TMPDIR:-/tmp}/shadow-runtime-app-bundle.XXXXXX.json")"
      python3 - "$runtime_app_bundle_manifest_host" "$runtime_app_bundle_content_fingerprint" <<'PY'
import json
import sys

manifest_path, fingerprint = sys.argv[1:3]
manifest = {
    "fingerprint": fingerprint,
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY
      pixel_adb "$serial" push "$runtime_app_bundle_artifact" "$(pixel_runtime_app_bundle_dst)" >/dev/null
      pixel_adb "$serial" push "$runtime_app_bundle_manifest_host" "$runtime_app_bundle_manifest_device_path" >/dev/null
      printf 'Pushed runtime app bundle -> %s\n' "$(pixel_runtime_app_bundle_dst)"
    fi
  fi
  pixel_root_shell "$serial" "find '$runtime_linux_dir' -type f -exec chmod 0755 {} +"
  printf 'Pushed runtime helper dir -> %s\n' "$runtime_linux_dir"
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
