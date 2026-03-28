#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER_LINK="$REPO_ROOT/.shadow-vm/ui-vm-runner"
SOCKET_PATH="$REPO_ROOT/.shadow-vm/shadow-ui-vm.sock"

cd "$REPO_ROOT"
mkdir -p .shadow-vm

if [[ -S "$SOCKET_PATH" ]]; then
  if pgrep -f 'microvm@shadow-ui-vm' >/dev/null; then
    echo "ui-vm-run: VM socket already exists at $SOCKET_PATH" >&2
    echo "ui-vm-run: stop the current VM first with 'just ui-vm-stop'" >&2
    exit 1
  fi
  rm -f "$SOCKET_PATH"
fi

rm -f .shadow-vm/nix-store-overlay.img
SHADOW_UI_VM_SOURCE="$REPO_ROOT" \
  nix build --impure --accept-flake-config -o "$RUNNER_LINK" .#ui-vm >/dev/null

echo "ui-vm-run: launching Shadow UI VM"
echo "ui-vm-run: qemu window will host the real Linux compositor"
echo "ui-vm-run: ssh endpoint shadow@127.0.0.1:2222"
echo "ui-vm-run: state image .shadow-vm/shadow-ui-state.img"
echo "ui-vm-run: first boot or dependency changes may spend time compiling in guest"

exec "$RUNNER_LINK/bin/microvm-run"
