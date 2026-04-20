#!/usr/bin/env bash

pixel_connected_serials() {
  adb devices | awk 'NR > 1 && $2 == "device" { print $1 }'
}

pixel_connected_fastboot_serials() {
  fastboot devices | awk '$2 == "fastboot" { print $1 }'
}

pixel_connected_sideload_serials() {
  adb devices | awk 'NR > 1 && $2 == "sideload" { print $1 }'
}

pixel_resolve_serial() {
  local requested serial serials
  requested="${PIXEL_SERIAL:-}"

  if [[ -n "$requested" ]]; then
    if pixel_connected_serials | grep -Fxq "$requested"; then
      printf '%s\n' "$requested"
      return 0
    fi
    echo "pixel: requested PIXEL_SERIAL is not connected and authorized: $requested" >&2
    return 1
  fi

  serials=()
  while IFS= read -r serial; do
    [[ -n "$serial" ]] || continue
    serials+=("$serial")
  done < <(pixel_connected_serials)
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
  local requested serial serials
  requested="${PIXEL_SERIAL:-}"

  if [[ -n "$requested" ]]; then
    if pixel_connected_sideload_serials | grep -Fxq "$requested"; then
      printf '%s\n' "$requested"
      return 0
    fi
    echo "pixel: requested PIXEL_SERIAL is not connected in adb sideload mode: $requested" >&2
    return 1
  fi

  serials=()
  while IFS= read -r serial; do
    [[ -n "$serial" ]] || continue
    serials+=("$serial")
  done < <(pixel_connected_sideload_serials)
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

pixel_resolve_fastboot_serial() {
  local requested serial serials
  requested="${PIXEL_SERIAL:-}"

  if [[ -n "$requested" ]]; then
    if pixel_connected_fastboot_serials | grep -Fxq "$requested"; then
      printf '%s\n' "$requested"
      return 0
    fi
    echo "pixel: requested PIXEL_SERIAL is not connected in fastboot mode: $requested" >&2
    return 1
  fi

  serials=()
  while IFS= read -r serial; do
    [[ -n "$serial" ]] || continue
    serials+=("$serial")
  done < <(pixel_connected_fastboot_serials)
  case "${#serials[@]}" in
    0)
      echo "pixel: no fastboot device detected" >&2
      return 1
      ;;
    1)
      printf '%s\n' "${serials[0]}"
      ;;
    *)
      echo "pixel: multiple fastboot devices detected; set PIXEL_SERIAL" >&2
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

pixel_adb_reverse_tcp() {
  local serial port
  serial="$1"
  port="$2"
  pixel_adb "$serial" reverse "tcp:$port" "tcp:$port"
}

pixel_adb_reverse_remove_tcp() {
  local serial port
  serial="$1"
  port="$2"
  pixel_adb "$serial" reverse --remove "tcp:$port"
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
    if printf '%s\n' "$command" | pixel_adb "$serial" shell "$su_bin" 0 sh; then
      return 0
    fi
  done < <(pixel_su_candidates)

  return 1
}

pixel_prop() {
  local serial key
  serial="$1"
  key="$2"
  pixel_adb "$serial" shell getprop "$key" | tr -d '\r'
}

pixel_display_size() {
  local serial size
  serial="$1"
  size="$(
    timeout "${PIXEL_ADB_QUERY_TIMEOUT_SECS:-5}" adb -s "$serial" shell wm size 2>/dev/null \
      | tr -d '\r' \
      | grep -Eo '[0-9]+x[0-9]+' \
      | head -n1 \
      || true
  )"
  if [[ -z "$size" ]]; then
    size="$(
      pixel_root_shell "$serial" '
        for f in /sys/class/drm/*/modes; do
          case "$f" in
            *Virtual*) continue ;;
          esac
          [ -r "$f" ] || continue
          while IFS= read -r mode; do
            printf "%s\n" "$mode"
            exit 0
          done < "$f"
        done
        if [ -r /sys/class/graphics/fb0/virtual_size ]; then
          cat /sys/class/graphics/fb0/virtual_size
          exit 0
        fi
        exit 1
      ' 2>/dev/null \
        | tr -d '\r' \
        | grep -Eo '[0-9]+x[0-9]+' \
        | head -n1 \
        || true
    )"
  fi
  if [[ -z "$size" ]]; then
    echo "pixel: failed to determine display size via 'wm size' or rooted DRM sysfs" >&2
    return 1
  fi
  printf '%s\n' "$size"
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

pixel_reboot_and_wait_android_display() {
  local serial timeout_secs
  serial="$1"
  timeout_secs="${2:-120}"

  pixel_adb "$serial" reboot >/dev/null 2>&1 || return 1
  pixel_wait_for_adb "$serial" "$timeout_secs" >/dev/null 2>&1 || return 1
  pixel_wait_for_boot_completed "$serial" "$timeout_secs" >/dev/null 2>&1 || return 1
  pixel_wait_for_condition "$timeout_secs" 1 pixel_android_display_restored "$serial"
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

pixel_last_json_ok() {
  local input
  input="$1"
  python3 - "$input" <<'PY'
import json
import sys

path = sys.argv[1]
payload = None

with open(path, "r", encoding="utf-8", errors="replace") as fh:
    for raw_line in fh:
        line = raw_line.strip()
        if not line.startswith("{") or not line.endswith("}"):
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue

if not isinstance(payload, dict) or "ok" not in payload:
    sys.exit(2)

sys.exit(0 if payload.get("ok") is True else 1)
PY
}

pixel_wait_for_fastboot() {
  local serial timeout
  serial="$1"
  timeout="${2:-60}"
  for _ in $(seq 1 "$timeout"); do
    if pixel_connected_fastboot_serials | grep -Fxq "$serial"; then
      return 0
    fi
    sleep 1
  done
  echo "pixel: timed out waiting for fastboot device $serial" >&2
  return 1
}

pixel_fastboot_device_present() {
  local serial
  serial="$1"
  pixel_connected_fastboot_serials | grep -Fxq "$serial"
}

pixel_fastboot_device_absent() {
  local serial
  serial="$1"
  ! pixel_fastboot_device_present "$serial"
}

pixel_reset_fastboot_cycle_status() {
  PIXEL_FASTBOOT_CYCLE_DEPARTED=false
  PIXEL_FASTBOOT_CYCLE_RETURNED=false
  PIXEL_FASTBOOT_CYCLE_LEAVE_ELAPSED_SECS=0
  PIXEL_FASTBOOT_CYCLE_RETURN_ELAPSED_SECS=0
  PIXEL_FASTBOOT_CYCLE_TOTAL_ELAPSED_SECS=0
}

pixel_wait_for_fastboot_cycle() {
  local serial leave_timeout_secs return_timeout_secs cycle_started_at departed_at
  serial="$1"
  leave_timeout_secs="${2:-15}"
  return_timeout_secs="${3:-45}"

  pixel_reset_fastboot_cycle_status
  cycle_started_at=$SECONDS

  if ! pixel_wait_for_condition "$leave_timeout_secs" 1 pixel_fastboot_device_absent "$serial"; then
    PIXEL_FASTBOOT_CYCLE_LEAVE_ELAPSED_SECS=$((SECONDS - cycle_started_at))
    PIXEL_FASTBOOT_CYCLE_TOTAL_ELAPSED_SECS="$PIXEL_FASTBOOT_CYCLE_LEAVE_ELAPSED_SECS"
    echo "pixel: timed out waiting for fastboot device $serial to leave fastboot" >&2
    return 1
  fi

  PIXEL_FASTBOOT_CYCLE_DEPARTED=true
  departed_at=$SECONDS
  PIXEL_FASTBOOT_CYCLE_LEAVE_ELAPSED_SECS=$((departed_at - cycle_started_at))

  if ! pixel_wait_for_condition "$return_timeout_secs" 1 pixel_fastboot_device_present "$serial"; then
    PIXEL_FASTBOOT_CYCLE_RETURN_ELAPSED_SECS=$((SECONDS - departed_at))
    PIXEL_FASTBOOT_CYCLE_TOTAL_ELAPSED_SECS=$((SECONDS - cycle_started_at))
    echo "pixel: timed out waiting for fastboot device $serial to return after leaving fastboot" >&2
    return 1
  fi

  PIXEL_FASTBOOT_CYCLE_RETURNED=true
  PIXEL_FASTBOOT_CYCLE_RETURN_ELAPSED_SECS=$((SECONDS - departed_at))
  PIXEL_FASTBOOT_CYCLE_TOTAL_ELAPSED_SECS=$((SECONDS - cycle_started_at))
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
