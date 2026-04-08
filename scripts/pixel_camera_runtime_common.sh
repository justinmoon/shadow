#!/usr/bin/env bash

pixel_camera_runtime_endpoint() {
  printf '%s\n' "${PIXEL_RUNTIME_CAMERA_ENDPOINT:-127.0.0.1:37656}"
}

pixel_camera_runtime_device_binary() {
  printf '%s\n' "${PIXEL_CAMERA_RS_DEVICE_BINARY:-/data/local/tmp/shadow-camera-provider-host}"
}

pixel_camera_runtime_daemon_pid_path() {
  printf '%s\n' "/data/local/tmp/shadow-camera-provider-host-serve.pid"
}

pixel_camera_runtime_daemon_log_path() {
  printf '%s\n' "/data/local/tmp/shadow-camera-provider-host-serve.log"
}

pixel_camera_runtime_prepare_broker() {
  local serial endpoint helper_script
  serial="${1:?pixel_camera_runtime_prepare_broker requires a serial}"
  endpoint="${2:-$(pixel_camera_runtime_endpoint)}"
  pixel_camera_runtime_prepare_helper "$serial"
  pixel_root_shell "$serial" "$(pixel_camera_runtime_start_command "$endpoint")" >/dev/null
}

pixel_camera_runtime_prepare_helper() {
  local serial helper_script
  serial="${1:?pixel_camera_runtime_prepare_helper requires a serial}"
  helper_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pixel_camera_rs_run.sh"

  PIXEL_SERIAL="$serial" "$helper_script" ping >/dev/null
}

pixel_camera_runtime_start_command() {
  local endpoint device_binary daemon_pid_path daemon_log_path
  endpoint="${1:-$(pixel_camera_runtime_endpoint)}"
  device_binary="$(pixel_camera_runtime_device_binary)"
  daemon_pid_path="$(pixel_camera_runtime_daemon_pid_path)"
  daemon_log_path="$(pixel_camera_runtime_daemon_log_path)"

  cat <<EOF
if [ -f '$daemon_pid_path' ]; then
  kill \$(cat '$daemon_pid_path') >/dev/null 2>&1 || true
fi
rm -f '$daemon_pid_path' '$daemon_log_path'
chmod 0755 '$device_binary'
nohup '$device_binary' serve '$endpoint' >'$daemon_log_path' 2>&1 &
echo \$! > '$daemon_pid_path'
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -Fq 'socket-server-listening' '$daemon_log_path' 2>/dev/null; then
    ready=1
    break
  fi
  kill -0 \$(cat '$daemon_pid_path') >/dev/null 2>&1 || break
  sleep 1
done
if [ "\$ready" != 1 ]; then
  cat '$daemon_log_path' >&2 2>/dev/null || true
  exit 1
fi
EOF
}

pixel_camera_runtime_cleanup_broker() {
  local serial daemon_pid_path
  serial="${1:?pixel_camera_runtime_cleanup_broker requires a serial}"
  daemon_pid_path="$(pixel_camera_runtime_daemon_pid_path)"

  pixel_root_shell "$serial" "
    if [ -f '$daemon_pid_path' ]; then
      kill \$(cat '$daemon_pid_path') >/dev/null 2>&1 || true
      rm -f '$daemon_pid_path'
    fi
  " >/dev/null 2>&1 || true
}
