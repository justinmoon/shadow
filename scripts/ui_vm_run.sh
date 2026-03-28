#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ui_vm_common.sh
source "$SCRIPT_DIR/ui_vm_common.sh"

ui_vm_write_identity_file
cd "$REPO_ROOT"

if [[ -S "$SOCKET_PATH" ]]; then
  if pgrep -f "$SHADOW_UI_VM_PROCESS_PATTERN" >/dev/null; then
    echo "ui-vm-run: VM socket already exists at $SOCKET_PATH" >&2
    echo "ui-vm-run: stop the current VM first with 'just ui-vm-stop'" >&2
    exit 1
  fi
  rm -f "$SOCKET_PATH"
fi

rm -f .shadow-vm/nix-store-overlay.img
SHADOW_UI_VM_SOURCE="$REPO_ROOT" \
  SHADOW_UI_VM_NAME="$SHADOW_UI_VM_NAME" \
  SHADOW_UI_VM_HOSTNAME="$SHADOW_UI_VM_HOSTNAME" \
  SHADOW_UI_VM_SSH_PORT="$SHADOW_UI_VM_SSH_PORT" \
  SHADOW_UI_VM_QMP_SOCKET="$SHADOW_UI_VM_QMP_SOCKET" \
  SHADOW_UI_VM_MAC_ADDRESS="$SHADOW_UI_VM_MAC_ADDRESS" \
  SHADOW_UI_VM_UUID="$SHADOW_UI_VM_UUID" \
  nix build --impure --accept-flake-config -o "$RUNNER_LINK" .#ui-vm >/dev/null

echo "ui-vm-run: launching Shadow UI VM"
echo "ui-vm-run: instance $SHADOW_UI_VM_NAME"
echo "ui-vm-run: qemu window will host the real Linux compositor"
echo "ui-vm-run: ssh endpoint shadow@127.0.0.1:$SHADOW_UI_VM_SSH_PORT"
echo "ui-vm-run: state image .shadow-vm/shadow-ui-state.img"
echo "ui-vm-run: first boot or dependency changes may spend time compiling in guest"

exec "$RUNNER_LINK/bin/microvm-run"
