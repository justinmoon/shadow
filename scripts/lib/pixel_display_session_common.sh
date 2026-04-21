#!/usr/bin/env bash

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
