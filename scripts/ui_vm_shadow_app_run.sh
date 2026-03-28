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
      if (command ~ ("^cargo run( --locked)? --manifest-path ui/Cargo.toml -p " package "\$")) {
        print
      }
    }
  '
}

if [[ ! -f "\$COMPOSITOR_ENV_FILE" ]]; then
  echo "ui-vm-shadow-app-run: missing nested compositor env; run just ui-vm-shadow-run first" >&2
  exit 1
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
