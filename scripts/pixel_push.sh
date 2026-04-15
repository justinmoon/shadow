#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
runtime_host_bundle_artifact_dir="${PIXEL_RUNTIME_HOST_BUNDLE_ARTIFACT_DIR-}"
runtime_app_asset_artifact_dir="${PIXEL_RUNTIME_APP_ASSET_ARTIFACT_DIR-}"
runtime_app_bundle_artifact="${PIXEL_RUNTIME_APP_BUNDLE_ARTIFACT-}"
runtime_bundle_archive_host=""
runtime_bundle_archive_device=""
runtime_asset_archive_host=""
runtime_asset_archive_device=""
runtime_manifest_path=""
runtime_device_manifest_path=""
runtime_asset_manifest_path=""
runtime_asset_manifest_device_path=""
runtime_app_bundle_manifest_host=""
runtime_app_bundle_manifest_device_path=""
runtime_helper_content_fingerprint=""
runtime_device_content_fingerprint=""
runtime_asset_content_fingerprint=""
runtime_device_asset_content_fingerprint=""
runtime_device_assets_present=""
runtime_app_bundle_content_fingerprint=""
runtime_device_app_bundle_content_fingerprint=""
runtime_device_app_bundle_present=""

cleanup() {
  if [[ -n "$runtime_bundle_archive_host" && -f "$runtime_bundle_archive_host" ]]; then
    rm -f "$runtime_bundle_archive_host"
  fi
  if [[ -n "$runtime_asset_archive_host" && -f "$runtime_asset_archive_host" ]]; then
    rm -f "$runtime_asset_archive_host"
  fi
  if [[ -n "$runtime_app_bundle_manifest_host" && -f "$runtime_app_bundle_manifest_host" ]]; then
    rm -f "$runtime_app_bundle_manifest_host"
  fi
}

trap cleanup EXIT

json_manifest_string_field_from_file() {
  local manifest_path="$1"
  local field="$2"

  [[ -f "$manifest_path" ]] || return 0
  python3 - "$manifest_path" "$field" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    print(json.load(handle).get(sys.argv[2], ""))
PY
}

json_manifest_string_field_from_device() {
  local manifest_path="$1"
  local field="$2"

  pixel_root_shell "$serial" "cat '$manifest_path' 2>/dev/null || true" \
    | python3 -c '
import json
import sys

data = sys.stdin.read().strip()
field = sys.argv[1]
if not data:
    print("")
else:
    try:
        print(json.loads(data).get(field, ""))
    except json.JSONDecodeError:
        print("")
' "$field"
}

push_verified_file() {
  local host_path device_path tmp_path host_sum device_sum
  host_path="$1"
  device_path="$2"
  tmp_path="${device_path}.push.$$"
  host_sum="$(shasum -a 256 "$host_path" | awk '{print $1}')"

  pixel_adb "$serial" shell "rm -f '$tmp_path'"
  pixel_adb "$serial" push "$host_path" "$tmp_path" >/dev/null
  device_sum="$(
    pixel_adb "$serial" shell "toybox sha256sum '$tmp_path'" 2>/dev/null \
      | tr -d '\r' \
      | awk 'NR == 1 { print $1 }'
  )"
  if [[ -z "$device_sum" || "$device_sum" != "$host_sum" ]]; then
    pixel_adb "$serial" shell "rm -f '$tmp_path'" >/dev/null 2>&1 || true
    echo "pixel_push: checksum mismatch for $device_path" >&2
    echo "pixel_push: host checksum=$host_sum device checksum=${device_sum:-missing}" >&2
    return 1
  fi

  pixel_adb "$serial" shell "mv '$tmp_path' '$device_path' && chmod 0755 '$device_path'"
}

if ! pixel_require_runtime_artifacts; then
  "$SCRIPT_DIR/pixel_build.sh"
fi

printf 'Pushing device artifacts to %s\n' "$serial"
if [[ -n "$runtime_host_bundle_artifact_dir" || -n "$runtime_app_asset_artifact_dir" || -n "$runtime_app_bundle_artifact" ]]; then
  runtime_linux_dir="$(pixel_runtime_linux_dir)"
  runtime_manifest_path="$runtime_host_bundle_artifact_dir/.runtime-bundle-manifest.json"
  runtime_device_manifest_path="$runtime_linux_dir/.runtime-bundle-manifest.json"
  runtime_asset_manifest_path="$runtime_app_asset_artifact_dir/.runtime-assets-manifest.json"
  runtime_asset_manifest_device_path="$runtime_linux_dir/.runtime-assets-manifest.json"
  printf 'Pushing runtime support to %s\n' "$serial"

  if [[ -n "$runtime_host_bundle_artifact_dir" ]]; then
    if [[ -f "$runtime_manifest_path" ]]; then
      runtime_helper_content_fingerprint="$(
        json_manifest_string_field_from_file "$runtime_manifest_path" contentFingerprint
      )"
      runtime_device_content_fingerprint="$(
        json_manifest_string_field_from_device "$runtime_device_manifest_path" contentFingerprint
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
      pixel_root_shell "$serial" "umount -l '$runtime_linux_dir/etc' >/dev/null 2>&1 || true; mkdir -p '$runtime_linux_dir'; rm -f '$runtime_bundle_archive_device'"
      pixel_adb "$serial" push "$runtime_bundle_archive_host" "$runtime_bundle_archive_device" >/dev/null
      pixel_root_shell "$serial" "umount -l '$runtime_linux_dir/etc' >/dev/null 2>&1 || true; mkdir -p '$runtime_linux_dir' && /system/bin/tar -xf '$runtime_bundle_archive_device' -C '$runtime_linux_dir' && chown -R shell:shell '$runtime_linux_dir' && find '$runtime_linux_dir' -type d -exec chmod 0755 {} + && find '$runtime_linux_dir' -type f -exec chmod 0755 {} + && rm -f '$runtime_bundle_archive_device'"
    fi
  else
    pixel_root_shell "$serial" "rm -rf '$runtime_linux_dir'"
    pixel_adb "$serial" shell "mkdir -p '$runtime_linux_dir'"
  fi

  if [[ -n "$runtime_app_asset_artifact_dir" && -d "$runtime_app_asset_artifact_dir" ]]; then
    if [[ ! -f "$runtime_asset_manifest_path" ]]; then
      echo "pixel_push: missing runtime asset manifest: $runtime_asset_manifest_path" >&2
      exit 1
    fi
    runtime_asset_content_fingerprint="$(
      json_manifest_string_field_from_file "$runtime_asset_manifest_path" contentFingerprint
    )"
    if [[ -z "$runtime_asset_content_fingerprint" ]]; then
      echo "pixel_push: invalid runtime asset manifest: $runtime_asset_manifest_path" >&2
      exit 1
    fi
  fi
  runtime_device_asset_content_fingerprint="$(
    json_manifest_string_field_from_device "$runtime_asset_manifest_device_path" contentFingerprint
  )"
  runtime_device_assets_present="$(
    pixel_root_shell "$serial" "[ -e '$runtime_linux_dir/assets' ] && printf yes || true" \
      | tr -d '\r' || true
  )"
  if [[ -n "$runtime_asset_content_fingerprint" ]]; then
    if [[ "$runtime_asset_content_fingerprint" == "$runtime_device_asset_content_fingerprint" && "$runtime_device_assets_present" == "yes" ]]; then
      printf 'Runtime assets cacheHit -> %s/assets\n' "$runtime_linux_dir"
    else
      runtime_asset_archive_host="$(mktemp "${TMPDIR:-/tmp}/shadow-runtime-assets.XXXXXX.tar")"
      runtime_asset_archive_device="/data/local/tmp/$(basename "$runtime_asset_archive_host")"
      COPYFILE_DISABLE=1 tar \
        --format=ustar \
        --numeric-owner \
        --owner=0 \
        --group=0 \
        --no-xattrs \
        --exclude=.runtime-assets-manifest.json \
        -C "$runtime_app_asset_artifact_dir" \
        -cf "$runtime_asset_archive_host" \
        .
      pixel_root_shell "$serial" "rm -rf '$runtime_linux_dir/assets'; mkdir -p '$runtime_linux_dir/assets'; rm -f '$runtime_asset_archive_device'"
      pixel_adb "$serial" push "$runtime_asset_archive_host" "$runtime_asset_archive_device" >/dev/null
      pixel_root_shell "$serial" "mkdir -p '$runtime_linux_dir/assets' && /system/bin/tar -xf '$runtime_asset_archive_device' -C '$runtime_linux_dir/assets' && chown -R shell:shell '$runtime_linux_dir/assets' && find '$runtime_linux_dir/assets' -type d -exec chmod 0755 {} + && find '$runtime_linux_dir/assets' -type f -exec chmod 0644 {} + && rm -f '$runtime_asset_archive_device'"
      pixel_adb "$serial" push "$runtime_asset_manifest_path" "$runtime_asset_manifest_device_path" >/dev/null
      pixel_root_shell "$serial" "chown shell:shell '$runtime_asset_manifest_device_path' && chmod 0644 '$runtime_asset_manifest_device_path'"
      printf 'Pushed runtime assets -> %s/assets\n' "$runtime_linux_dir"
    fi
  else
    if [[ -n "$runtime_device_asset_content_fingerprint" || "$runtime_device_assets_present" == "yes" ]]; then
      pixel_root_shell "$serial" "rm -rf '$runtime_linux_dir/assets' '$runtime_asset_manifest_device_path'"
      printf 'Removed runtime assets -> %s/assets\n' "$runtime_linux_dir"
    fi
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
      json_manifest_string_field_from_device "$runtime_app_bundle_manifest_device_path" fingerprint
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
      pixel_root_shell "$serial" "chown shell:shell '$(pixel_runtime_app_bundle_dst)' '$runtime_app_bundle_manifest_device_path' && chmod 0644 '$(pixel_runtime_app_bundle_dst)' '$runtime_app_bundle_manifest_device_path'"
      printf 'Pushed runtime app bundle -> %s\n' "$(pixel_runtime_app_bundle_dst)"
    fi
  fi

  printf 'Pushed runtime helper dir -> %s\n' "$runtime_linux_dir"
fi

push_verified_file "$(pixel_session_artifact)" "$(pixel_session_dst)"
push_verified_file "$(pixel_compositor_artifact)" "$(pixel_compositor_dst)"
push_verified_file "$(pixel_guest_client_artifact)" "$(pixel_guest_client_dst)"

printf 'Pushed %s\n' "$(pixel_session_dst)"
printf 'Pushed %s\n' "$(pixel_compositor_dst)"
printf 'Pushed %s\n' "$(pixel_guest_client_dst)"
