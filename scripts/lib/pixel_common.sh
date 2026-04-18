#!/usr/bin/env bash

PIXEL_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHADOW_SCRIPT_ROOT="$(cd "$PIXEL_COMMON_DIR/.." && pwd)"
# shellcheck source=./shadow_common.sh
source "$PIXEL_COMMON_DIR/shadow_common.sh"

pixel_dir() {
  printf '%s/pixel\n' "$(build_dir)"
}

pixel_artifacts_dir() {
  printf '%s/artifacts\n' "$(pixel_dir)"
}

pixel_root_dir() {
  printf '%s/root\n' "$(pixel_dir)"
}

pixel_boot_dir() {
  printf '%s/boot\n' "$(pixel_dir)"
}

pixel_boot_unpacks_dir() {
  printf '%s/unpack\n' "$(pixel_boot_dir)"
}

pixel_boot_init_wrapper_bin() {
  printf '%s/init-wrapper\n' "$(pixel_boot_dir)"
}

pixel_boot_custom_boot_img() {
  printf '%s/shadow-boot-wrapper.img\n' "$(pixel_boot_dir)"
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

pixel_connected_fastboot_serials() {
  fastboot devices | awk '$2 == "fastboot" { print $1 }'
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

pixel_retry_nix_build() {
  local attempt max_attempts retry_sleep_secs status log_path
  max_attempts="${PIXEL_NIX_BUILD_RETRIES:-3}"
  retry_sleep_secs="${PIXEL_NIX_BUILD_RETRY_SLEEP_SECS:-3}"
  log_path="$(mktemp "${TMPDIR:-/tmp}/pixel-nix-build.XXXXXX")"

  for attempt in $(seq 1 "$max_attempts"); do
    if "$@" >"$log_path" 2>&1; then
      cat "$log_path"
      rm -f "$log_path"
      return 0
    fi

    status="$?"
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
  local attempt max_attempts retry_sleep_secs status stdout_log stderr_log combined_log
  max_attempts="${PIXEL_NIX_BUILD_RETRIES:-3}"
  retry_sleep_secs="${PIXEL_NIX_BUILD_RETRY_SLEEP_SECS:-3}"
  stdout_log="$(mktemp "${TMPDIR:-/tmp}/pixel-nix-build-stdout.XXXXXX")"
  stderr_log="$(mktemp "${TMPDIR:-/tmp}/pixel-nix-build-stderr.XXXXXX")"
  combined_log="$(mktemp "${TMPDIR:-/tmp}/pixel-nix-build-combined.XXXXXX")"

  for attempt in $(seq 1 "$max_attempts"); do
    if "$@" >"$stdout_log" 2>"$stderr_log"; then
      cat "$stderr_log" >&2
      cat "$stdout_log"
      rm -f "$stdout_log" "$stderr_log" "$combined_log"
      return 0
    fi

    status="$?"
    cat "$stdout_log" "$stderr_log" >"$combined_log"
    if (( attempt == max_attempts )) || ! pixel_retryable_nix_build_failure "$combined_log"; then
      cat "$stderr_log" >&2
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
  local requested serials serial
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

pixel_restore_android_best_effort() {
  local serial timeout_secs reboot_timeout_secs pid
  serial="$1"
  timeout_secs="${2:-60}"
  reboot_timeout_secs="${PIXEL_RESTORE_ANDROID_REBOOT_TIMEOUT_SECS:-120}"
  pid=""

  if pixel_android_display_restored "$serial"; then
    return 0
  fi

  (
    PIXEL_SERIAL="$serial" "$SHADOW_SCRIPT_ROOT/pixel/pixel_restore_android.sh" >/dev/null 2>&1 || true
  ) &
  pid="$!"

  local deadline=$((SECONDS + timeout_secs))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      wait "$pid" >/dev/null 2>&1 || true
      if pixel_android_display_restored "$serial"; then
        return 0
      fi
      printf 'pixel: warning: pixel_restore_android exited before Android was fully restored\n' >&2
      break
    fi
    sleep 1
  done

  if kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
    printf 'pixel: warning: pixel_restore_android timed out after %ss\n' "$timeout_secs" >&2
  fi

  if [[ "${PIXEL_RESTORE_ANDROID_REBOOT_ON_FAILURE:-1}" == "0" ]]; then
    return 1
  fi

  printf 'pixel: warning: rebooting %s to restore Android display stack\n' "$serial" >&2
  pixel_reboot_and_wait_android_display "$serial" "$reboot_timeout_secs"
}

pixel_kill_stale_shadow_processes_shell_snippet() {
  cat <<'EOF'
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
  kill_named_shadow_process shadow-compositor-guest
  kill_named_shadow_process shadow-session
}

kill_stale_shadow_processes
EOF
}

pixel_stop_shadow_session_script() {
  cat <<EOF
$(pixel_kill_stale_shadow_processes_shell_snippet)
rm -f '$(pixel_shell_control_socket_path)' >/dev/null 2>&1 || true
EOF
}

pixel_stop_shadow_session_best_effort() {
  local serial
  serial="$1"
  pixel_root_shell "$serial" "$(pixel_stop_shadow_session_script)" >/dev/null 2>&1 || true
}

pixel_takeover_display_service_helpers_script() {
  cat <<'EOF'
service_process_exists() {
  name="$1"
  ps -A | awk -v name="$name" '$NF == name { found=1 } END { exit(found ? 0 : 1) }'
}

service_binary_exists() {
  name="$1"
  for path in "/vendor/bin/hw/$name" "/vendor/bin/$name" "/system/bin/$name" "/system_ext/bin/$name"; do
    if [ -e "$path" ]; then
      return 0
    fi
  done
  return 1
}

service_is_known() {
  service="$1"
  current="$(getprop "init.svc.$service" | tr -d '\r')"
  if [ "$current" = running ]; then
    return 0
  fi
  service_process_exists "$service" || service_binary_exists "$service"
}

service_is_running() {
  service="$1"
  current="$(getprop "init.svc.$service" | tr -d '\r')"
  if [ "$current" = running ]; then
    return 0
  fi
  service_process_exists "$service"
}

service_is_stopped() {
  service="$1"
  ! service_is_running "$service"
}

any_service_running() {
  for service in "$@"; do
    [ -n "$service" ] || continue
    if service_is_running "$service"; then
      return 0
    fi
  done
  return 1
}

all_services_stopped() {
  for service in "$@"; do
    [ -n "$service" ] || continue
    if service_is_running "$service"; then
      return 1
    fi
  done
  return 0
}

wait_for_service_state() {
  service="$1"
  expected="$2"
  attempts="${3:-40}"
  count=0
  while [ "$count" -lt "$attempts" ]; do
    if [ "$expected" = running ]; then
      if service_is_running "$service"; then
        return 0
      fi
    else
      if service_is_stopped "$service"; then
        return 0
      fi
    fi
    count=$((count + 1))
    sleep 0.2
  done
  return 1
}

EOF
}

pixel_takeover_stop_services_script() {
  local stop_allocator
  stop_allocator="${1:-1}"
  cat <<'EOF'
EOF
  pixel_takeover_display_service_helpers_script
  pixel_kill_stale_shadow_processes_shell_snippet
  cat <<'EOF'
stop_service_and_wait() {
  service="$1"
  stop "$service" || true
  wait_for_service_state "$service" stopped 50 || true
}

stop_service_and_wait surfaceflinger
stop_service_and_wait bootanim
for service in \
  vendor.hwcomposer-2-4 \
  android.hardware.graphics.composer@2.4-service-sm8150 \
  android.hardware.graphics.composer@2.4-service
do
  if service_is_known "$service"; then
    stop_service_and_wait "$service"
  fi
done
EOF
  if [[ "$stop_allocator" != "0" ]]; then
    cat <<'EOF'
for service in \
  vendor.qti.hardware.display.allocator \
  vendor.qti.hardware.display.allocator-service
do
  if service_is_known "$service"; then
    stop_service_and_wait "$service"
  fi
done
EOF
  fi
  cat <<'EOF'
setenforce 0 >/dev/null 2>&1 || true
EOF
}

pixel_takeover_start_services_script() {
  cat <<'EOF'
EOF
  pixel_takeover_display_service_helpers_script
  pixel_kill_stale_shadow_processes_shell_snippet
  cat <<'EOF'
start_service_if_known() {
  service="$1"
  current="$(getprop "init.svc.$service" | tr -d '\r')"
  if [ "$current" = running ]; then
    return 0
  fi
  if [ -n "$current" ]; then
    start "$service" || true
    wait_for_service_state "$service" running 50 || true
    return 0
  fi
  service_process_exists "$service" && return 0
  return 0
}

boot_completed() {
  [ "$(getprop sys.boot_completed | tr -d '\r')" = "1" ] \
    || [ "$(getprop dev.bootcomplete | tr -d '\r')" = "1" ]
}

for service in \
  vendor.qti.hardware.display.allocator \
  vendor.qti.hardware.display.allocator-service
do
  start_service_if_known "$service"
done
for service in \
  vendor.hwcomposer-2-4 \
  android.hardware.graphics.composer@2.4-service-sm8150 \
  android.hardware.graphics.composer@2.4-service
do
  start_service_if_known "$service"
done
start surfaceflinger || true
if boot_completed; then
  setprop service.bootanim.exit 1 || true
  stop bootanim || true
else
  start bootanim || true
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

pixel_graphics_composer_service_candidates() {
  printf '%s\n' \
    vendor.hwcomposer-2-4 \
    android.hardware.graphics.composer@2.4-service-sm8150 \
    android.hardware.graphics.composer@2.4-service
}

pixel_display_allocator_service_candidates() {
  printf '%s\n' \
    vendor.qti.hardware.display.allocator \
    vendor.qti.hardware.display.allocator-service
}

pixel_named_service_binary_exists() {
  local serial service quoted_service
  serial="$1"
  service="$2"
  quoted_service="$(printf '%q' "$service")"
  pixel_root_shell "$serial" "
    service=$quoted_service
    for path in \"/vendor/bin/hw/\$service\" \"/vendor/bin/\$service\" \"/system/bin/\$service\" \"/system_ext/bin/\$service\"; do
      [ -e \"\$path\" ] && exit 0
    done
    exit 1
  "
}

pixel_named_service_known() {
  local serial service
  serial="$1"
  service="$2"
  [[ "$(pixel_service_state "$serial" "$service")" == "running" ]] \
    || pixel_root_process_exists "$serial" "$service" >/dev/null 2>&1 \
    || pixel_named_service_binary_exists "$serial" "$service" >/dev/null 2>&1
}

pixel_named_service_running() {
  local serial service state
  serial="$1"
  service="$2"
  state="$(pixel_service_state "$serial" "$service")"
  if [[ "$state" == "running" ]]; then
    return 0
  fi
  pixel_root_process_exists "$serial" "$service" >/dev/null 2>&1
}

pixel_any_named_service_running() {
  local serial service
  serial="$1"
  shift
  for service in "$@"; do
    [[ -n "$service" ]] || continue
    if pixel_named_service_running "$serial" "$service"; then
      return 0
    fi
  done
  return 1
}

pixel_all_named_services_stopped() {
  local serial service
  serial="$1"
  shift
  for service in "$@"; do
    [[ -n "$service" ]] || continue
    if pixel_named_service_running "$serial" "$service"; then
      return 1
    fi
  done
  return 0
}

pixel_display_services_stopped() {
  local serial
  serial="$1"
  pixel_all_named_services_stopped "$serial" surfaceflinger || return 1
  pixel_all_named_services_stopped "$serial" \
    vendor.hwcomposer-2-4 \
    android.hardware.graphics.composer@2.4-service-sm8150 \
    android.hardware.graphics.composer@2.4-service || return 1
  pixel_all_named_services_stopped "$serial" \
    vendor.qti.hardware.display.allocator \
    vendor.qti.hardware.display.allocator-service
}

pixel_display_services_stopped_keep_allocator() {
  local serial
  serial="$1"
  pixel_all_named_services_stopped "$serial" surfaceflinger || return 1
  pixel_all_named_services_stopped "$serial" \
    vendor.hwcomposer-2-4 \
    android.hardware.graphics.composer@2.4-service-sm8150 \
    android.hardware.graphics.composer@2.4-service || return 1
  pixel_any_named_service_running "$serial" \
    vendor.qti.hardware.display.allocator \
    vendor.qti.hardware.display.allocator-service
}

pixel_display_services_running() {
  local serial
  serial="$1"
  pixel_any_named_service_running "$serial" surfaceflinger || return 1
  pixel_any_named_service_running "$serial" \
    vendor.hwcomposer-2-4 \
    android.hardware.graphics.composer@2.4-service-sm8150 \
    android.hardware.graphics.composer@2.4-service || return 1
  pixel_any_named_service_running "$serial" \
    vendor.qti.hardware.display.allocator \
    vendor.qti.hardware.display.allocator-service
}

pixel_bootanim_stopped() {
  local serial
  serial="$1"
  [[ "$(pixel_service_state "$serial" bootanim)" == "stopped" ]]
}

pixel_android_window_service_ready() {
  local serial
  serial="$1"
  timeout "${PIXEL_ADB_QUERY_TIMEOUT_SECS:-5}" adb -s "$serial" shell wm size 2>/dev/null \
    | tr -d '\r' \
    | grep -Eq '[0-9]+x[0-9]+'
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

pixel_takeover_processes_absent() {
  local serial process_name
  serial="$1"
  for process_name in shadow-blitz-demo shadow-compositor-guest shadow-session; do
    if pixel_root_process_exists "$serial" "$process_name" >/dev/null 2>&1; then
      return 1
    fi
  done
}

pixel_android_display_stack_restored() {
  local serial
  serial="$1"
  pixel_display_services_running "$serial" || return 1
  if [[ "$(pixel_prop "$serial" sys.boot_completed)" == "1" || "$(pixel_prop "$serial" dev.bootcomplete)" == "1" ]]; then
    pixel_bootanim_stopped "$serial" || return 1
  fi
  pixel_takeover_processes_absent "$serial"
}

pixel_android_display_restored() {
  local serial
  serial="$1"
  pixel_android_display_stack_restored "$serial" || return 1
  pixel_android_window_service_ready "$serial"
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

pixel_root_socket_exists() {
  local serial path
  serial="$1"
  path="$2"
  pixel_root_shell "$serial" "[ -S '$path' ]"
}

pixel_shell_control_request() {
  local serial request control_socket phone_script
  serial="$1"
  request="$2"
  control_socket="$(pixel_shell_control_socket_path)"

  phone_script=$(
    cat <<EOF
control_socket=$control_socket
if [ ! -S "\$control_socket" ]; then
  echo "shadowctl: missing compositor control socket \$control_socket" >&2
  exit 1
fi
printf '%s\n' $(printf '%q' "$request") | nc -U "\$control_socket"
EOF
  )

  pixel_root_shell "$serial" "$phone_script"
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

pixel_prepare_dirs() {
  mkdir -p "$(pixel_artifacts_dir)" "$(pixel_runs_dir)" "$(pixel_root_dir)" "$(pixel_boot_dir)"
}

pixel_pinned_turnip_result_link() {
  printf '%s/shadow-pinned-turnip-mesa-aarch64-linux-result\n' "$(pixel_dir)"
}

pixel_pinned_turnip_lib_path() {
  printf '%s/lib/libvulkan_freedreno.so\n' "$(pixel_pinned_turnip_result_link)"
}

pixel_ensure_pinned_turnip_lib() {
  local repo package_system package_ref out_link lib_path

  out_link="$(pixel_pinned_turnip_result_link)"
  lib_path="$(pixel_pinned_turnip_lib_path)"
  repo="$(repo_root)"
  package_system="${PIXEL_LINUX_BUILD_SYSTEM:-aarch64-linux}"
  package_ref="$repo#packages.${package_system}.shadow-pinned-turnip-mesa-aarch64-linux"
  nix build \
    --accept-flake-config \
    --out-link "$out_link" \
    --print-out-paths \
    "$package_ref" >/dev/null

  if [[ ! -f "$lib_path" ]]; then
    echo "pixel: pinned Turnip build did not produce libvulkan_freedreno.so: $lib_path" >&2
    return 1
  fi

  printf '%s\n' "$lib_path"
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

pixel_runtime_app_bundle_artifact() {
  pixel_artifact_path shadow-runtime-app-bundle.js
}

pixel_runtime_apps_manifest() {
  printf '%s\n' "${SHADOW_APP_METADATA_MANIFEST:-$(repo_root)/runtime/apps.json}"
}

pixel_runtime_shell_app_ids() {
  python3 - "$(pixel_runtime_apps_manifest)" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)

for app in manifest.get("apps", []):
    if "pixel-shell" in set(app.get("profiles", [])):
        print(app["id"])
PY
}

pixel_runtime_app_manifest_field() {
  local app_id="$1"
  local field_path="$2"

  python3 - "$(pixel_runtime_apps_manifest)" "$app_id" "$field_path" <<'PY'
import json
import sys

manifest_path, app_id, field_path = sys.argv[1:4]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)

for app in manifest.get("apps", []):
    if app.get("id") != app_id:
        continue
    value = app
    for part in field_path.split("."):
        value = value[part]
    if isinstance(value, (dict, list)):
        print(json.dumps(value, separators=(",", ":")))
    else:
        print(value)
    raise SystemExit(0)

raise SystemExit(f"unknown runtime app id: {app_id}")
PY
}

pixel_runtime_app_bundle_filename() {
  pixel_runtime_app_manifest_field "$1" runtime.bundleFilename
}

pixel_runtime_app_bundle_env() {
  pixel_runtime_app_manifest_field "$1" runtime.bundleEnv
}

pixel_runtime_app_bundle_artifact_for() {
  pixel_artifact_path "$(pixel_runtime_app_bundle_filename "$1")"
}

pixel_runtime_host_bundle_artifact_dir() {
  pixel_artifact_path shadow-runtime-gnu
}

pixel_runtime_app_asset_artifact_dir() {
  pixel_artifact_path shadow-runtime-app-assets
}

pixel_shell_runtime_host_bundle_artifact_dir() {
  pixel_artifact_path shadow-runtime-shell-gnu
}

pixel_guest_client_artifact() {
  if [[ -n "${PIXEL_GUEST_CLIENT_ARTIFACT:-}" ]]; then
    printf '%s\n' "$PIXEL_GUEST_CLIENT_ARTIFACT"
  else
    pixel_artifact_path shadow-blitz-demo
  fi
}

pixel_session_dst() {
  printf '%s\n' "${PIXEL_SESSION_DST:-/data/local/tmp/shadow-session}"
}

pixel_compositor_dst() {
  printf '%s\n' "${PIXEL_COMPOSITOR_DST:-/data/local/tmp/shadow-compositor-guest}"
}

pixel_guest_client_dst() {
  if [[ -n "${PIXEL_GUEST_CLIENT_DST:-}" ]]; then
    printf '%s\n' "$PIXEL_GUEST_CLIENT_DST"
  else
    printf '%s\n' "/data/local/tmp/shadow-blitz-demo"
  fi
}

pixel_runtime_dir() {
  printf '%s\n' "${PIXEL_RUNTIME_DIR:-/data/local/tmp/shadow-runtime}"
}

pixel_runtime_touch_signal_path() {
  printf '%s/touch-signal\n' "$(pixel_runtime_dir)"
}

pixel_runtime_cashu_data_dir() {
  printf '%s/cashu\n' "$(pixel_runtime_dir)"
}

pixel_runtime_nostr_db_path() {
  printf '%s/runtime-nostr.sqlite3\n' "$(pixel_runtime_dir)"
}

pixel_shell_control_socket_path() {
  printf '%s/%s\n' "$(pixel_runtime_dir)" "shadow-control.sock"
}

pixel_runtime_linux_dir() {
  printf '%s\n' "${PIXEL_RUNTIME_LINUX_DIR:-/data/local/tmp/shadow-runtime-gnu}"
}

pixel_runtime_chroot_device_path() {
  local chroot_path
  chroot_path="${1:?pixel_runtime_chroot_device_path requires a path}"
  printf '%s%s\n' "$(pixel_runtime_linux_dir)" "$chroot_path"
}

pixel_runtime_home_dir() {
  printf '%s/home\n' "$(pixel_runtime_linux_dir)"
}

pixel_runtime_cache_dir() {
  printf '%s/.cache\n' "$(pixel_runtime_home_dir)"
}

pixel_runtime_mesa_cache_dir() {
  printf '%s/mesa\n' "$(pixel_runtime_cache_dir)"
}

pixel_runtime_config_dir() {
  printf '%s/.config\n' "$(pixel_runtime_home_dir)"
}

pixel_runtime_xkb_config_root() {
  printf '%s/share/X11/xkb\n' "$(pixel_runtime_linux_dir)"
}

pixel_runtime_precreate_dirs_lines() {
  cat <<EOF
$(pixel_runtime_home_dir)
$(pixel_runtime_cache_dir)
$(pixel_runtime_mesa_cache_dir)
$(pixel_runtime_config_dir)
EOF
}

pixel_runtime_app_bundle_dst() {
  printf '%s/runtime-app-bundle.js\n' "$(pixel_runtime_linux_dir)"
}

pixel_runtime_app_bundle_dst_for() {
  printf '%s/%s\n' "$(pixel_runtime_linux_dir)" "$(pixel_runtime_app_bundle_filename "$1")"
}

pixel_runtime_host_binary_dst() {
  printf '%s/shadow-runtime-host\n' "$(pixel_runtime_linux_dir)"
}

pixel_runtime_host_launcher_dst() {
  printf '%s/run-shadow-runtime-host\n' "$(pixel_runtime_linux_dir)"
}

pixel_runtime_openlog_preload_dst() {
  printf '%s/lib/shadow-openlog-preload.so\n' "$(pixel_runtime_linux_dir)"
}

pixel_runtime_host_env_lines() {
  cat <<EOF
SHADOW_RUNTIME_HOST_BINARY_PATH=$(pixel_runtime_host_launcher_dst)
SHADOW_RUNTIME_NOSTR_DB_PATH=$(pixel_runtime_nostr_db_path)
EOF
}

pixel_runtime_linux_user_env_lines() {
  cat <<EOF
HOME=$(pixel_runtime_home_dir)
XDG_CACHE_HOME=$(pixel_runtime_cache_dir)
XDG_CONFIG_HOME=$(pixel_runtime_config_dir)
XKB_CONFIG_ROOT=$(pixel_runtime_xkb_config_root)
EOF
}

pixel_runtime_gpu_profile_lines() {
  local profile="$1"

  case "$profile" in
    "")
      return 0
      ;;
    gl)
      printf '%s\n' \
        'WGPU_BACKEND=gl' \
        "SHADOW_LINUX_LD_PRELOAD=$(pixel_runtime_openlog_preload_dst)"
      ;;
    gl_kgsl)
      printf '%s\n' \
        'WGPU_BACKEND=gl' \
        'MESA_LOADER_DRIVER_OVERRIDE=kgsl' \
        'TU_DEBUG=noconform' \
        "SHADOW_LINUX_LD_PRELOAD=$(pixel_runtime_openlog_preload_dst)"
      ;;
    vulkan_drm)
      printf '%s\n' \
        'WGPU_BACKEND=vulkan' \
        "SHADOW_LINUX_LD_PRELOAD=$(pixel_runtime_openlog_preload_dst)"
      ;;
    vulkan_kgsl)
      printf '%s\n' \
        'WGPU_BACKEND=vulkan' \
        'MESA_LOADER_DRIVER_OVERRIDE=kgsl' \
        'TU_DEBUG=noconform' \
        "SHADOW_LINUX_LD_PRELOAD=$(pixel_runtime_openlog_preload_dst)"
      ;;
    vulkan_kgsl_first)
      printf '%s\n' \
        'WGPU_BACKEND=vulkan' \
        'MESA_LOADER_DRIVER_OVERRIDE=kgsl' \
        'TU_DEBUG=noconform' \
        "SHADOW_LINUX_LD_PRELOAD=$(pixel_runtime_openlog_preload_dst)" \
        'SHADOW_OPENLOG_DENY_DRI=1'
      ;;
    *)
      return 1
      ;;
  esac
}

pixel_runtime_shell_bundle_env_lines() {
  local app_id

  while IFS= read -r app_id; do
    [[ -n "$app_id" ]] || continue
    printf '%s=%s\n' \
      "$(pixel_runtime_app_bundle_env "$app_id")" \
      "$(pixel_runtime_app_bundle_dst_for "$app_id")"
  done < <(pixel_runtime_shell_app_ids)
  printf 'SHADOW_RUNTIME_CASHU_DATA_DIR=%s\n' "$(pixel_runtime_cashu_data_dir)"
}

pixel_shell_words_quoted() {
  local word quoted

  for word in "$@"; do
    [[ -n "$word" ]] || continue
    # The rooted device wrapper executes under /system/bin/sh, so avoid bash-only
    # $'...' quoting for multiline env payloads.
    quoted=${word//\'/\'\\\'\'}
    printf "'%s' " "$quoted"
  done
}

pixel_lines_quoted() {
  local lines="$1"
  local line

  [[ -n "$lines" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pixel_shell_words_quoted "$line"
  done <<< "$lines"
}

pixel_guest_ui_session_env_words() {
  local runtime_dir="$1"
  local compositor_dst="$2"
  local client_dst="$3"
  local frame_path="$4"
  local compositor_exit_on_first_frame="${5:-}"
  local compositor_exit_on_client_disconnect="${6:-}"
  local client_exit_on_configure="${7:-}"
  local guest_client_env="${8:-}"
  local guest_session_env="${9:-}"

  pixel_lines_quoted "$guest_session_env"

  pixel_shell_words_quoted \
    "XKB_CONFIG_ROOT=$(pixel_runtime_xkb_config_root)" \
    'SHADOW_SESSION_MODE=guest-ui' \
    "SHADOW_RUNTIME_DIR=$runtime_dir" \
    "SHADOW_GUEST_COMPOSITOR_BIN=$compositor_dst" \
    "SHADOW_GUEST_CLIENT=$client_dst" \
    'SHADOW_GUEST_COMPOSITOR_TRANSPORT=direct' \
    'SHADOW_GUEST_COMPOSITOR_ENABLE_DRM=1'

  if [[ -n "$compositor_exit_on_first_frame" ]]; then
    pixel_shell_words_quoted "SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME=$compositor_exit_on_first_frame"
  fi
  if [[ -n "$compositor_exit_on_client_disconnect" ]]; then
    pixel_shell_words_quoted "SHADOW_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT=$compositor_exit_on_client_disconnect"
  fi
  if [[ -n "$client_exit_on_configure" ]]; then
    pixel_shell_words_quoted "SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE=$client_exit_on_configure"
  fi
  pixel_shell_words_quoted 'SHADOW_GUEST_CLIENT_LINGER_MS=500'
  if [[ -n "$guest_client_env" ]]; then
    pixel_shell_words_quoted "SHADOW_GUEST_CLIENT_ENV=$guest_client_env"
  fi

  pixel_shell_words_quoted \
    "SHADOW_GUEST_FRAME_PATH=$frame_path" \
    'RUST_LOG=shadow_compositor_guest=info,shadow_blitz_demo=info,smithay=warn'
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

pixel_shell_runs_dir() {
  printf '%s/shell\n' "$(pixel_dir)"
}

pixel_audio_runs_dir() {
  printf '%s/audio\n' "$(pixel_dir)"
}

pixel_touch_runs_dir() {
  printf '%s/touch\n' "$(pixel_dir)"
}

pixel_audio_linux_dir() {
  printf '%s\n' "${PIXEL_AUDIO_LINUX_DIR:-/data/local/tmp/shadow-audio-spike-gnu}"
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

Run 'sc -t pixel ota-sideload' first, let Android boot, re-enable USB debugging, then retry.
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

pixel_other_slot_letter() {
  case "$1" in
    a)
      printf 'b\n'
      ;;
    b)
      printf 'a\n'
      ;;
    *)
      echo "pixel: unknown slot letter: $1" >&2
      return 1
      ;;
  esac
}

pixel_current_slot_letter_from_adb() {
  local serial
  serial="$1"
  pixel_slot_suffix_to_letter "$(pixel_prop "$serial" ro.boot.slot_suffix)"
}

pixel_boot_partition_for_slot() {
  local slot_letter
  slot_letter="$(pixel_slot_suffix_to_letter "$1")"
  printf 'boot_%s\n' "$slot_letter"
}

pixel_boot_partition_for_slot_letter() {
  case "$1" in
    a|b)
      printf 'boot_%s\n' "$1"
      ;;
    *)
      echo "pixel: unknown slot letter: $1" >&2
      return 1
      ;;
  esac
}

pixel_fastboot_current_slot() {
  local serial current_slot
  serial="$1"
  current_slot="$(
    pixel_fastboot "$serial" getvar current-slot 2>&1 | awk -F': *' '/current-slot:/{print $2; exit}'
  )"
  current_slot="${current_slot//[$'\r\n\t ']}"
  [[ -n "$current_slot" ]] || {
    echo "pixel: failed to determine current fastboot slot for $serial" >&2
    return 1
  }
  printf '%s\n' "$current_slot"
}

pixel_boot_last_action_json() {
  printf '%s/last-action.json\n' "$(pixel_boot_dir)"
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
