#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

read -r -d '' REMOTE_SCRIPT <<'EOF' || true
set -euo pipefail

STATE_DIR="/var/lib/shadow-ui"
LOG_DIR="$STATE_DIR/log"
SESSION_ENV_FILE="$STATE_DIR/shadow-ui-session-env.sh"
COMPOSITOR_ENV_FILE="$STATE_DIR/shadow-compositor-session-env.sh"
COMPOSITOR_LOG="$LOG_DIR/shadow-compositor.log"
COMPOSITOR_LOCK_FILE="$STATE_DIR/shadow-compositor.lock"
COMPOSITOR_CONTROL_SOCKET_NAME="shadow-control.sock"
OUTER_WAYLAND_DISPLAY="wayland-0"
CARGO_INCREMENTAL=0

load_session_env() {
  if [[ -f "$SESSION_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SESSION_ENV_FILE"
    return
  fi

  local session_pid
  session_pid="$(pgrep -o -f 'weston|shadow-ui-desktop' || true)"
  if [[ -z "$session_pid" ]]; then
    echo "ui-vm-shadow-run: could not find a running weston session" >&2
    exit 1
  fi

  while IFS= read -r -d '' entry; do
    case "$entry" in
      HOME=*|XDG_CACHE_HOME=*|CARGO_TARGET_DIR=*|PKG_CONFIG_PATH=*|LD_LIBRARY_PATH=*|LIBRARY_PATH=*|NIX_LDFLAGS=*|LIBGL_DRIVERS_PATH=*|RUST_BACKTRACE=*|XDG_RUNTIME_DIR=*|DBUS_SESSION_BUS_ADDRESS=*|GDK_BACKEND=*)
        export "$entry"
        ;;
    esac
  done <"/proc/$session_pid/environ"
}

matching_processes() {
  ps -eo pid=,comm=,args= | awk '
    $3 ~ /(^|\/)shadow-compositor([[:space:]]|$)/ { print; next }
    $2 == "cargo" {
      command_start = index($0, $3)
      command = substr($0, command_start)
      if (command ~ "(^|/)cargo run( --locked)? --manifest-path ui/Cargo.toml -p shadow-compositor$") {
        print
      }
    }
  '
}

find_nested_wayland() {
  find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' ! -name "$OUTER_WAYLAND_DISPLAY" -printf '%f\n' \
    | sort -V \
    | tail -n 1
}

write_compositor_env() {
  local nested_wayland="$1"
  local control_socket="$2"
  cat >"$COMPOSITOR_ENV_FILE" <<ENV
export HOME="$HOME"
export XDG_CACHE_HOME="$XDG_CACHE_HOME"
export CARGO_TARGET_DIR="$CARGO_TARGET_DIR"
export PKG_CONFIG_PATH="$PKG_CONFIG_PATH"
export LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
export LIBRARY_PATH="$LIBRARY_PATH"
export NIX_LDFLAGS="$NIX_LDFLAGS"
export LIBGL_DRIVERS_PATH="$LIBGL_DRIVERS_PATH"
export RUST_BACKTRACE="$RUST_BACKTRACE"
export XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}"
export GDK_BACKEND="${GDK_BACKEND:-}"
export WAYLAND_DISPLAY="$nested_wayland"
export SHADOW_COMPOSITOR_CONTROL="$control_socket"
ENV
}

load_session_env

if [[ ! -S "$XDG_RUNTIME_DIR/$OUTER_WAYLAND_DISPLAY" ]]; then
  echo "ui-vm-shadow-run: missing weston socket $XDG_RUNTIME_DIR/$OUTER_WAYLAND_DISPLAY" >&2
  exit 1
fi

mkdir -p "$STATE_DIR"
exec 9>"$COMPOSITOR_LOCK_FILE"
flock 9

control_socket="$XDG_RUNTIME_DIR/$COMPOSITOR_CONTROL_SOCKET_NAME"
existing="$(matching_processes)"
if [[ -n "$existing" ]]; then
  nested_wayland="$(find_nested_wayland)"
  if [[ -n "$nested_wayland" && -S "$control_socket" ]]; then
    write_compositor_env "$nested_wayland" "$control_socket"
  fi
  echo "ui-vm-shadow-run: shadow-compositor is already running" >&2
  printf '%s\n' "$existing"
  if [[ -f "$COMPOSITOR_ENV_FILE" ]]; then
    echo "ui-vm-shadow-run: existing nested session env:"
    cat "$COMPOSITOR_ENV_FILE"
  fi
  exit 0
fi

mkdir -p "$LOG_DIR"
rm -f "$COMPOSITOR_ENV_FILE"
rm -f "$XDG_RUNTIME_DIR/$COMPOSITOR_CONTROL_SOCKET_NAME"
find "$XDG_RUNTIME_DIR" -maxdepth 1 \
  \( -type s -o -type f \) \
  \( -name 'wayland-[1-9]*' -o -name 'wayland-[1-9]*.lock' \) \
  -delete 2>/dev/null || true
find "$CARGO_TARGET_DIR/debug/deps" -maxdepth 1 -type f \
  \( -name 'libshadow_ui_software-*.rlib' -o -name 'libshadow_ui_software-*.rmeta' \) \
  -size 0 -delete 2>/dev/null || true
find "$CARGO_TARGET_DIR/debug/incremental" -maxdepth 1 -type d -name 'shadow_compositor-*' \
  -exec rm -rf {} + 2>/dev/null || true

cd /work/shadow
nohup env \
  CARGO_INCREMENTAL="$CARGO_INCREMENTAL" \
  WAYLAND_DISPLAY="$OUTER_WAYLAND_DISPLAY" \
  cargo run --locked --manifest-path ui/Cargo.toml -p shadow-compositor \
  >"$COMPOSITOR_LOG" 2>&1 </dev/null &
compositor_pid=$!

nested_wayland=""
for _ in $(seq 1 180); do
  if ! kill -0 "$compositor_pid" 2>/dev/null; then
    echo "ui-vm-shadow-run: shadow-compositor exited before becoming ready" >&2
    tail -n 200 "$COMPOSITOR_LOG" >&2 || true
    wait "$compositor_pid" || true
    exit 1
  fi

  nested_wayland="$(find_nested_wayland)"

  if [[ -S "$control_socket" && -n "$nested_wayland" ]]; then
    break
  fi

  sleep 1
done

if [[ -z "$nested_wayland" || ! -S "$control_socket" ]]; then
  echo "ui-vm-shadow-run: timed out waiting for nested compositor socket/control" >&2
  tail -n 200 "$COMPOSITOR_LOG" >&2 || true
  exit 1
fi

write_compositor_env "$nested_wayland" "$control_socket"

echo "ui-vm-shadow-run: launched shadow-compositor on $nested_wayland"
echo "ui-vm-shadow-run: control socket $control_socket"
matching_processes || true
EOF

exec "$SCRIPT_DIR/ui_vm_ssh.sh" "bash -c $(printf '%q' "$REMOTE_SCRIPT")"
