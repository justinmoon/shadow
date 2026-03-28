#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER_LINK="$REPO_ROOT/.shadow-vm/ui-vm-runner"
SOCKET_PATH="$REPO_ROOT/.shadow-vm/shadow-ui-vm.sock"
PROCESS_PATTERN='microvm@shadow-ui-vm'

cd "$REPO_ROOT"

process_running() {
  pgrep -f "$PROCESS_PATTERN" >/dev/null
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
  pkill -TERM -f "$PROCESS_PATTERN" 2>/dev/null || true
  if wait_for_stop 3; then
    return 0
  fi

  pkill -KILL -f "$PROCESS_PATTERN" 2>/dev/null || true
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
