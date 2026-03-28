#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=./ui_vm_common.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ui_vm_common.sh"

ui_vm_write_identity_file
cd "$REPO_ROOT"

process_running() {
  pgrep -f "$SHADOW_UI_VM_PROCESS_PATTERN" >/dev/null
}

wait_for_stop() {
  local attempts="$1"

  for _ in $(seq 1 "$attempts"); do
    if ! process_running; then
      return 0
    fi
    sleep 1
  done

  return 1
}

terminate_vm_process() {
  pkill -TERM -f "$SHADOW_UI_VM_PROCESS_PATTERN" 2>/dev/null || true
  if wait_for_stop 3; then
    return 0
  fi

  pkill -KILL -f "$SHADOW_UI_VM_PROCESS_PATTERN" 2>/dev/null || true
  wait_for_stop 3 || true
}

if [[ ! -S "$SOCKET_PATH" ]]; then
  if process_running; then
    terminate_vm_process
    exit 0
  fi
  echo "ui-vm-stop: VM is not running"
  exit 0
fi

mkdir -p .shadow-vm
if [[ ! -x "$RUNNER_LINK/bin/microvm-shutdown" ]]; then
  SHADOW_UI_VM_SOURCE="$REPO_ROOT" \
    SHADOW_UI_VM_NAME="$SHADOW_UI_VM_NAME" \
    SHADOW_UI_VM_HOSTNAME="$SHADOW_UI_VM_HOSTNAME" \
    SHADOW_UI_VM_SSH_PORT="$SHADOW_UI_VM_SSH_PORT" \
    SHADOW_UI_VM_QMP_SOCKET="$SHADOW_UI_VM_QMP_SOCKET" \
    SHADOW_UI_VM_MAC_ADDRESS="$SHADOW_UI_VM_MAC_ADDRESS" \
    SHADOW_UI_VM_UUID="$SHADOW_UI_VM_UUID" \
    nix build --impure --accept-flake-config -o "$RUNNER_LINK" .#ui-vm >/dev/null
fi

shutdown_pid=""
"$RUNNER_LINK/bin/microvm-shutdown" </dev/null >/dev/null 2>&1 &
shutdown_pid=$!

if wait_for_stop 10; then
  wait "$shutdown_pid" 2>/dev/null || true
  rm -f "$SOCKET_PATH"
  exit 0
fi

kill "$shutdown_pid" 2>/dev/null || true
wait "$shutdown_pid" 2>/dev/null || true

terminate_vm_process
rm -f "$SOCKET_PATH"
