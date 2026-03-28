#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -ne 1 ]]; then
  echo "usage: ui_vm_app_run.sh <cargo-package>" >&2
  exit 1
fi

PACKAGE="$1"
LOG_FILE="/var/lib/shadow-ui/log/${PACKAGE}.log"
SESSION_ENV_FILE="/var/lib/shadow-ui/shadow-ui-session-env.sh"

read -r -d '' REMOTE_SCRIPT <<EOF || true
set -euo pipefail

export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"
session_env_file="${SESSION_ENV_FILE}"
package="${PACKAGE}"
log_file="${LOG_FILE}"
export CARGO_BUILD_JOBS="\${CARGO_BUILD_JOBS:-1}"

load_session_env_from_process() {
  local session_pid
  session_pid="\$(pgrep -o -f 'shadow-compositor' || true)"
  if [[ -z "\$session_pid" ]]; then
    echo "ui-vm-app-run: could not find a running shadow-compositor to recover guest env" >&2
    exit 1
  fi

  while IFS= read -r -d '' entry; do
    case "\$entry" in
      HOME=*|XDG_CACHE_HOME=*|CARGO_TARGET_DIR=*|PKG_CONFIG_PATH=*|LD_LIBRARY_PATH=*|LIBRARY_PATH=*|NIX_LDFLAGS=*|LIBGL_DRIVERS_PATH=*|RUST_BACKTRACE=*|XDG_RUNTIME_DIR=*)
        export "\$entry"
        ;;
    esac
  done <"/proc/\$session_pid/environ"
}

if [[ -f "\$session_env_file" ]]; then
  source "\$session_env_file"
else
  load_session_env_from_process
fi

wayland_socket="\$(find "\$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | sort -V | tail -n 1)"
control_socket="\$XDG_RUNTIME_DIR/shadow-control.sock"

if [[ -z "\$wayland_socket" ]]; then
  echo "ui-vm-app-run: no wayland socket found in \$XDG_RUNTIME_DIR" >&2
  exit 1
fi

if [[ ! -S "\$control_socket" ]]; then
  echo "ui-vm-app-run: missing compositor control socket \$control_socket" >&2
  exit 1
fi

matching_processes() {
  ps -eo pid=,comm=,args= | awk -v package="\$package" '
    \$2 == package { print; next }
    \$2 == "cargo" {
      command_start = index(\$0, \$3)
      command = substr(\$0, command_start)
      if (command ~ ("^cargo run( --locked)? --manifest-path ui/Cargo.toml -p " package "\$")) {
        print
      }
    }
  '
}

existing="\$(matching_processes)"
if [[ -n "\$existing" ]]; then
  echo "ui-vm-app-run: \$package is already running" >&2
  printf '%s\n' "\$existing"
  exit 0
fi

cd /work/shadow
nohup env \
  WAYLAND_DISPLAY="\$wayland_socket" \
  SHADOW_COMPOSITOR_CONTROL="\$control_socket" \
  cargo run --locked --manifest-path ui/Cargo.toml -p "\$package" \
  >"\$log_file" 2>&1 </dev/null &

sleep 1
echo "ui-vm-app-run: launched \$package on \$wayland_socket"
matching_processes || true
EOF

exec "$SCRIPT_DIR/ui_vm_ssh.sh" "bash -c $(printf '%q' "$REMOTE_SCRIPT")"
