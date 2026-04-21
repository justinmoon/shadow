#!/usr/bin/env bash

PIXEL_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHADOW_SCRIPT_ROOT="$(cd "$PIXEL_COMMON_DIR/.." && pwd)"
# shellcheck source=./shadow_common.sh
source "$PIXEL_COMMON_DIR/shadow_common.sh"
# shellcheck source=./pixel_device_transport_common.sh
source "$PIXEL_COMMON_DIR/pixel_device_transport_common.sh"
# shellcheck source=./pixel_runtime_session_common.sh
source "$PIXEL_COMMON_DIR/pixel_runtime_session_common.sh"
# shellcheck source=./pixel_display_session_common.sh
source "$PIXEL_COMMON_DIR/pixel_display_session_common.sh"
# shellcheck source=./pixel_root_boot_common.sh
source "$PIXEL_COMMON_DIR/pixel_root_boot_common.sh"

pixel_dir() {
  printf '%s/pixel\n' "$(build_dir)"
}

pixel_artifacts_dir() {
  printf '%s/artifacts\n' "$(pixel_dir)"
}

pixel_root_dir() {
  printf '%s/root\n' "$(pixel_dir)"
}

pixel_shared_dir() {
  printf '%s/build/shared/pixel\n' "$(repo_common_root)"
}

pixel_shared_root_dir() {
  printf '%s/root\n' "$(pixel_shared_dir)"
}

pixel_boot_dir() {
  printf '%s/boot\n' "$(pixel_dir)"
}

pixel_boot_oneshots_dir() {
  printf '%s/oneshot\n' "$(pixel_boot_dir)"
}

pixel_boot_unpacks_dir() {
  printf '%s/unpack\n' "$(pixel_boot_dir)"
}

pixel_boot_init_wrapper_bin() {
  printf '%s/init-wrapper\n' "$(pixel_boot_dir)"
}

pixel_boot_init_wrapper_bin_for_mode() {
  local wrapper_mode
  wrapper_mode="${1:-standard}"

  case "$wrapper_mode" in
    standard)
      pixel_boot_init_wrapper_bin
      ;;
    minimal)
      printf '%s/init-wrapper-minimal\n' "$(pixel_boot_dir)"
      ;;
    *)
      echo "pixel: unsupported init wrapper mode: $wrapper_mode" >&2
      return 1
      ;;
  esac
}

pixel_other_wrapper_mode() {
  local wrapper_mode
  wrapper_mode="${1:-standard}"

  case "$wrapper_mode" in
    standard)
      printf 'minimal\n'
      ;;
    minimal)
      printf 'standard\n'
      ;;
    *)
      echo "pixel: unsupported init wrapper mode: $wrapper_mode" >&2
      return 1
      ;;
  esac
}

pixel_init_wrapper_mode_sentinel() {
  local wrapper_mode
  wrapper_mode="${1:-standard}"
  printf 'shadow-init-wrapper-mode:%s\n' "$wrapper_mode"
}

pixel_wrapper_binary_matches_mode() {
  local wrapper_path wrapper_mode sentinel
  wrapper_path="${1:?pixel_wrapper_binary_matches_mode requires a wrapper path}"
  wrapper_mode="${2:?pixel_wrapper_binary_matches_mode requires a wrapper mode}"
  sentinel="$(pixel_init_wrapper_mode_sentinel "$wrapper_mode")"
  grep -aFq -- "$sentinel" "$wrapper_path"
}

pixel_assert_wrapper_binary_mode() {
  local wrapper_path wrapper_mode
  wrapper_path="${1:?pixel_assert_wrapper_binary_mode requires a wrapper path}"
  wrapper_mode="${2:?pixel_assert_wrapper_binary_mode requires a wrapper mode}"

  if ! pixel_wrapper_binary_matches_mode "$wrapper_path" "$wrapper_mode"; then
    cat <<EOF >&2
pixel: init-wrapper binary does not match requested mode '$wrapper_mode': $wrapper_path

Rebuild the matching wrapper with:
  scripts/pixel/pixel_build_init_wrapper.sh --mode $wrapper_mode
EOF
    return 1
  fi
}

pixel_assert_wrapper_cache_path_mode() {
  local wrapper_path wrapper_mode opposite_mode opposite_path
  wrapper_path="${1:?pixel_assert_wrapper_cache_path_mode requires a wrapper path}"
  wrapper_mode="${2:?pixel_assert_wrapper_cache_path_mode requires a wrapper mode}"
  opposite_mode="$(pixel_other_wrapper_mode "$wrapper_mode")"
  opposite_path="$(pixel_boot_init_wrapper_bin_for_mode "$opposite_mode")"

  if [[ "$wrapper_path" == "$opposite_path" ]]; then
    cat <<EOF >&2
pixel: wrapper path conflicts with requested mode '$wrapper_mode': $wrapper_path

Use the matching cache path instead:
  $(pixel_boot_init_wrapper_bin_for_mode "$wrapper_mode")
EOF
    return 1
  fi
}

pixel_boot_custom_boot_img() {
  printf '%s/shadow-boot-wrapper.img\n' "$(pixel_boot_dir)"
}

pixel_boot_custom_boot_img_for_wrapper_mode() {
  local wrapper_mode
  wrapper_mode="${1:-standard}"

  case "$wrapper_mode" in
    standard)
      pixel_boot_custom_boot_img
      ;;
    minimal)
      printf '%s/shadow-boot-wrapper-minimal.img\n' "$(pixel_boot_dir)"
      ;;
    *)
      echo "pixel: unsupported init wrapper mode: $wrapper_mode" >&2
      return 1
      ;;
  esac
}

pixel_boot_log_probe_img() {
  printf '%s/shadow-boot-log-probe.img\n' "$(pixel_boot_dir)"
}

pixel_boot_logs_dir() {
  printf '%s/logs\n' "$(pixel_boot_dir)"
}

pixel_boot_flash_runs_dir() {
  printf '%s/flash-run\n' "$(pixel_boot_dir)"
}

pixel_boot_device_log_root() {
  printf '%s\n' "${PIXEL_BOOT_DEVICE_LOG_ROOT:-/data/local/tmp/shadow-boot}"
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

pixel_serial_lock_key() {
  local serial
  serial="${1:?pixel_serial_lock_key requires a serial}"

  printf '%s\n' "$serial" | tr -c 'A-Za-z0-9._-' '_'
}

pixel_serial_lock_path() {
  local serial lock_dir lock_key
  serial="${1:?pixel_serial_lock_path requires a serial}"
  lock_dir="$(pixel_dir)/locks"
  lock_key="$(pixel_serial_lock_key "$serial")"

  mkdir -p "$lock_dir"
  printf '%s/%s.lock\n' "$lock_dir" "$lock_key"
}

pixel_require_host_lock() {
  local serial script_path script_name lock_path
  serial="${1:?pixel_require_host_lock requires a serial}"
  script_path="${2:?pixel_require_host_lock requires a script path}"
  shift 2

  if [[ "${PIXEL_HOST_LOCK_HELD_SERIAL:-}" == "$serial" ]]; then
    return 0
  fi

  lock_path="$(pixel_serial_lock_path "$serial")"
  script_name="$(basename "$script_path")"
  if ! lockf -st 0 "$lock_path" true 2>/dev/null; then
    printf '%s: waiting for host lock on Pixel %s\n' "$script_name" "$serial" >&2
  fi

  exec env PIXEL_HOST_LOCK_HELD_SERIAL="$serial" \
    lockf "$lock_path" "$script_path" "$@"
}

pixel_retryable_nix_build_failure() {
  local log_path
  log_path="$1"

  grep -Eq \
    'Nix daemon disconnected unexpectedly|failed to read from remote builder|failed to start SSH connection to|Failed to find a machine for remote build|writing to file: Broken pipe|unexpected end-of-file|Connection reset by peer' \
    "$log_path"
}

pixel_flush_appended_stderr() {
  local log_path emitted_bytes total_bytes
  log_path="${1:?pixel_flush_appended_stderr requires a log path}"
  emitted_bytes="${2:-0}"

  if [[ ! -f "$log_path" ]]; then
    printf '%s\n' "$emitted_bytes"
    return 0
  fi

  total_bytes="$(wc -c <"$log_path" | tr -d '[:space:]')"
  if (( total_bytes > emitted_bytes )); then
    tail -c "+$((emitted_bytes + 1))" "$log_path" >&2 || true
  fi

  printf '%s\n' "$total_bytes"
}

pixel_retry_nix_build() {
  local attempt max_attempts retry_sleep_secs heartbeat_secs status log_path pid started_at next_heartbeat old_term_trap old_int_trap
  max_attempts="${PIXEL_NIX_BUILD_RETRIES:-3}"
  retry_sleep_secs="${PIXEL_NIX_BUILD_RETRY_SLEEP_SECS:-3}"
  heartbeat_secs="${PIXEL_NIX_BUILD_HEARTBEAT_SECS:-30}"
  log_path="$(mktemp "${TMPDIR:-/tmp}/pixel-nix-build.XXXXXX")"
  old_term_trap="$(trap -p TERM || true)"
  old_int_trap="$(trap -p INT || true)"

  for attempt in $(seq 1 "$max_attempts"); do
    pid=""
    "$@" >"$log_path" 2>&1 &
    pid=$!
    trap '
      if [[ -n "${pid:-}" ]] && kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
      fi
      exit 143
    ' TERM
    trap '
      if [[ -n "${pid:-}" ]] && kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
      fi
      exit 130
    ' INT
    started_at="$SECONDS"
    next_heartbeat=$((started_at + heartbeat_secs))
    while kill -0 "$pid" >/dev/null 2>&1; do
      sleep 1
      if (( heartbeat_secs > 0 && SECONDS >= next_heartbeat )); then
        printf 'pixel: nix build still running (%ss elapsed): %s\n' \
          "$((SECONDS - started_at))" \
          "$*" >&2
        next_heartbeat=$((SECONDS + heartbeat_secs))
      fi
    done

    if wait "$pid"; then
      pid=""
      cat "$log_path"
      if [[ -n "$old_term_trap" ]]; then
        eval "$old_term_trap"
      else
        trap - TERM
      fi
      if [[ -n "$old_int_trap" ]]; then
        eval "$old_int_trap"
      else
        trap - INT
      fi
      rm -f "$log_path"
      return 0
    fi

    pid=""
    status="$?"
    if [[ -n "$old_term_trap" ]]; then
      eval "$old_term_trap"
    else
      trap - TERM
    fi
    if [[ -n "$old_int_trap" ]]; then
      eval "$old_int_trap"
    else
      trap - INT
    fi
    if (( attempt == max_attempts )) || ! pixel_retryable_nix_build_failure "$log_path"; then
      cat "$log_path" >&2
      rm -f "$log_path"
      return "$status"
    fi

    printf 'pixel: retrying transient nix build failure (%s/%s)\n' "$attempt" "$max_attempts" >&2
    tail -n 80 "$log_path" >&2 || true
    sleep "$retry_sleep_secs"
  done

  rm -f "$log_path"
  return 1
}

pixel_retry_nix_build_print_out_paths() {
  local attempt max_attempts retry_sleep_secs heartbeat_secs status stdout_log stderr_log combined_log pid started_at next_heartbeat old_term_trap old_int_trap stderr_emitted_bytes
  max_attempts="${PIXEL_NIX_BUILD_RETRIES:-3}"
  retry_sleep_secs="${PIXEL_NIX_BUILD_RETRY_SLEEP_SECS:-3}"
  heartbeat_secs="${PIXEL_NIX_BUILD_HEARTBEAT_SECS:-30}"
  stdout_log="$(mktemp "${TMPDIR:-/tmp}/pixel-nix-build-stdout.XXXXXX")"
  stderr_log="$(mktemp "${TMPDIR:-/tmp}/pixel-nix-build-stderr.XXXXXX")"
  combined_log="$(mktemp "${TMPDIR:-/tmp}/pixel-nix-build-combined.XXXXXX")"
  old_term_trap="$(trap -p TERM || true)"
  old_int_trap="$(trap -p INT || true)"

  for attempt in $(seq 1 "$max_attempts"); do
    pid=""
    stderr_emitted_bytes=0
    "$@" >"$stdout_log" 2>"$stderr_log" &
    pid=$!
    trap '
      if [[ -n "${pid:-}" ]] && kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
      fi
      exit 143
    ' TERM
    trap '
      if [[ -n "${pid:-}" ]] && kill -0 "$pid" >/dev/null 2>&1; then
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
      fi
      exit 130
    ' INT
    started_at="$SECONDS"
    next_heartbeat=$((started_at + heartbeat_secs))
    while kill -0 "$pid" >/dev/null 2>&1; do
      sleep 1
      stderr_emitted_bytes="$(pixel_flush_appended_stderr "$stderr_log" "$stderr_emitted_bytes")"
      if (( heartbeat_secs > 0 && SECONDS >= next_heartbeat )); then
        printf 'pixel: nix build still running (%ss elapsed): %s\n' \
          "$((SECONDS - started_at))" \
          "$*" >&2
        next_heartbeat=$((SECONDS + heartbeat_secs))
      fi
    done

    stderr_emitted_bytes="$(pixel_flush_appended_stderr "$stderr_log" "$stderr_emitted_bytes")"
    if wait "$pid"; then
      pid=""
      cat "$stdout_log"
      if [[ -n "$old_term_trap" ]]; then
        eval "$old_term_trap"
      else
        trap - TERM
      fi
      if [[ -n "$old_int_trap" ]]; then
        eval "$old_int_trap"
      else
        trap - INT
      fi
      rm -f "$stdout_log" "$stderr_log" "$combined_log"
      return 0
    fi

    pid=""
    status="$?"
    if [[ -n "$old_term_trap" ]]; then
      eval "$old_term_trap"
    else
      trap - TERM
    fi
    if [[ -n "$old_int_trap" ]]; then
      eval "$old_int_trap"
    else
      trap - INT
    fi
    cat "$stdout_log" "$stderr_log" >"$combined_log"
    if (( attempt == max_attempts )) || ! pixel_retryable_nix_build_failure "$combined_log"; then
      cat "$stdout_log" >&2
      rm -f "$stdout_log" "$stderr_log" "$combined_log"
      return "$status"
    fi

    printf 'pixel: retrying transient nix build print-out-paths failure (%s/%s)\n' "$attempt" "$max_attempts" >&2
    tail -n 80 "$combined_log" >&2 || true
    sleep "$retry_sleep_secs"
  done

  rm -f "$stdout_log" "$stderr_log" "$combined_log"
  return 1
}

pixel_host_local_port() {
  local service_key
  service_key="${1:?pixel_host_local_port requires a service key}"

  python3 - "$(repo_root)" "$service_key" <<'PY'
import hashlib
import sys

repo_root, service_key = sys.argv[1], sys.argv[2]
base = 40000
span = 4000
digest = hashlib.sha256(f"{repo_root}:{service_key}".encode("utf-8")).hexdigest()
print(base + (int(digest[:8], 16) % span))
PY
}

pixel_nostr_local_relay_port() {
  if [[ -n "${PIXEL_NOSTR_LOCAL_RELAY_PORT:-}" ]]; then
    printf '%s\n' "$PIXEL_NOSTR_LOCAL_RELAY_PORT"
    return 0
  fi
  pixel_host_local_port pixel-nostr-local-relay
}

pixel_touchscreen_event_device() {
  local serial listing device
  serial="$1"
  listing="$(pixel_adb "$serial" shell getevent -pl 2>/dev/null | tr -d '\r')"
  device="$(
    printf '%s\n' "$listing" | awk '
      /^add device/ {
        if (device != "" && direct && has_x && has_y) {
          print device
          found=1
          exit
        }
        device=$4
        direct=0
        has_x=0
        has_y=0
        next
      }
      /ABS_MT_POSITION_X/ { has_x=1 }
      /ABS_MT_POSITION_Y/ { has_y=1 }
      /INPUT_PROP_DIRECT/ { direct=1 }
      END {
        if (!found && device != "" && direct && has_x && has_y) {
          print device
        }
      }
    '
  )"

  if [[ -z "$device" ]]; then
    echo "pixel: failed to detect a direct-touch input device from 'getevent -pl'" >&2
    return 1
  fi

  printf '%s\n' "$device"
}

pixel_touchscreen_device_info_json() {
  local serial device listing
  serial="$1"
  device="$(pixel_touchscreen_event_device "$serial")" || return 1
  listing="$(pixel_adb "$serial" shell getevent -pl "$device" 2>/dev/null | tr -d '\r')"

  DEVICE_PATH="$device" GETEVENT_LISTING="$listing" python3 - <<'PY'
import json
import os
import re
import sys

device_path = os.environ["DEVICE_PATH"]
listing = os.environ["GETEVENT_LISTING"]

axis_pattern = re.compile(
    r"ABS_MT_POSITION_(?P<axis>[XY])\s*: value \d+, min (?P<min>-?\d+), max (?P<max>-?\d+)"
)
x_min = x_max = y_min = y_max = None
for raw_line in listing.splitlines():
    line = raw_line.strip()
    match = axis_pattern.search(line)
    if not match:
      continue
    axis = match.group("axis")
    axis_min = int(match.group("min"))
    axis_max = int(match.group("max"))
    if axis == "X":
      x_min = axis_min
      x_max = axis_max
    else:
      y_min = axis_min
      y_max = axis_max

if None in (x_min, x_max, y_min, y_max):
    raise SystemExit("pixel: failed to parse ABS_MT_POSITION ranges from getevent -pl")

print(
    json.dumps(
        {
            "devicePath": device_path,
            "xMin": x_min,
            "xMax": x_max,
            "yMin": y_min,
            "yMax": y_max,
        }
    )
)
PY
}

pixel_touchscreen_tap_panel() {
  local serial panel_x panel_y panel_size touch_json tap_script
  serial="$1"
  panel_x="$2"
  panel_y="$3"
  panel_size="${4-}"
  if [[ -z "$panel_size" ]]; then
    panel_size="$(pixel_display_size "$serial")"
  fi
  touch_json="$(pixel_touchscreen_device_info_json "$serial")"
  tap_script="$(
    PANEL_SIZE="$panel_size" \
    PANEL_X="$panel_x" \
    PANEL_Y="$panel_y" \
    TOUCH_JSON="$touch_json" \
    python3 - <<'PY'
import json
import os

panel_w, panel_h = [int(part) for part in os.environ["PANEL_SIZE"].split("x", 1)]
panel_x = int(os.environ["PANEL_X"])
panel_y = int(os.environ["PANEL_Y"])
touch = json.loads(os.environ["TOUCH_JSON"])

def scale(panel_value: int, panel_extent: int, raw_min: int, raw_max: int) -> int:
    if panel_extent <= 1:
        return raw_min
    normalized = max(0.0, min(1.0, panel_value / float(panel_extent - 1)))
    return round(raw_min + normalized * (raw_max - raw_min))

def nudge(value: int, raw_min: int, raw_max: int) -> int:
    if value > raw_min:
        return value - 1
    if value < raw_max:
        return value + 1
    return value

raw_x = scale(panel_x, panel_w, int(touch["xMin"]), int(touch["xMax"]))
raw_y = scale(panel_y, panel_h, int(touch["yMin"]), int(touch["yMax"]))
raw_x_nudge = nudge(raw_x, int(touch["xMin"]), int(touch["xMax"]))
raw_y_nudge = nudge(raw_y, int(touch["yMin"]), int(touch["yMax"]))
tracking_id = 4242
device_path = touch["devicePath"]

print(
    "\n".join(
        [
            f"sendevent {device_path} 3 47 0",
            f"sendevent {device_path} 3 57 {tracking_id}",
            f"sendevent {device_path} 3 53 {raw_x_nudge}",
            f"sendevent {device_path} 3 54 {raw_y_nudge}",
            f"sendevent {device_path} 3 53 {raw_x}",
            f"sendevent {device_path} 3 54 {raw_y}",
            f"sendevent {device_path} 3 48 20",
            f"sendevent {device_path} 3 58 30",
            f"sendevent {device_path} 1 330 1",
            f"sendevent {device_path} 0 0 0",
            "sleep 0.05",
            f"sendevent {device_path} 3 47 0",
            f"sendevent {device_path} 3 57 -1",
            f"sendevent {device_path} 1 330 0",
            f"sendevent {device_path} 0 0 0",
        ]
    )
)
PY
  )"

  pixel_root_shell "$serial" "$tap_script"
}

pixel_touchscreen_swipe_panel() {
  local serial start_x start_y end_x end_y panel_size duration_ms steps touch_json swipe_script
  serial="$1"
  start_x="$2"
  start_y="$3"
  end_x="$4"
  end_y="$5"
  panel_size="${6-}"
  duration_ms="${7:-220}"
  steps="${8:-18}"
  if [[ -z "$panel_size" ]]; then
    panel_size="$(pixel_display_size "$serial")"
  fi
  touch_json="$(pixel_touchscreen_device_info_json "$serial")"
  swipe_script="$(
    PANEL_SIZE="$panel_size" \
    START_X="$start_x" \
    START_Y="$start_y" \
    END_X="$end_x" \
    END_Y="$end_y" \
    DURATION_MS="$duration_ms" \
    STEPS="$steps" \
    TOUCH_JSON="$touch_json" \
    python3 - <<'PY'
import json
import os

panel_w, panel_h = [int(part) for part in os.environ["PANEL_SIZE"].split("x", 1)]
start_x = int(os.environ["START_X"])
start_y = int(os.environ["START_Y"])
end_x = int(os.environ["END_X"])
end_y = int(os.environ["END_Y"])
duration_ms = max(0, int(os.environ["DURATION_MS"]))
steps = max(2, int(os.environ["STEPS"]))
touch = json.loads(os.environ["TOUCH_JSON"])

def scale(panel_value: int, panel_extent: int, raw_min: int, raw_max: int) -> int:
    if panel_extent <= 1:
        return raw_min
    normalized = max(0.0, min(1.0, panel_value / float(panel_extent - 1)))
    return round(raw_min + normalized * (raw_max - raw_min))

def nudge(value: int, raw_min: int, raw_max: int) -> int:
    if value > raw_min:
        return value - 1
    if value < raw_max:
        return value + 1
    return value

def lerp(start: int, end: int, index: int, total: int) -> int:
    if total <= 1:
        return start
    return round(start + (end - start) * index / float(total - 1))

sleep_secs = duration_ms / 1000.0 / max(1, steps - 1)
tracking_id = 4243
device_path = touch["devicePath"]
raw_points = [
    (
        scale(lerp(start_x, end_x, index, steps), panel_w, int(touch["xMin"]), int(touch["xMax"])),
        scale(lerp(start_y, end_y, index, steps), panel_h, int(touch["yMin"]), int(touch["yMax"])),
    )
    for index in range(steps)
]
raw_x_nudge = nudge(raw_points[0][0], int(touch["xMin"]), int(touch["xMax"]))
raw_y_nudge = nudge(raw_points[0][1], int(touch["yMin"]), int(touch["yMax"]))

lines = [
    f"sendevent {device_path} 3 47 0",
    f"sendevent {device_path} 3 57 {tracking_id}",
    f"sendevent {device_path} 3 53 {raw_x_nudge}",
    f"sendevent {device_path} 3 54 {raw_y_nudge}",
    f"sendevent {device_path} 3 53 {raw_points[0][0]}",
    f"sendevent {device_path} 3 54 {raw_points[0][1]}",
    f"sendevent {device_path} 3 48 20",
    f"sendevent {device_path} 3 58 30",
    f"sendevent {device_path} 1 330 1",
    f"sendevent {device_path} 0 0 0",
]

for raw_x, raw_y in raw_points[1:]:
    lines.extend(
        [
            f"sendevent {device_path} 3 47 0",
            f"sendevent {device_path} 3 53 {raw_x}",
            f"sendevent {device_path} 3 54 {raw_y}",
            f"sendevent {device_path} 0 0 0",
            f"sleep {sleep_secs:.4f}",
        ]
    )

lines.extend(
    [
        f"sendevent {device_path} 3 47 0",
        f"sendevent {device_path} 3 57 -1",
        f"sendevent {device_path} 1 330 0",
        f"sendevent {device_path} 0 0 0",
    ]
)

print("\n".join(lines))
PY
  )"

  pixel_root_shell "$serial" "$swipe_script"
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
  local path missing guest_client_artifact
  missing=0
  guest_client_artifact="$(pixel_guest_client_artifact)" || return 1
  for path in \
    "$(pixel_session_artifact)" \
    "$(pixel_compositor_artifact)" \
    "$guest_client_artifact"; do
    if [[ ! -f "$path" ]]; then
      echo "pixel: missing built artifact: $path" >&2
      missing=1
    fi
  done
  if [[ -n "${PIXEL_RUNTIME_APP_BUNDLE_ARTIFACT:-}" && ! -f "${PIXEL_RUNTIME_APP_BUNDLE_ARTIFACT}" ]]; then
    echo "pixel: missing runtime app bundle artifact: ${PIXEL_RUNTIME_APP_BUNDLE_ARTIFACT}" >&2
    missing=1
  fi
  if [[ -n "${PIXEL_SYSTEM_BUNDLE_ARTIFACT_DIR:-}" && ! -d "${PIXEL_SYSTEM_BUNDLE_ARTIFACT_DIR}" ]]; then
    echo "pixel: missing system bundle artifact dir: ${PIXEL_SYSTEM_BUNDLE_ARTIFACT_DIR}" >&2
    missing=1
  fi
  return "$missing"
}

pixel_download_file() {
  local url output
  url="$1"
  output="$2"
  curl -L --fail --retry 3 --retry-delay 2 -o "$output.tmp" "$url"
  mv "$output.tmp" "$output"
}
