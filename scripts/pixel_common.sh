#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"

pixel_dir() {
  printf '%s/pixel\n' "$(build_dir)"
}

pixel_artifacts_dir() {
  printf '%s/artifacts\n' "$(pixel_dir)"
}

pixel_root_dir() {
  printf '%s/root\n' "$(pixel_dir)"
}

pixel_runs_dir() {
  printf '%s/runs\n' "$(pixel_dir)"
}

pixel_latest_run_link() {
  printf '%s/latest-run\n' "$(pixel_dir)"
}

pixel_timestamp() {
  date -u +%Y%m%dT%H%M%SZ
}

pixel_connected_serials() {
  adb devices | awk 'NR > 1 && $2 == "device" { print $1 }'
}

pixel_connected_sideload_serials() {
  adb devices | awk 'NR > 1 && $2 == "sideload" { print $1 }'
}

pixel_resolve_serial() {
  local requested
  requested="${PIXEL_SERIAL:-}"

  if [[ -n "$requested" ]]; then
    if pixel_connected_serials | grep -Fxq "$requested"; then
      printf '%s\n' "$requested"
      return 0
    fi
    echo "pixel: requested PIXEL_SERIAL is not connected and authorized: $requested" >&2
    return 1
  fi

  mapfile -t serials < <(pixel_connected_serials)
  case "${#serials[@]}" in
    0)
      echo "pixel: no authorized adb device detected" >&2
      return 1
      ;;
    1)
      printf '%s\n' "${serials[0]}"
      ;;
    *)
      echo "pixel: multiple adb devices detected; set PIXEL_SERIAL" >&2
      printf '  %s\n' "${serials[@]}" >&2
      return 1
      ;;
  esac
}

pixel_resolve_sideload_serial() {
  local requested
  requested="${PIXEL_SERIAL:-}"

  if [[ -n "$requested" ]]; then
    if pixel_connected_sideload_serials | grep -Fxq "$requested"; then
      printf '%s\n' "$requested"
      return 0
    fi
    echo "pixel: requested PIXEL_SERIAL is not connected in adb sideload mode: $requested" >&2
    return 1
  fi

  mapfile -t serials < <(pixel_connected_sideload_serials)
  case "${#serials[@]}" in
    0)
      echo "pixel: no adb sideload device detected" >&2
      return 1
      ;;
    1)
      printf '%s\n' "${serials[0]}"
      ;;
    *)
      echo "pixel: multiple adb sideload devices detected; set PIXEL_SERIAL" >&2
      printf '  %s\n' "${serials[@]}" >&2
      return 1
      ;;
  esac
}

pixel_adb() {
  local serial
  serial="$1"
  shift
  adb -s "$serial" "$@"
}

pixel_fastboot() {
  local serial
  serial="$1"
  shift
  fastboot -s "$serial" "$@"
}

pixel_su_candidates() {
  printf '%s\n' "${PIXEL_SU_BIN:-/debug_ramdisk/su}"
  printf '%s\n' "su"
}

pixel_root_id() {
  local serial su_bin output status
  serial="$1"

  while IFS= read -r su_bin; do
    [[ -n "$su_bin" ]] || continue
    set +e
    output="$(pixel_adb "$serial" shell "$su_bin 0 sh -c id" 2>/dev/null | tr -d '\r')"
    status="$?"
    set -e
    if [[ "$status" -eq 0 && -n "$output" ]]; then
      printf '%s\n' "$output"
      return 0
    fi
  done < <(pixel_su_candidates)

  return 1
}

pixel_root_shell() {
  local serial command su_bin
  serial="$1"
  shift
  command="$1"

  while IFS= read -r su_bin; do
    [[ -n "$su_bin" ]] || continue
    if pixel_adb "$serial" shell "$su_bin 0 sh -c $(printf '%q' "$command")"; then
      return 0
    fi
  done < <(pixel_su_candidates)

  return 1
}

pixel_takeover_stop_services_script() {
  cat <<'EOF'
wait_for_service_state() {
  service="$1"
  expected="$2"
  attempts="${3:-40}"
  count=0
  while [ "$count" -lt "$attempts" ]; do
    current="$(getprop "init.svc.$service" | tr -d '\r')"
    if [ "$current" = "$expected" ]; then
      return 0
    fi
    count=$((count + 1))
    sleep 0.2
  done
  return 1
}

kill_stale_shadow_processes() {
  shadow_process_pids() {
    name="$1"
    ps -A | awk -v name="$name" '$NF == name { print $2 }'
  }

  kill_named_shadow_process() {
    name="$1"
    attempts="${2:-10}"
    count=0

    for pid in $(shadow_process_pids "$name"); do
      kill "$pid" >/dev/null 2>&1 || true
    done
    while [ "$count" -lt "$attempts" ]; do
      if [ -z "$(shadow_process_pids "$name")" ]; then
        return 0
      fi
      count=$((count + 1))
      sleep 0.2
    done

    for pid in $(shadow_process_pids "$name"); do
      kill -KILL "$pid" >/dev/null 2>&1 || true
    done
    while [ -n "$(shadow_process_pids "$name")" ]; do
      sleep 0.1
    done
  }

  kill_named_shadow_process shadow-blitz-demo
  kill_named_shadow_process shadow-counter-guest
  kill_named_shadow_process shadow-compositor-guest
  kill_named_shadow_process drm-rect
  kill_named_shadow_process shadow-session
}

stop_service_and_wait() {
  service="$1"
  stop "$service" || true
  wait_for_service_state "$service" stopped 50 || true
}

kill_stale_shadow_processes
stop_service_and_wait surfaceflinger
stop_service_and_wait bootanim
stop_service_and_wait vendor.hwcomposer-2-4
stop_service_and_wait vendor.qti.hardware.display.allocator
setenforce 0 >/dev/null 2>&1 || true
EOF
}

pixel_takeover_start_services_script() {
  cat <<'EOF'
wait_for_service_state() {
  service="$1"
  expected="$2"
  attempts="${3:-40}"
  count=0
  while [ "$count" -lt "$attempts" ]; do
    current="$(getprop "init.svc.$service" | tr -d '\r')"
    if [ "$current" = "$expected" ]; then
      return 0
    fi
    count=$((count + 1))
    sleep 0.2
  done
  return 1
}

kill_stale_shadow_processes() {
  shadow_process_pids() {
    name="$1"
    ps -A | awk -v name="$name" '$NF == name { print $2 }'
  }

  kill_named_shadow_process() {
    name="$1"
    attempts="${2:-10}"
    count=0

    for pid in $(shadow_process_pids "$name"); do
      kill "$pid" >/dev/null 2>&1 || true
    done
    while [ "$count" -lt "$attempts" ]; do
      if [ -z "$(shadow_process_pids "$name")" ]; then
        return 0
      fi
      count=$((count + 1))
      sleep 0.2
    done

    for pid in $(shadow_process_pids "$name"); do
      kill -KILL "$pid" >/dev/null 2>&1 || true
    done
    while [ -n "$(shadow_process_pids "$name")" ]; do
      sleep 0.1
    done
  }

  kill_named_shadow_process shadow-blitz-demo
  kill_named_shadow_process shadow-counter-guest
  kill_named_shadow_process shadow-compositor-guest
  kill_named_shadow_process drm-rect
  kill_named_shadow_process shadow-session
}

start_service_and_wait() {
  service="$1"
  start "$service" || true
  wait_for_service_state "$service" running 50 || true
}

boot_completed() {
  [ "$(getprop sys.boot_completed | tr -d '\r')" = "1" ] \
    || [ "$(getprop dev.bootcomplete | tr -d '\r')" = "1" ]
}

kill_stale_shadow_processes
start_service_and_wait vendor.qti.hardware.display.allocator
start_service_and_wait vendor.hwcomposer-2-4
start_service_and_wait surfaceflinger
if boot_completed; then
  setprop service.bootanim.exit 1 || true
  stop bootanim || true
  wait_for_service_state bootanim stopped 50 || true
else
  start_service_and_wait bootanim
fi
setenforce 1 >/dev/null 2>&1 || true
EOF
}

pixel_prop() {
  local serial key
  serial="$1"
  key="$2"
  pixel_adb "$serial" shell getprop "$key" | tr -d '\r'
}

pixel_service_state() {
  local serial service
  serial="$1"
  service="$2"
  pixel_prop "$serial" "init.svc.$service"
}

pixel_display_services_stopped() {
  local serial service
  serial="$1"
  for service in surfaceflinger vendor.hwcomposer-2-4 vendor.qti.hardware.display.allocator; do
    if [[ "$(pixel_service_state "$serial" "$service")" != "stopped" ]]; then
      return 1
    fi
  done
}

pixel_display_services_running() {
  local serial service
  serial="$1"
  for service in surfaceflinger vendor.hwcomposer-2-4 vendor.qti.hardware.display.allocator; do
    if [[ "$(pixel_service_state "$serial" "$service")" != "running" ]]; then
      return 1
    fi
  done
}

pixel_bootanim_stopped() {
  local serial
  serial="$1"
  [[ "$(pixel_service_state "$serial" bootanim)" == "stopped" ]]
}

pixel_display_size() {
  local serial size
  serial="$1"
  size="$(
    pixel_adb "$serial" shell wm size 2>/dev/null \
      | tr -d '\r' \
      | grep -Eo '[0-9]+x[0-9]+' \
      | head -n1 \
      || true
  )"
  if [[ -z "$size" ]]; then
    echo "pixel: failed to determine display size via 'wm size'" >&2
    return 1
  fi
  printf '%s\n' "$size"
}

pixel_takeover_processes_absent() {
  local serial process_name
  serial="$1"
  for process_name in shadow-blitz-demo shadow-counter-guest shadow-compositor-guest drm-rect shadow-session; do
    if pixel_root_process_exists "$serial" "$process_name" >/dev/null 2>&1; then
      return 1
    fi
  done
}

pixel_android_display_restored() {
  local serial
  serial="$1"
  [[ "$(pixel_service_state "$serial" surfaceflinger)" == "running" ]] || return 1
  if [[ "$(pixel_prop "$serial" sys.boot_completed)" == "1" || "$(pixel_prop "$serial" dev.bootcomplete)" == "1" ]]; then
    pixel_bootanim_stopped "$serial" || return 1
  fi
  pixel_takeover_processes_absent "$serial"
}

pixel_root_process_exists() {
  local serial process_name
  serial="$1"
  process_name="$2"
  pixel_root_shell "$serial" "ps -A | awk -v name='$process_name' '\$NF == name { found=1 } END { exit(found ? 0 : 1) }'"
}

pixel_root_file_nonempty() {
  local serial path
  serial="$1"
  path="$2"
  pixel_root_shell "$serial" "[ -s '$path' ]"
}

pixel_wait_for_condition() {
  local timeout_secs sleep_secs deadline
  timeout_secs="$1"
  sleep_secs="$2"
  shift 2

  deadline=$((SECONDS + timeout_secs))
  while (( SECONDS < deadline )); do
    if "$@"; then
      return 0
    fi
    sleep "$sleep_secs"
  done

  if "$@"; then
    return 0
  fi
  return 1
}

pixel_prepare_dirs() {
  mkdir -p "$(pixel_artifacts_dir)" "$(pixel_runs_dir)" "$(pixel_root_dir)"
}

pixel_prepare_named_run_dir() {
  local base_dir run_dir
  base_dir="$1"
  mkdir -p "$base_dir"
  run_dir="${base_dir}/$(pixel_timestamp)"
  mkdir -p "$run_dir"
  printf '%s\n' "$run_dir"
}

pixel_prepare_run_dir() {
  local run_dir
  pixel_prepare_dirs
  run_dir="$(pixel_runs_dir)/$(pixel_timestamp)"
  mkdir -p "$run_dir"
  ln -sfn "$run_dir" "$(pixel_latest_run_link)"
  printf '%s\n' "$run_dir"
}

pixel_latest_run_dir() {
  local link
  link="$(pixel_latest_run_link)"
  if [[ -L "$link" ]]; then
    readlink "$link"
  fi
}

pixel_selected_run_dir() {
  if [[ -n "${PIXEL_RUN_DIR:-}" ]]; then
    printf '%s\n' "$PIXEL_RUN_DIR"
    return 0
  fi
  pixel_latest_run_dir
}

pixel_artifact_path() {
  printf '%s/%s\n' "$(pixel_artifacts_dir)" "$1"
}

pixel_session_artifact() {
  pixel_artifact_path shadow-session
}

pixel_compositor_artifact() {
  pixel_artifact_path shadow-compositor-guest
}

pixel_counter_artifact() {
  pixel_artifact_path shadow-counter-guest
}

pixel_blitz_demo_artifact() {
  pixel_artifact_path shadow-blitz-demo
}

pixel_runtime_app_bundle_artifact() {
  pixel_artifact_path shadow-runtime-app-bundle.js
}

pixel_runtime_host_bundle_artifact_dir() {
  pixel_artifact_path shadow-runtime-gnu
}

pixel_guest_client_artifact() {
  if [[ -n "${PIXEL_GUEST_CLIENT_ARTIFACT:-}" ]]; then
    printf '%s\n' "$PIXEL_GUEST_CLIENT_ARTIFACT"
  else
    pixel_counter_artifact
  fi
}

pixel_session_dst() {
  printf '%s\n' "${PIXEL_SESSION_DST:-/data/local/tmp/shadow-session}"
}

pixel_compositor_dst() {
  printf '%s\n' "${PIXEL_COMPOSITOR_DST:-/data/local/tmp/shadow-compositor-guest}"
}

pixel_counter_dst() {
  printf '%s\n' "${PIXEL_COUNTER_DST:-/data/local/tmp/shadow-counter-guest}"
}

pixel_blitz_demo_dst() {
  printf '%s\n' "${PIXEL_BLITZ_DEMO_DST:-/data/local/tmp/shadow-blitz-demo}"
}

pixel_guest_client_dst() {
  if [[ -n "${PIXEL_GUEST_CLIENT_DST:-}" ]]; then
    printf '%s\n' "$PIXEL_GUEST_CLIENT_DST"
  else
    pixel_counter_dst
  fi
}

pixel_runtime_dir() {
  printf '%s\n' "${PIXEL_RUNTIME_DIR:-/data/local/tmp/shadow-runtime}"
}

pixel_runtime_linux_dir() {
  printf '%s\n' "${PIXEL_RUNTIME_LINUX_DIR:-/data/local/tmp/shadow-runtime-gnu}"
}

pixel_runtime_app_bundle_dst() {
  printf '%s/runtime-app-bundle.js\n' "$(pixel_runtime_linux_dir)"
}

pixel_runtime_host_binary_dst() {
  printf '%s/deno-core-smoke\n' "$(pixel_runtime_linux_dir)"
}

pixel_runtime_host_launcher_dst() {
  printf '%s/run-deno-core-smoke\n' "$(pixel_runtime_linux_dir)"
}

pixel_download_dir_device() {
  printf '%s\n' "${PIXEL_DOWNLOAD_DIR_DEVICE:-/storage/emulated/0/Download}"
}

pixel_frame_path() {
  printf '%s\n' "${PIXEL_FRAME_PATH:-/data/local/tmp/shadow-frame.ppm}"
}

pixel_drm_runs_dir() {
  printf '%s/drm\n' "$(pixel_dir)"
}

pixel_drm_guest_runs_dir() {
  printf '%s/drm-guest\n' "$(pixel_dir)"
}

pixel_runtime_runs_dir() {
  printf '%s/runtime\n' "$(pixel_dir)"
}

pixel_root_ota_url() {
  printf '%s\n' "${PIXEL_ROOT_OTA_URL:-https://ota.googlezip.net/packages/ota-api/package/c4e85817eb7653336a8fe2de681618a9e004b1fb.zip}"
}

pixel_root_ota_zip() {
  printf '%s/%s\n' "$(pixel_root_dir)" "${PIXEL_ROOT_OTA_FILENAME:-sunfish-TQ3A.230805.001.S2-full-ota.zip}"
}

pixel_root_payload_bin() {
  printf '%s/payload.bin\n' "$(pixel_root_dir)"
}

pixel_root_payload_extract_dir() {
  printf '%s/payload-extracted\n' "$(pixel_root_dir)"
}

pixel_root_stock_boot_img() {
  printf '%s/boot.img\n' "$(pixel_root_dir)"
}

pixel_root_magisk_apk() {
  printf '%s/Magisk.apk\n' "$(pixel_root_dir)"
}

pixel_root_magisk_info_json() {
  printf '%s/magisk-release.json\n' "$(pixel_root_dir)"
}

pixel_root_patched_boot_img() {
  printf '%s/magisk_patched.img\n' "$(pixel_root_dir)"
}

pixel_root_magisk_patch_assets_dir() {
  printf '%s/magisk-device-assets\n' "$(pixel_root_dir)"
}

pixel_root_patch_log() {
  printf '%s/magisk-patch.log\n' "$(pixel_root_dir)"
}

pixel_root_device_patch_dir() {
  printf '%s\n' "${PIXEL_ROOT_DEVICE_PATCH_DIR:-/data/local/tmp/shadow-magisk-patch}"
}

pixel_root_device_patched_boot_img() {
  printf '%s/new-boot.img\n' "$(pixel_root_device_patch_dir)"
}

pixel_root_device_boot_img() {
  printf '%s\n' "${PIXEL_ROOT_DEVICE_BOOT_IMG:-$(pixel_download_dir_device)/shadow-stock-boot.img}"
}

pixel_root_device_patched_glob() {
  printf '%s\n' "${PIXEL_ROOT_DEVICE_PATCHED_GLOB:-$(pixel_download_dir_device)/magisk_patched*.img}"
}

pixel_root_expected_fingerprint() {
  printf '%s\n' "${PIXEL_ROOT_EXPECTED_FINGERPRINT:-google/sunfish/sunfish:13/TQ3A.230805.001.S2/12655424:user/release-keys}"
}

pixel_require_expected_fingerprint() {
  local serial context expected actual
  serial="$1"
  context="$2"
  expected="$(pixel_root_expected_fingerprint)"
  actual="$(pixel_prop "$serial" ro.build.fingerprint)"

  if [[ "$actual" == "$expected" ]]; then
    return 0
  fi

  cat <<EOF >&2
$context: device fingerprint does not match the cached stock boot image.
expected: $expected
actual:   $actual

Run 'just pixel-ota-sideload' first, let Android boot, re-enable USB debugging, then retry.
EOF
  return 1
}

pixel_slot_suffix_to_letter() {
  case "$1" in
    _a)
      printf 'a\n'
      ;;
    _b)
      printf 'b\n'
      ;;
    *)
      echo "pixel: unknown slot suffix: $1" >&2
      return 1
      ;;
  esac
}

pixel_boot_partition_for_slot() {
  local slot_letter
  slot_letter="$(pixel_slot_suffix_to_letter "$1")"
  printf 'boot_%s\n' "$slot_letter"
}

pixel_expected_checksum() {
  printf '%s\n' "${PIXEL_EXPECTED_CHECKSUM:-dd64a1693b87ade5}"
}

pixel_expected_size() {
  printf '%s\n' "${PIXEL_EXPECTED_SIZE:-220x120}"
}

pixel_compositor_marker() {
  if [[ -n "${PIXEL_COMPOSITOR_MARKER:-}" ]]; then
    printf '%s\n' "$PIXEL_COMPOSITOR_MARKER"
    return 0
  fi
  printf '[shadow-guest-compositor] captured-frame checksum=%s size=%s\n' \
    "$(pixel_expected_checksum)" \
    "$(pixel_expected_size)"
}

pixel_client_marker() {
  if [[ -n "${PIXEL_CLIENT_MARKER:-}" ]]; then
    printf '%s\n' "$PIXEL_CLIENT_MARKER"
    return 0
  fi
  printf '[shadow-guest-counter] frame-committed checksum=%s size=%s\n' \
    "$(pixel_expected_checksum)" \
    "$(pixel_expected_size)"
}

pixel_require_runtime_artifacts() {
  local path missing
  missing=0
  for path in \
    "$(pixel_session_artifact)" \
    "$(pixel_compositor_artifact)" \
    "$(pixel_guest_client_artifact)"; do
    if [[ ! -f "$path" ]]; then
      echo "pixel: missing built artifact: $path" >&2
      missing=1
    fi
  done
  if [[ -n "${PIXEL_RUNTIME_APP_BUNDLE_ARTIFACT:-}" && ! -f "${PIXEL_RUNTIME_APP_BUNDLE_ARTIFACT}" ]]; then
    echo "pixel: missing runtime app bundle artifact: ${PIXEL_RUNTIME_APP_BUNDLE_ARTIFACT}" >&2
    missing=1
  fi
  if [[ -n "${PIXEL_RUNTIME_HOST_BUNDLE_ARTIFACT_DIR:-}" && ! -d "${PIXEL_RUNTIME_HOST_BUNDLE_ARTIFACT_DIR}" ]]; then
    echo "pixel: missing runtime host bundle artifact dir: ${PIXEL_RUNTIME_HOST_BUNDLE_ARTIFACT_DIR}" >&2
    missing=1
  fi
  return "$missing"
}

pixel_capture_props() {
  local serial output
  serial="$1"
  output="$2"
  pixel_adb "$serial" shell getprop >"$output"
}

pixel_capture_processes() {
  local serial output
  serial="$1"
  output="$2"
  pixel_adb "$serial" shell 'ps -A -o USER,PID,PPID,NAME,ARGS 2>/dev/null | grep -E "shadow|wayland" || true' >"$output"
}

pixel_write_status_json() {
  local output
  output="$1"
  shift
  python3 - "$output" "$@" <<'PY'
import json
import sys

output = sys.argv[1]
data = {}
for item in sys.argv[2:]:
    key, value = item.split("=", 1)
    if value == "true":
        data[key] = True
    elif value == "false":
        data[key] = False
    else:
        try:
            data[key] = int(value)
        except ValueError:
            data[key] = value

with open(output, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

pixel_download_file() {
  local url output
  url="$1"
  output="$2"
  curl -L --fail --retry 3 --retry-delay 2 -o "$output.tmp" "$url"
  mv "$output.tmp" "$output"
}

pixel_wait_for_fastboot() {
  local serial timeout
  serial="$1"
  timeout="${2:-60}"
  for _ in $(seq 1 "$timeout"); do
    if fastboot devices | awk '$2 == "fastboot" { print $1 }' | grep -Fxq "$serial"; then
      return 0
    fi
    sleep 1
  done
  echo "pixel: timed out waiting for fastboot device $serial" >&2
  return 1
}

pixel_wait_for_adb() {
  local serial timeout
  serial="$1"
  timeout="${2:-120}"
  for _ in $(seq 1 "$timeout"); do
    if pixel_connected_serials | grep -Fxq "$serial"; then
      return 0
    fi
    sleep 1
  done
  echo "pixel: timed out waiting for adb device $serial" >&2
  return 1
}

pixel_wait_for_sideload() {
  local serial timeout
  serial="$1"
  timeout="${2:-300}"
  for _ in $(seq 1 "$timeout"); do
    if pixel_connected_sideload_serials | grep -Fxq "$serial"; then
      return 0
    fi
    sleep 1
  done
  echo "pixel: timed out waiting for adb sideload mode on $serial" >&2
  return 1
}

pixel_wait_for_boot_completed() {
  local serial timeout
  serial="$1"
  timeout="${2:-240}"
  for _ in $(seq 1 "$timeout"); do
    if [[ "$(pixel_prop "$serial" sys.boot_completed)" == "1" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "pixel: timed out waiting for Android boot completion on $serial" >&2
  return 1
}
