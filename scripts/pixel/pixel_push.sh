#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
system_bundle_artifact_dir="${PIXEL_SYSTEM_BUNDLE_ARTIFACT_DIR-}"
runtime_app_asset_artifact_dir="${PIXEL_RUNTIME_APP_ASSET_ARTIFACT_DIR-}"
runtime_app_bundle_artifact="${PIXEL_RUNTIME_APP_BUNDLE_ARTIFACT-}"
runtime_bundle_archive_host=""
runtime_bundle_archive_device=""
runtime_sync_work_dir=""
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
  if [[ -n "$runtime_sync_work_dir" && -d "$runtime_sync_work_dir" ]]; then
    rm -rf "$runtime_sync_work_dir"
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

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        print(json.load(handle).get(sys.argv[2], ""))
except (FileNotFoundError, json.JSONDecodeError):
    print("")
PY
}

json_manifest_string_field_from_device() {
  local manifest_path="$1"
  local field="$2"

  pixel_push_root_shell "cat '$manifest_path' 2>/dev/null || true" \
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

write_runtime_helper_sync_manifest() {
  local bundle_dir="$1"
  local manifest_path="$2"

  python3 - "$bundle_dir" "$manifest_path" <<'PY'
import hashlib
import json
import os
import stat
import sys

bundle_dir, manifest_path = sys.argv[1:3]
excluded_paths = {
    ".bundle-manifest.json",
    ".runtime-bundle-manifest.json",
    ".runtime-bundle-sync-manifest.json",
}
entries = []
for current_root, dirnames, filenames in os.walk(bundle_dir, topdown=True, followlinks=False):
    dirnames.sort()
    filenames.sort()
    rel_root = os.path.relpath(current_root, bundle_dir)
    if rel_root == ".":
        rel_root = ""

    for dirname in list(dirnames):
        abs_path = os.path.join(current_root, dirname)
        rel_path = os.path.join(rel_root, dirname) if rel_root else dirname
        st = os.lstat(abs_path)
        mode = stat.S_IMODE(st.st_mode)
        if stat.S_ISLNK(st.st_mode):
            entries.append(
                {
                    "mode": mode,
                    "path": rel_path,
                    "target": os.readlink(abs_path),
                    "type": "symlink",
                }
            )
            dirnames.remove(dirname)
            continue
        entries.append(
            {
                "mode": mode,
                "path": rel_path,
                "type": "dir",
            }
        )

    for filename in filenames:
        rel_path = os.path.join(rel_root, filename) if rel_root else filename
        if rel_path in excluded_paths:
            continue

        abs_path = os.path.join(current_root, filename)
        st = os.lstat(abs_path)
        mode = stat.S_IMODE(st.st_mode)
        if stat.S_ISLNK(st.st_mode):
            entries.append(
                {
                    "mode": mode,
                    "path": rel_path,
                    "target": os.readlink(abs_path),
                    "type": "symlink",
                }
            )
            continue

        digest = hashlib.sha256()
        with open(abs_path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        entries.append(
            {
                "mode": mode,
                "path": rel_path,
                "sha256": digest.hexdigest(),
                "size": st.st_size,
                "type": "file",
            }
        )

entries.sort(key=lambda entry: (entry["path"], entry["type"]))
fingerprint = hashlib.sha256()
for entry in entries:
    fingerprint.update(entry["type"].encode("utf-8"))
    fingerprint.update(b"\0")
    fingerprint.update(entry["path"].encode("utf-8"))
    fingerprint.update(b"\0")
    fingerprint.update(f"{entry['mode']:04o}".encode("ascii"))
    if entry["type"] == "file":
        fingerprint.update(b"\0")
        fingerprint.update(str(entry["size"]).encode("ascii"))
        fingerprint.update(b"\0")
        fingerprint.update(entry["sha256"].encode("ascii"))
    elif entry["type"] == "symlink":
        fingerprint.update(b"\0")
        fingerprint.update(entry["target"].encode("utf-8"))
    fingerprint.update(b"\n")

manifest = {
    "contentFingerprint": fingerprint.hexdigest(),
    "entries": entries,
    "schemaVersion": 1,
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY
}

write_runtime_helper_sync_plan() {
  local host_manifest_path="$1"
  local device_manifest_path="$2"
  local plan_path="$3"
  local changed_paths_path="$4"
  local reset_paths_path="$5"
  local dir_modes_path="$6"

  python3 - "$host_manifest_path" "$device_manifest_path" "$plan_path" "$changed_paths_path" "$reset_paths_path" "$dir_modes_path" <<'PY'
import json
import os
import sys

(
    host_manifest_path,
    device_manifest_path,
    plan_path,
    changed_paths_path,
    reset_paths_path,
    dir_modes_path,
) = sys.argv[1:7]

with open(host_manifest_path, "r", encoding="utf-8") as handle:
    host_manifest = json.load(handle)

device_manifest = {}
device_manifest_valid = False
if os.path.isfile(device_manifest_path):
    try:
        with open(device_manifest_path, "r", encoding="utf-8") as handle:
            device_manifest = json.load(handle)
        device_manifest_valid = (
            device_manifest.get("schemaVersion") == host_manifest.get("schemaVersion")
            and isinstance(device_manifest.get("entries"), list)
        )
    except json.JSONDecodeError:
        device_manifest = {}

host_entries = {
    entry["path"]: entry for entry in host_manifest.get("entries", [])
}
device_entries = {
    entry["path"]: entry for entry in device_manifest.get("entries", [])
} if device_manifest_valid else {}

changed_paths = []
reset_paths = set()
dir_modes = []
changed_bytes = 0

for path, host_entry in host_entries.items():
    device_entry = device_entries.get(path)
    if host_entry["type"] == "dir":
        dir_modes.append((path, host_entry["mode"]))
        if device_entry and device_entry.get("type") != "dir":
            reset_paths.add(path)
        continue

    if not device_manifest_valid or device_entry != host_entry:
        changed_paths.append(path)
        if host_entry["type"] == "file":
            changed_bytes += int(host_entry.get("size", 0))
        if device_entry and (
            device_entry.get("type") != host_entry.get("type")
            or host_entry["type"] == "symlink"
        ):
            reset_paths.add(path)

for path, device_entry in device_entries.items():
    if path not in host_entries:
        reset_paths.add(path)

dir_modes.sort(key=lambda item: (item[0].count("/"), item[0]))
changed_paths.sort()
reset_paths_sorted = sorted(reset_paths, key=lambda path: (-path.count("/"), path), reverse=False)

with open(changed_paths_path, "w", encoding="utf-8") as handle:
    for path in changed_paths:
        handle.write(f"{path}\n")

with open(reset_paths_path, "w", encoding="utf-8") as handle:
    for path in reset_paths_sorted:
        handle.write(f"{path}\n")

with open(dir_modes_path, "w", encoding="utf-8") as handle:
    for path, mode in dir_modes:
        handle.write(f"{mode:04o}\t{path}\n")

plan = {
    "changedBytes": changed_bytes,
    "changedPathCount": len(changed_paths),
    "contentFingerprint": host_manifest.get("contentFingerprint", ""),
    "deviceManifestValid": device_manifest_valid,
    "fullReplace": not device_manifest_valid,
    "resetPathCount": len(reset_paths_sorted),
}
with open(plan_path, "w", encoding="utf-8") as handle:
    json.dump(plan, handle, indent=2)
    handle.write("\n")
PY
}

json_manifest_int_field_from_file() {
  local manifest_path="$1"
  local field="$2"

  [[ -f "$manifest_path" ]] || return 0
  python3 - "$manifest_path" "$field" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        value = json.load(handle).get(sys.argv[2], 0)
except (FileNotFoundError, json.JSONDecodeError):
    value = 0
print(int(value))
PY
}

pixel_push_retryable_adb_failure() {
  local log_path="$1"

  grep -Eq \
    "device '.+' not found|error: device .+ not found|failed to get feature set: device '.+' not found|device offline|no devices/emulators found|closed" \
    "$log_path"
}

pixel_push_wait_for_transport() {
  local adb_timeout boot_timeout

  adb_timeout="${PIXEL_PUSH_WAIT_FOR_ADB_TIMEOUT_SECS:-45}"
  boot_timeout="${PIXEL_PUSH_WAIT_FOR_BOOT_TIMEOUT_SECS:-90}"

  pixel_wait_for_adb "$serial" "$adb_timeout" >/dev/null 2>&1 || return 1
  pixel_wait_for_boot_completed "$serial" "$boot_timeout" >/dev/null 2>&1 || true
}

pixel_push_adb() {
  local attempt max_attempts retry_sleep_secs status stdout_log stderr_log combined_log

  max_attempts="${PIXEL_PUSH_ADB_RETRIES:-4}"
  retry_sleep_secs="${PIXEL_PUSH_ADB_RETRY_SLEEP_SECS:-2}"
  stdout_log="$(mktemp "${TMPDIR:-/tmp}/pixel-push-adb-stdout.XXXXXX")"
  stderr_log="$(mktemp "${TMPDIR:-/tmp}/pixel-push-adb-stderr.XXXXXX")"
  combined_log="$(mktemp "${TMPDIR:-/tmp}/pixel-push-adb-combined.XXXXXX")"

  for attempt in $(seq 1 "$max_attempts"); do
    if pixel_adb "$serial" "$@" >"$stdout_log" 2>"$stderr_log"; then
      cat "$stderr_log" >&2
      cat "$stdout_log"
      rm -f "$stdout_log" "$stderr_log" "$combined_log"
      return 0
    fi

    status="$?"
    cat "$stdout_log" "$stderr_log" >"$combined_log"
    if (( attempt == max_attempts )) || ! pixel_push_retryable_adb_failure "$combined_log"; then
      cat "$stderr_log" >&2
      cat "$stdout_log"
      rm -f "$stdout_log" "$stderr_log" "$combined_log"
      return "$status"
    fi

    printf 'pixel_push: waiting for transient adb reconnect on %s (%s/%s)\n' \
      "$serial" "$attempt" "$max_attempts" >&2
    tail -n 20 "$combined_log" >&2 || true
    pixel_push_wait_for_transport || true
    sleep "$retry_sleep_secs"
  done

  rm -f "$stdout_log" "$stderr_log" "$combined_log"
  return 1
}

pixel_push_root_shell() {
  local command attempt max_attempts retry_sleep_secs status stdout_log stderr_log combined_log

  command="$1"
  max_attempts="${PIXEL_PUSH_ROOT_RETRIES:-4}"
  retry_sleep_secs="${PIXEL_PUSH_ROOT_RETRY_SLEEP_SECS:-2}"
  stdout_log="$(mktemp "${TMPDIR:-/tmp}/pixel-push-root-stdout.XXXXXX")"
  stderr_log="$(mktemp "${TMPDIR:-/tmp}/pixel-push-root-stderr.XXXXXX")"
  combined_log="$(mktemp "${TMPDIR:-/tmp}/pixel-push-root-combined.XXXXXX")"

  for attempt in $(seq 1 "$max_attempts"); do
    if pixel_root_shell "$serial" "$command" >"$stdout_log" 2>"$stderr_log"; then
      cat "$stderr_log" >&2
      cat "$stdout_log"
      rm -f "$stdout_log" "$stderr_log" "$combined_log"
      return 0
    fi

    status="$?"
    cat "$stdout_log" "$stderr_log" >"$combined_log"
    if (( attempt == max_attempts )) || ! pixel_push_retryable_adb_failure "$combined_log"; then
      cat "$stderr_log" >&2
      cat "$stdout_log"
      rm -f "$stdout_log" "$stderr_log" "$combined_log"
      return "$status"
    fi

    printf 'pixel_push: waiting for transient rooted adb reconnect on %s (%s/%s)\n' \
      "$serial" "$attempt" "$max_attempts" >&2
    tail -n 20 "$combined_log" >&2 || true
    pixel_push_wait_for_transport || true
    sleep "$retry_sleep_secs"
  done

  rm -f "$stdout_log" "$stderr_log" "$combined_log"
  return 1
}

push_verified_file() {
  local host_path device_path tmp_path host_sum device_sum
  host_path="$1"
  device_path="$2"
  tmp_path="${device_path}.push.$$"
  host_sum="$(shasum -a 256 "$host_path" | awk '{print $1}')"

  pixel_push_adb shell "rm -f '$tmp_path'"
  pixel_push_adb push "$host_path" "$tmp_path" >/dev/null
  device_sum="$(
    pixel_push_adb shell "toybox sha256sum '$tmp_path'" 2>/dev/null \
      | tr -d '\r' \
      | awk 'NR == 1 { print $1 }'
  )"
  if [[ -z "$device_sum" || "$device_sum" != "$host_sum" ]]; then
    pixel_push_adb shell "rm -f '$tmp_path'" >/dev/null 2>&1 || true
    echo "pixel_push: checksum mismatch for $device_path" >&2
    echo "pixel_push: host checksum=$host_sum device checksum=${device_sum:-missing}" >&2
    return 1
  fi

  pixel_push_adb shell "mv '$tmp_path' '$device_path' && chmod 0755 '$device_path'"
}

if ! pixel_require_runtime_artifacts; then
  "$SCRIPT_DIR/pixel/pixel_build.sh"
fi

printf 'Pushing device artifacts to %s\n' "$serial"
if [[ -n "$system_bundle_artifact_dir" || -n "$runtime_app_asset_artifact_dir" || -n "$runtime_app_bundle_artifact" ]]; then
  runtime_linux_dir="$(pixel_runtime_linux_dir)"
  runtime_manifest_path="$system_bundle_artifact_dir/.runtime-bundle-manifest.json"
  runtime_device_manifest_path="$runtime_linux_dir/.runtime-bundle-manifest.json"
  runtime_asset_manifest_path="$runtime_app_asset_artifact_dir/.runtime-assets-manifest.json"
  runtime_asset_manifest_device_path="$runtime_linux_dir/.runtime-assets-manifest.json"
  printf 'Pushing runtime support to %s\n' "$serial"

  if [[ -n "$system_bundle_artifact_dir" ]]; then
    runtime_sync_work_dir="$(mktemp -d "${TMPDIR:-/tmp}/shadow-runtime-sync.XXXXXX")"
    system_sync_manifest_path="$runtime_sync_work_dir/shadow-system-manifest.json"
    runtime_device_manifest_host_path="$runtime_sync_work_dir/runtime-device-manifest.json"
    runtime_sync_plan_path="$runtime_sync_work_dir/runtime-sync-plan.json"
    runtime_sync_changed_paths_path="$runtime_sync_work_dir/runtime-changed-paths.txt"
    runtime_sync_reset_paths_path="$runtime_sync_work_dir/runtime-reset-paths.txt"
    runtime_sync_dir_modes_path="$runtime_sync_work_dir/runtime-dir-modes.tsv"

    write_runtime_helper_sync_manifest \
      "$system_bundle_artifact_dir" \
      "$system_sync_manifest_path"
    runtime_helper_content_fingerprint="$(
      json_manifest_string_field_from_file "$system_sync_manifest_path" contentFingerprint
    )"

    pixel_push_root_shell "cat '$runtime_device_manifest_path' 2>/dev/null || true" \
      >"$runtime_device_manifest_host_path"
    runtime_device_content_fingerprint="$(
      json_manifest_string_field_from_file "$runtime_device_manifest_host_path" contentFingerprint
    )"

    if [[ -n "$runtime_helper_content_fingerprint" && "$runtime_helper_content_fingerprint" == "$runtime_device_content_fingerprint" ]]; then
      printf 'Runtime helper dir cacheHit -> %s\n' "$runtime_linux_dir"
    else
      runtime_sync_changed_path_count=0
      runtime_sync_reset_path_count=0
      runtime_sync_changed_bytes=0
      runtime_sync_full_replace=0

      write_runtime_helper_sync_plan \
        "$system_sync_manifest_path" \
        "$runtime_device_manifest_host_path" \
        "$runtime_sync_plan_path" \
        "$runtime_sync_changed_paths_path" \
        "$runtime_sync_reset_paths_path" \
        "$runtime_sync_dir_modes_path"

      runtime_sync_changed_path_count="$(
        json_manifest_int_field_from_file "$runtime_sync_plan_path" changedPathCount
      )"
      runtime_sync_reset_path_count="$(
        json_manifest_int_field_from_file "$runtime_sync_plan_path" resetPathCount
      )"
      runtime_sync_changed_bytes="$(
        json_manifest_int_field_from_file "$runtime_sync_plan_path" changedBytes
      )"
      if [[ "$(json_manifest_string_field_from_file "$runtime_sync_plan_path" fullReplace)" == "True" ]]; then
        runtime_sync_full_replace=1
      fi

      runtime_bundle_archive_device=""
      if (( runtime_sync_changed_path_count > 0 )); then
        runtime_bundle_archive_host="$(mktemp "${TMPDIR:-/tmp}/shadow-runtime-bundle.XXXXXX.tar")"
        runtime_bundle_archive_device="/data/local/tmp/$(basename "$runtime_bundle_archive_host")"
        COPYFILE_DISABLE=1 tar \
          --format=ustar \
          --numeric-owner \
          --owner=0 \
          --group=0 \
          --no-xattrs \
          -C "$system_bundle_artifact_dir" \
          -cf "$runtime_bundle_archive_host" \
          -T "$runtime_sync_changed_paths_path"
      fi

      pixel_push_root_shell "umount -l '$runtime_linux_dir/etc' >/dev/null 2>&1 || true"
      if (( runtime_sync_full_replace == 1 )); then
        pixel_push_root_shell "rm -rf '$runtime_linux_dir' && mkdir -p '$runtime_linux_dir' && chown shell:shell '$runtime_linux_dir' && chmod 0755 '$runtime_linux_dir'"
      else
        pixel_push_root_shell "mkdir -p '$runtime_linux_dir' && chown shell:shell '$runtime_linux_dir' && chmod 0755 '$runtime_linux_dir' && rm -f '$runtime_linux_dir/.bundle-manifest.json'"
        if (( runtime_sync_reset_path_count > 0 )); then
          pixel_push_root_shell "while IFS= read -r rel; do [ -n \"\$rel\" ] || continue; rm -rf '$runtime_linux_dir'/\"\$rel\"; done" \
            <"$runtime_sync_reset_paths_path"
        fi
      fi
      pixel_push_adb shell "while IFS='	' read -r mode rel; do [ -n \"\$rel\" ] || continue; mkdir -p '$runtime_linux_dir'/\"\$rel\" && chmod \"\$mode\" '$runtime_linux_dir'/\"\$rel\"; done" \
        <"$runtime_sync_dir_modes_path"

      if (( runtime_sync_changed_path_count > 0 )); then
        pixel_push_adb shell "rm -f '$runtime_bundle_archive_device'"
        pixel_push_adb push "$runtime_bundle_archive_host" "$runtime_bundle_archive_device" >/dev/null
        pixel_push_adb shell "/system/bin/tar -xf '$runtime_bundle_archive_device' -C '$runtime_linux_dir' && rm -f '$runtime_bundle_archive_device'"
      fi

      pixel_push_adb push "$system_sync_manifest_path" "$runtime_device_manifest_path" >/dev/null
      pixel_push_adb shell "chmod 0644 '$runtime_device_manifest_path'"

      if (( runtime_sync_full_replace == 1 )); then
        printf 'Runtime helper dir fullSync -> %s (changed=%s reset=%s bytes=%s)\n' \
          "$runtime_linux_dir" \
          "$runtime_sync_changed_path_count" \
          "$runtime_sync_reset_path_count" \
          "$runtime_sync_changed_bytes"
      else
        printf 'Runtime helper dir deltaSync -> %s (changed=%s reset=%s bytes=%s)\n' \
          "$runtime_linux_dir" \
          "$runtime_sync_changed_path_count" \
          "$runtime_sync_reset_path_count" \
          "$runtime_sync_changed_bytes"
      fi
    fi
  else
    pixel_push_root_shell "rm -rf '$runtime_linux_dir'"
    pixel_push_adb shell "mkdir -p '$runtime_linux_dir'"
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
    pixel_push_root_shell "[ -e '$runtime_linux_dir/assets' ] && printf yes || true" \
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
      pixel_push_root_shell "rm -rf '$runtime_linux_dir/assets'; mkdir -p '$runtime_linux_dir/assets'; rm -f '$runtime_asset_archive_device'"
      pixel_push_adb push "$runtime_asset_archive_host" "$runtime_asset_archive_device" >/dev/null
      pixel_push_root_shell "mkdir -p '$runtime_linux_dir/assets' && /system/bin/tar -xf '$runtime_asset_archive_device' -C '$runtime_linux_dir/assets' && chown -R shell:shell '$runtime_linux_dir/assets' && find '$runtime_linux_dir/assets' -type d -exec chmod 0755 {} + && find '$runtime_linux_dir/assets' -type f -exec chmod 0644 {} + && rm -f '$runtime_asset_archive_device'"
      pixel_push_adb push "$runtime_asset_manifest_path" "$runtime_asset_manifest_device_path" >/dev/null
      pixel_push_root_shell "chown shell:shell '$runtime_asset_manifest_device_path' && chmod 0644 '$runtime_asset_manifest_device_path'"
      printf 'Pushed runtime assets -> %s/assets\n' "$runtime_linux_dir"
    fi
  else
    if [[ -n "$runtime_device_asset_content_fingerprint" || "$runtime_device_assets_present" == "yes" ]]; then
      pixel_push_root_shell "rm -rf '$runtime_linux_dir/assets' '$runtime_asset_manifest_device_path'"
      printf 'Removed runtime assets -> %s/assets\n' "$runtime_linux_dir"
    fi
  fi

  if [[ -n "$runtime_app_bundle_artifact" ]]; then
    runtime_app_bundle_manifest_device_path="$runtime_linux_dir/.runtime-app-bundle-manifest.json"
    runtime_app_bundle_content_fingerprint="$(
      shasum -a 256 "$runtime_app_bundle_artifact" | awk '{print $1}'
    )"
    runtime_device_app_bundle_present="$(
      pixel_push_root_shell "test -f '$(pixel_runtime_app_bundle_dst)' && printf yes || true" \
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
      pixel_push_adb push "$runtime_app_bundle_artifact" "$(pixel_runtime_app_bundle_dst)" >/dev/null
      pixel_push_adb push "$runtime_app_bundle_manifest_host" "$runtime_app_bundle_manifest_device_path" >/dev/null
      pixel_push_root_shell "chown shell:shell '$(pixel_runtime_app_bundle_dst)' '$runtime_app_bundle_manifest_device_path' && chmod 0644 '$(pixel_runtime_app_bundle_dst)' '$runtime_app_bundle_manifest_device_path'"
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
