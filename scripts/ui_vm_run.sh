#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER_LINK="$REPO_ROOT/.shadow-vm/ui-vm-runner"
SOCKET_PATH="$REPO_ROOT/.shadow-vm/shadow-ui-vm.sock"
RUNTIME_ENV_PATH="$REPO_ROOT/.shadow-vm/runtime-host-session-env.sh"

cd "$REPO_ROOT"
mkdir -p .shadow-vm
runtime_env_tmp=""

case "$(uname -m)" in
  arm64|aarch64)
    ui_vm_runtime_host_package_attr_default="shadow-runtime-host-aarch64-linux-gnu"
    ;;
  x86_64)
    ui_vm_runtime_host_package_attr_default="shadow-runtime-host-x86_64-linux-gnu"
    ;;
  *)
    echo "ui-vm-run: unsupported host arch $(uname -m) for runtime host package selection" >&2
    exit 1
    ;;
esac

cleanup_runtime_env_tmp() {
  if [[ -n "${runtime_env_tmp:-}" ]]; then
    rm -f "$runtime_env_tmp"
  fi
}

trap cleanup_runtime_env_tmp EXIT

if [[ -S "$SOCKET_PATH" ]]; then
  if pgrep -f 'microvm@shadow-ui-vm' >/dev/null; then
    echo "ui-vm-run: VM socket already exists at $SOCKET_PATH" >&2
    echo "ui-vm-run: stop the current VM first with 'just ui-vm-stop'" >&2
    exit 1
  fi
  rm -f "$SOCKET_PATH"
fi

rm -f .shadow-vm/nix-store-overlay.img
if [[ ! -s "$RUNTIME_ENV_PATH" || -n "${SHADOW_UI_VM_REFRESH_RUNTIME_ENV:-}" ]] \
  || ! grep -Fq 'SHADOW_RUNTIME_APP_TIMELINE_BUNDLE_PATH=' "$RUNTIME_ENV_PATH" 2>/dev/null; then
  runtime_env_tmp="$(mktemp "$REPO_ROOT/.shadow-vm/runtime-host-session-env.XXXXXX")"
  SHADOW_RUNTIME_APP_BUNDLE_REWRITE_FROM="$REPO_ROOT" \
  SHADOW_RUNTIME_APP_BUNDLE_REWRITE_TO="/work/shadow" \
  SHADOW_RUNTIME_HOST_PACKAGE_ATTR_OVERRIDE="${SHADOW_UI_VM_RUNTIME_HOST_PACKAGE_ATTR:-$ui_vm_runtime_host_package_attr_default}" \
  SHADOW_RUNTIME_HOST_BINARY_NAME_OVERRIDE="${SHADOW_UI_VM_RUNTIME_HOST_BINARY_NAME:-shadow-runtime-host}" \
    ./scripts/runtime_prepare_host_session_env.sh >"$runtime_env_tmp"
  mv "$runtime_env_tmp" "$RUNTIME_ENV_PATH"
  chmod 0644 "$RUNTIME_ENV_PATH"
  runtime_env_tmp=""
fi
SHADOW_UI_VM_SOURCE="$REPO_ROOT" \
  nix build --impure --accept-flake-config -o "$RUNNER_LINK" .#ui-vm >/dev/null

echo "ui-vm-run: launching Shadow UI VM"
echo "ui-vm-run: qemu window will host the real Linux compositor"
echo "ui-vm-run: ssh endpoint shadow@127.0.0.1:2222"
echo "ui-vm-run: state image .shadow-vm/shadow-ui-state.img"
echo "ui-vm-run: first boot or dependency changes may spend time compiling in guest"
echo "ui-vm-run: use 'just ui-vm-doctor' or 'just ui-vm-wait-ready' while the screen is blank"

trap - EXIT
exec "$RUNNER_LINK/bin/microvm-run"
