#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -ne 1 ]]; then
  echo "usage: ui_vm_shadow_app_run.sh <cargo-package>" >&2
  exit 1
fi

PACKAGE="$1"

read -r -d '' REMOTE_SCRIPT <<EOF || true
set -euo pipefail

STATE_DIR="/var/lib/shadow-ui"
COMPOSITOR_ENV_FILE="\$STATE_DIR/shadow-compositor-session-env.sh"
LOG_FILE="\$STATE_DIR/log/${PACKAGE}.shadow.log"
package="${PACKAGE}"
export CARGO_BUILD_JOBS="\${CARGO_BUILD_JOBS:-1}"

matching_processes() {
  ps -eo pid=,comm=,args= | awk -v package="\$package" '
    \$2 == package { print; next }
    \$2 == "cargo" {
      command_start = index(\$0, \$3)
      command = substr(\$0, command_start)
      if (command ~ ("(^|/)cargo run( --locked)? --manifest-path ui/Cargo.toml -p " package "\$")) {
        print
      }
    }
  '
}

recover_nested_env() {
  local control_socket="\$XDG_RUNTIME_DIR/shadow-control.sock"
  local nested_wayland
  nested_wayland="\$(
    find "\$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' ! -name 'wayland-0' -printf '%f\n' \
      | sort -V \
      | tail -n 1
  )"

  if [[ -z "\$nested_wayland" || ! -S "\$control_socket" ]]; then
    return 1
  fi

  cat >"\$COMPOSITOR_ENV_FILE" <<ENV
export HOME="\$HOME"
export XDG_CACHE_HOME="\$XDG_CACHE_HOME"
export CARGO_TARGET_DIR="\$CARGO_TARGET_DIR"
export PKG_CONFIG_PATH="\$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="\$LD_LIBRARY_PATH"
export LIBRARY_PATH="\$LIBRARY_PATH"
export NIX_LDFLAGS="\$NIX_LDFLAGS"
export LIBGL_DRIVERS_PATH="\$LIBGL_DRIVERS_PATH"
export RUST_BACKTRACE="\$RUST_BACKTRACE"
export XDG_RUNTIME_DIR="\$XDG_RUNTIME_DIR"
export DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS:-}"
export GDK_BACKEND="\${GDK_BACKEND:-}"
export WAYLAND_DISPLAY="\$nested_wayland"
export SHADOW_COMPOSITOR_CONTROL="\$control_socket"
ENV
}

if [[ ! -f "\$COMPOSITOR_ENV_FILE" ]]; then
  if ! recover_nested_env; then
    echo "ui-vm-shadow-app-run: missing nested compositor env; run just ui-vm-shadow-run first" >&2
    exit 1
  fi
fi

# shellcheck disable=SC1090
source "\$COMPOSITOR_ENV_FILE"

if [[ ! -S "\$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY" ]]; then
  echo "ui-vm-shadow-app-run: nested wayland socket \$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY is missing" >&2
  exit 1
fi

if [[ ! -S "\$SHADOW_COMPOSITOR_CONTROL" ]]; then
  echo "ui-vm-shadow-app-run: compositor control socket \$SHADOW_COMPOSITOR_CONTROL is missing" >&2
  exit 1
fi

existing="\$(matching_processes)"
if [[ -n "\$existing" ]]; then
  echo "ui-vm-shadow-app-run: \$package is already running" >&2
  printf '%s\n' "\$existing"
  exit 0
fi

cd /work/shadow
nohup env \
  WAYLAND_DISPLAY="\$WAYLAND_DISPLAY" \
  SHADOW_COMPOSITOR_CONTROL="\$SHADOW_COMPOSITOR_CONTROL" \
  cargo run --locked --manifest-path ui/Cargo.toml -p "\$package" \
  >"\$LOG_FILE" 2>&1 </dev/null &

sleep 1
echo "ui-vm-shadow-app-run: launched \$package on \$WAYLAND_DISPLAY"
matching_processes || true
EOF

exec "$SCRIPT_DIR/ui_vm_ssh.sh" "bash -c $(printf '%q' "$REMOTE_SCRIPT")"
