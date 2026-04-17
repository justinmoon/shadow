#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./ui_vm_common.sh
source "$SCRIPT_DIR/lib/ui_vm_common.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER_LINK="$REPO_ROOT/.shadow-vm/ui-vm-runner"
SOCKET_PATH="$REPO_ROOT/.shadow-vm/shadow-ui-vm.sock"
PROCESS_PORT="$(ui_vm_ssh_port)"

cd "$REPO_ROOT"

process_pids() {
  ps -Ao pid=,command= \
    | grep -F "microvm@shadow-ui-vm" \
    | grep -F "hostfwd=tcp::${PROCESS_PORT}-:22" \
    | awk '{print $1}'
}

process_running() {
  [[ -n "$(process_pids)" ]]
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
  local pids

  pids="$(process_pids)"
  [[ -n "$pids" ]] || return 0
  kill -TERM $pids 2>/dev/null || true
  if wait_for_stop 3; then
    return 0
  fi

  kill -KILL $pids 2>/dev/null || true
  wait_for_stop 3 || true
}

if [[ ! -S "$SOCKET_PATH" ]]; then
  if process_running; then
    terminate_vm_process
    exit 0
  fi
  echo "vm: VM is not running"
  exit 0
fi

mkdir -p .shadow-vm
if [[ ! -x "$RUNNER_LINK/bin/microvm-shutdown" ]]; then
  mkdir -p "$REPO_ROOT/.shadow-vm/runtime-artifacts"
  SHADOW_UI_VM_SSH_PORT="$PROCESS_PORT" \
    nix build --impure --accept-flake-config -o "$RUNNER_LINK" .#ui-vm-ci >/dev/null
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
