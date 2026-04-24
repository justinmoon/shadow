#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_DIR=""
DRY_RUN=0
INCLUDE_CAMERA_COMPONENTS="${PIXEL_CAMERA_HAL_CAPSULE_INCLUDE_COMPONENTS:-true}"
ADB_TIMEOUT_SECS="${PIXEL_CAMERA_HAL_CAPSULE_ADB_TIMEOUT_SECS:-120}"

serial=""
readelf_cmd=""
declare -a queue=()
declare -A queued=()
declare -A pulled=()
declare -A missing=()
declare -A device_library_paths=()

search_roots=(
  /vendor/lib64/hw
  /vendor/lib64
  /vendor/lib64/camera
  /vendor/lib64/camera/components
  /odm/lib64
  /system/lib64
  /system_ext/lib64
  /apex/com.android.vndk.v33/lib64
  /apex/com.android.runtime/lib64/bionic
  /apex/com.android.runtime/lib64
  /product/lib64
)

initial_files=(
  /vendor/lib64/hw/camera.sm6150.so
  /linkerconfig/ld.config.txt
  /apex/com.android.runtime/bin/linker64
)

component_roots=(
  /vendor/lib64/camera
)

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_camera_hal_collect_capsule.sh [--output DIR]
                                                         [--include-camera-components true|false]
                                                         [--adb-timeout SECONDS]
                                                         [--dry-run]

Collect the minimal rooted-Android camera HAL linker capsule for the Shadow boot
camera probe. The output directory mirrors absolute device paths such as
vendor/lib64/hw/camera.sm6150.so, linkerconfig/ld.config.txt, and APEX linker
runtime files so it can be staged into a boot ramdisk.
EOF
}

safe_path_component() {
  tr -c 'A-Za-z0-9._-' '_' <<<"$1" | sed 's/_$//'
}

resolve_serial_for_mode() {
  if [[ "$DRY_RUN" == "1" && -n "${PIXEL_SERIAL:-}" ]]; then
    printf '%s\n' "$PIXEL_SERIAL"
    return 0
  fi

  pixel_resolve_serial
}

bool_arg() {
  local label value
  label="$1"
  value="$2"
  case "$value" in
    true|false)
      ;;
    *)
      echo "pixel_camera_hal_collect_capsule: $label must be true or false: $value" >&2
      exit 1
      ;;
  esac
}

find_readelf() {
  if command -v llvm-readelf >/dev/null 2>&1; then
    printf 'llvm-readelf\n'
    return 0
  fi
  if command -v readelf >/dev/null 2>&1; then
    printf 'readelf\n'
    return 0
  fi

  echo "pixel_camera_hal_collect_capsule: llvm-readelf or readelf is required" >&2
  exit 1
}

host_path_for_device_path() {
  local device_path
  device_path="${1:?host_path_for_device_path requires a device path}"
  printf '%s/%s\n' "$OUTPUT_DIR" "${device_path#/}"
}

device_shell_quote() {
  local value
  value="${1:?device_shell_quote requires a value}"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

adb_shell_root() {
  local command_text
  command_text="${1:?adb_shell_root requires a command}"
  timeout "$ADB_TIMEOUT_SECS" adb -s "$serial" shell "su 0 sh -c $(device_shell_quote "$command_text")" </dev/null
}

queue_file() {
  local device_path
  device_path="$1"
  [[ -n "$device_path" ]] || return 0
  [[ "$device_path" == /* ]] || {
    echo "pixel_camera_hal_collect_capsule: refusing non-absolute device path: $device_path" >&2
    exit 1
  }
  if [[ -z "${queued[$device_path]:-}" ]]; then
    queued[$device_path]=1
    queue+=("$device_path")
  fi
}

pull_file() {
  local device_path host_path tmp_path
  device_path="$1"
  host_path="$(host_path_for_device_path "$device_path")"

  if [[ -n "${pulled[$device_path]:-}" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$host_path")"
  tmp_path="$host_path.tmp"
  rm -f "$tmp_path"
  if timeout "$ADB_TIMEOUT_SECS" adb -s "$serial" pull "$device_path" "$tmp_path" >/dev/null 2>&1; then
    mv "$tmp_path" "$host_path"
  elif timeout "$ADB_TIMEOUT_SECS" adb -s "$serial" shell "su 0 sh -c $(device_shell_quote "cat $(device_shell_quote "$device_path")")" >"$tmp_path" </dev/null; then
    mv "$tmp_path" "$host_path"
  else
    rm -f "$tmp_path"
    missing[$device_path]=pull-failed
    return 1
  fi

  case "$device_path" in
    /apex/com.android.runtime/bin/linker64)
      chmod 0755 "$host_path" 2>/dev/null || true
      ;;
    *)
      chmod 0644 "$host_path" 2>/dev/null || true
      ;;
  esac
  pulled[$device_path]=1
}

read_needed_sonames() {
  local host_path
  host_path="$1"
  "$readelf_cmd" -dW "$host_path" 2>/dev/null |
    sed -n 's/^.*Shared library: \[\(.*\)\]$/\1/p'
}

find_device_library() {
  local soname
  soname="$1"

  if [[ -n "${device_library_paths[$soname]:-}" ]]; then
    printf '%s\n' "${device_library_paths[$soname]}"
    return 0
  fi

  return 1
}

index_device_libraries() {
  local device_path find_command root soname
  find_command=":"
  for root in "${search_roots[@]}"; do
    find_command+="; find $(device_shell_quote "$root") -maxdepth 1 -type f -print 2>/dev/null"
  done

  while IFS= read -r device_path; do
    device_path="${device_path//$'\r'/}"
    [[ "$device_path" == /* ]] || continue
    soname="${device_path##*/}"
    if [[ -z "${device_library_paths[$soname]:-}" ]]; then
      device_library_paths[$soname]="$device_path"
    fi
  done < <(adb_shell_root "$find_command")
}

queue_component_files() {
  local root
  for root in "${component_roots[@]}"; do
    while IFS= read -r device_path; do
      queue_file "$device_path"
    done < <(
      adb_shell_root "find $(device_shell_quote "$root") -maxdepth 3 -type f 2>/dev/null" |
        tr -d '\r' |
        LC_ALL=C sort
    )
  done
}

write_manifest() {
  local manifest_path
  manifest_path="$OUTPUT_DIR/capsule-manifest.json"
  python3 - "$manifest_path" "$serial" "$INCLUDE_CAMERA_COMPONENTS" "${!pulled[@]}" -- "${!missing[@]}" <<'PY'
import json
import sys

manifest_path, serial, include_components = sys.argv[1:4]
separator = sys.argv.index("--")
pulled = sorted(sys.argv[4:separator])
missing = sorted(sys.argv[separator + 1 :])

payload = {
    "kind": "camera_hal_linker_capsule",
    "serial": serial,
    "includeCameraComponents": include_components == "true",
    "pulled": pulled,
    "missing": missing,
}
with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_DIR="${2:?missing value for --output}"
      shift 2
      ;;
    --include-camera-components)
      INCLUDE_CAMERA_COMPONENTS="${2:?missing value for --include-camera-components}"
      shift 2
      ;;
    --adb-timeout)
      ADB_TIMEOUT_SECS="${2:?missing value for --adb-timeout}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "pixel_camera_hal_collect_capsule: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

bool_arg include-camera-components "$INCLUDE_CAMERA_COMPONENTS"
if [[ ! "$ADB_TIMEOUT_SECS" =~ ^[0-9]+$ ]]; then
  echo "pixel_camera_hal_collect_capsule: adb timeout must be an integer: $ADB_TIMEOUT_SECS" >&2
  exit 1
fi

serial="$(resolve_serial_for_mode)"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(pixel_dir)/camera-linker-capsule/$(pixel_timestamp)-$(safe_path_component "$serial")"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  cat <<EOF
pixel_camera_hal_collect_capsule: dry-run
serial=$serial
output_dir=$OUTPUT_DIR
include_camera_components=$INCLUDE_CAMERA_COMPONENTS
adb_timeout_secs=$ADB_TIMEOUT_SECS
initial_files=${initial_files[*]}
search_roots=${search_roots[*]}
EOF
  exit 0
fi

if [[ -e "$OUTPUT_DIR" ]] && find "$OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
  echo "pixel_camera_hal_collect_capsule: output dir must be empty or absent: $OUTPUT_DIR" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
readelf_cmd="$(find_readelf)"
index_device_libraries

for device_path in "${initial_files[@]}"; do
  queue_file "$device_path"
done
if [[ "$INCLUDE_CAMERA_COMPONENTS" == "true" ]]; then
  queue_component_files
fi

while ((${#queue[@]})); do
  device_path="${queue[0]}"
  queue=("${queue[@]:1}")

  if ! pull_file "$device_path"; then
    continue
  fi

  host_path="$(host_path_for_device_path "$device_path")"
  while IFS= read -r soname; do
    [[ -n "$soname" ]] || continue
    if dependency_path="$(find_device_library "$soname")"; then
      queue_file "$dependency_path"
    else
      missing[$soname]=not-found
    fi
  done < <(read_needed_sonames "$host_path")
done

write_manifest
printf 'Camera HAL linker capsule: %s\n' "$OUTPUT_DIR"
