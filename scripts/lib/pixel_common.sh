#!/usr/bin/env bash

PIXEL_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHADOW_SCRIPT_ROOT="$(cd "$PIXEL_COMMON_DIR/.." && pwd)"
# shellcheck source=./shadow_common.sh
source "$PIXEL_COMMON_DIR/shadow_common.sh"
# shellcheck source=./pixel_device_transport_common.sh
source "$PIXEL_COMMON_DIR/pixel_device_transport_common.sh"
# shellcheck source=./pixel_runtime_session_common.sh
source "$PIXEL_COMMON_DIR/pixel_runtime_session_common.sh"
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
  local attempt max_attempts retry_sleep_secs heartbeat_secs status stdout_log stderr_log combined_log pid started_at next_heartbeat old_term_trap old_int_trap
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
      if (( heartbeat_secs > 0 && SECONDS >= next_heartbeat )); then
        printf 'pixel: nix build still running (%ss elapsed): %s\n' \
          "$((SECONDS - started_at))" \
          "$*" >&2
        next_heartbeat=$((SECONDS + heartbeat_secs))
      fi
    done

    if wait "$pid"; then
      pid=""
      cat "$stderr_log" >&2
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

pixel_shell_socket_exists() {
  local serial path
  serial="$1"
  path="$2"
  pixel_adb "$serial" shell "[ -S '$path' ]" >/dev/null 2>&1
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

  pixel_adb "$serial" shell "$phone_script"
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
