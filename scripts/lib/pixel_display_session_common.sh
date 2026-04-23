#!/usr/bin/env bash

pixel_restore_android_best_effort() {
  local serial timeout_secs reboot_timeout_secs pid takeover_display_service_profile_json
  serial="$1"
  timeout_secs="${2:-60}"
  reboot_timeout_secs="${PIXEL_RESTORE_ANDROID_REBOOT_TIMEOUT_SECS:-120}"
  pid=""
  takeover_display_service_profile_json="${PIXEL_TAKEOVER_DISPLAY_SERVICE_PROFILE_JSON-}"

  if pixel_android_display_restored "$serial"; then
    return 0
  fi

  (
    PIXEL_SERIAL="$serial" \
    PIXEL_TAKEOVER_DISPLAY_SERVICE_PROFILE_JSON="$takeover_display_service_profile_json" \
      "$SHADOW_SCRIPT_ROOT/pixel/pixel_restore_android.sh" >/dev/null 2>&1 || true
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

pixel_takeover_display_service_profile_json_from_stop_allocator() {
  local stop_allocator="${1:-1}"

  PIXEL_TAKEOVER_STOP_ALLOCATOR="$stop_allocator" python3 - <<'PY'
import json
import os


display_allocator_services = [
    "vendor.qti.hardware.display.allocator",
    "vendor.qti.hardware.display.allocator-service",
]
stop_allocator = os.environ.get("PIXEL_TAKEOVER_STOP_ALLOCATOR", "1").strip().lower()
stop_allocator = stop_allocator not in {"", "0", "false", "off"}

stop_services = [
    "surfaceflinger",
    "bootanim",
    "vendor.hwcomposer-2-4",
    "android.hardware.graphics.composer@2.4-service-sm8150",
    "android.hardware.graphics.composer@2.4-service",
]
preserve_services = []
profile_name = "default"
if stop_allocator:
    stop_services.extend(display_allocator_services)
else:
    profile_name = "keep-allocator"
    preserve_services.extend(display_allocator_services)

print(
    json.dumps(
        {
            "name": profile_name,
            "preserveServices": preserve_services,
            "restoreBootanim": "conditional",
            "setEnforceAfterRestore": True,
            "setEnforceAfterStop": False,
            "startServices": display_allocator_services
            + [
                "vendor.hwcomposer-2-4",
                "android.hardware.graphics.composer@2.4-service-sm8150",
                "android.hardware.graphics.composer@2.4-service",
                "surfaceflinger",
            ],
            "stopServices": stop_services,
        },
        separators=(",", ":"),
        sort_keys=True,
    )
)
PY
}

pixel_takeover_display_service_profile_json_from_env() {
  if [[ -n "${PIXEL_TAKEOVER_DISPLAY_SERVICE_PROFILE_JSON-}" ]]; then
    printf '%s\n' "$PIXEL_TAKEOVER_DISPLAY_SERVICE_PROFILE_JSON"
    return 0
  fi

  pixel_takeover_display_service_profile_json_from_stop_allocator "${PIXEL_TAKEOVER_STOP_ALLOCATOR:-1}"
}

pixel_takeover_display_service_profile_field() {
  local profile_json="${1:-}"
  local field="${2:?pixel_takeover_display_service_profile_field requires a field}"

  if [[ -z "$profile_json" ]]; then
    profile_json="$(pixel_takeover_display_service_profile_json_from_env)"
  fi

  PIXEL_TAKEOVER_DISPLAY_SERVICE_PROFILE_JSON="$profile_json" \
  PIXEL_TAKEOVER_DISPLAY_SERVICE_PROFILE_FIELD="$field" \
    python3 - <<'PY'
import json
import os


display_allocator_services = [
    "vendor.qti.hardware.display.allocator",
    "vendor.qti.hardware.display.allocator-service",
]


def default_profile(stop_allocator):
    stop_services = [
        "surfaceflinger",
        "bootanim",
        "vendor.hwcomposer-2-4",
        "android.hardware.graphics.composer@2.4-service-sm8150",
        "android.hardware.graphics.composer@2.4-service",
    ]
    preserve_services = []
    profile_name = "default"
    if stop_allocator:
        stop_services.extend(display_allocator_services)
    else:
        profile_name = "keep-allocator"
        preserve_services.extend(display_allocator_services)
    return {
        "name": profile_name,
        "preserveServices": preserve_services,
        "restoreBootanim": "conditional",
        "setEnforceAfterRestore": True,
        "setEnforceAfterStop": False,
        "startServices": display_allocator_services
        + [
            "vendor.hwcomposer-2-4",
            "android.hardware.graphics.composer@2.4-service-sm8150",
            "android.hardware.graphics.composer@2.4-service",
            "surfaceflinger",
        ],
        "stopServices": stop_services,
    }


def parse_bool_field(label, value, default):
    if value is None:
        return default
    if not isinstance(value, bool):
        raise SystemExit(f"pixel: display service profile {label} must be a boolean")
    return value


def parse_list_field(label, value):
    if value is None:
        return []
    if not isinstance(value, list):
        raise SystemExit(f"pixel: display service profile {label} must be a list")
    parsed = []
    for item in value:
        if not isinstance(item, str):
            raise SystemExit(f"pixel: display service profile {label} entries must be strings")
        parsed.append(item)
    return parsed


raw = os.environ.get("PIXEL_TAKEOVER_DISPLAY_SERVICE_PROFILE_JSON", "").strip()
if raw:
    try:
        profile = json.loads(raw)
    except json.JSONDecodeError as error:
        raise SystemExit(
            f"pixel: invalid display service profile json: {error}"
        ) from error
    if not isinstance(profile, dict):
        raise SystemExit("pixel: display service profile must decode to an object")
else:
    profile = default_profile(True)

name = profile.get("name", "custom")
if not isinstance(name, str):
    raise SystemExit("pixel: display service profile name must be a string")
restore_bootanim = profile.get("restoreBootanim", "conditional")
if not isinstance(restore_bootanim, str):
    raise SystemExit("pixel: display service profile restoreBootanim must be a string")
if restore_bootanim not in {"conditional", "always-start", "always-stop", "ignore"}:
    raise SystemExit(
        "pixel: unsupported display service profile restoreBootanim: "
        f"{restore_bootanim!r}"
    )

profile = {
    "name": name,
    "preserveServices": parse_list_field("preserveServices", profile.get("preserveServices")),
    "restoreBootanim": restore_bootanim,
    "setEnforceAfterRestore": parse_bool_field(
        "setEnforceAfterRestore",
        profile.get("setEnforceAfterRestore"),
        True,
    ),
    "setEnforceAfterStop": parse_bool_field(
        "setEnforceAfterStop",
        profile.get("setEnforceAfterStop"),
        False,
    ),
    "startServices": parse_list_field("startServices", profile.get("startServices")),
    "stopServices": parse_list_field("stopServices", profile.get("stopServices")),
}

field = os.environ["PIXEL_TAKEOVER_DISPLAY_SERVICE_PROFILE_FIELD"]
if field in {"stopServices", "preserveServices", "startServices"}:
    print("\n".join(profile[field]))
elif field in {"setEnforceAfterRestore", "setEnforceAfterStop"}:
    print("1" if profile[field] else "0")
elif field in {"name", "restoreBootanim"}:
    print(profile[field])
else:
    raise SystemExit(f"pixel: unsupported display service profile field: {field}")
PY
}

pixel_takeover_display_service_stop_description() {
  local profile_json="${1:-}"
  local preserve_services=""

  preserve_services="$(pixel_takeover_display_service_profile_field "$profile_json" preserveServices)"
  if [[ -n "$preserve_services" ]]; then
    printf 'Android display services stopped with allocator preserved\n'
    return 0
  fi

  printf 'Android display services stopped\n'
}

pixel_display_services_stopped_for_profile() {
  local serial="${1:?pixel_display_services_stopped_for_profile requires a serial}"
  local profile_json="${2:-}"
  local service=""
  local stop_services=()
  local preserve_services=()

  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    stop_services+=("$service")
  done < <(pixel_takeover_display_service_profile_field "$profile_json" stopServices)
  if (( ${#stop_services[@]} > 0 )); then
    pixel_all_named_services_stopped "$serial" "${stop_services[@]}" || return 1
  fi

  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    preserve_services+=("$service")
  done < <(pixel_takeover_display_service_profile_field "$profile_json" preserveServices)
  if (( ${#preserve_services[@]} > 0 )); then
    pixel_any_named_service_running "$serial" "${preserve_services[@]}" || return 1
  fi

  return 0
}

pixel_takeover_stop_services_script_for_profile() {
  local profile_json="${1:-}"
  local stop_services=""
  local set_enforce_after_stop=""
  local service=""

  if [[ -z "$profile_json" ]]; then
    profile_json="$(pixel_takeover_display_service_profile_json_from_env)"
  fi

  stop_services="$(pixel_takeover_display_service_profile_field "$profile_json" stopServices)"
  set_enforce_after_stop="$(
    pixel_takeover_display_service_profile_field "$profile_json" setEnforceAfterStop
  )"

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

EOF
  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    printf 'stop_service_and_wait %q\n' "$service"
  done <<< "$stop_services"
  if [[ "$set_enforce_after_stop" == "1" ]]; then
    cat <<'EOF'
setenforce 1 >/dev/null 2>&1 || true
EOF
  else
    cat <<'EOF'
setenforce 0 >/dev/null 2>&1 || true
EOF
  fi
}

pixel_takeover_start_services_script_for_profile() {
  local profile_json="${1:-}"
  local start_services=""
  local restore_bootanim=""
  local set_enforce_after_restore=""
  local service=""

  if [[ -z "$profile_json" ]]; then
    profile_json="$(pixel_takeover_display_service_profile_json_from_env)"
  fi

  start_services="$(pixel_takeover_display_service_profile_field "$profile_json" startServices)"
  restore_bootanim="$(
    pixel_takeover_display_service_profile_field "$profile_json" restoreBootanim
  )"
  set_enforce_after_restore="$(
    pixel_takeover_display_service_profile_field "$profile_json" setEnforceAfterRestore
  )"

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

EOF
  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    printf 'start_service_if_known %q\n' "$service"
  done <<< "$start_services"
  case "$restore_bootanim" in
    conditional)
      cat <<'EOF'
if boot_completed; then
  setprop service.bootanim.exit 1 || true
  stop bootanim || true
else
  start bootanim || true
fi
EOF
      ;;
    always-start)
      cat <<'EOF'
start bootanim || true
EOF
      ;;
    always-stop)
      cat <<'EOF'
setprop service.bootanim.exit 1 || true
stop bootanim || true
EOF
      ;;
    ignore) ;;
    *)
      echo "pixel: unsupported display service profile restoreBootanim: $restore_bootanim" >&2
      return 1
      ;;
  esac
  if [[ "$set_enforce_after_restore" == "1" ]]; then
    cat <<'EOF'
setenforce 1 >/dev/null 2>&1 || true
EOF
  else
    cat <<'EOF'
setenforce 0 >/dev/null 2>&1 || true
EOF
  fi
}

pixel_takeover_stop_services_script() {
  local stop_allocator
  stop_allocator="${1:-1}"

  pixel_takeover_stop_services_script_for_profile \
    "$(pixel_takeover_display_service_profile_json_from_stop_allocator "$stop_allocator")"
}

pixel_takeover_start_services_script() {
  local profile_json="${1:-}"

  if [[ -n "$profile_json" ]]; then
    pixel_takeover_start_services_script_for_profile "$profile_json"
    return
  fi

  pixel_takeover_start_services_script_for_profile \
    "$(pixel_takeover_display_service_profile_json_from_env)"
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
