#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ui_vm_common.sh
source "$SCRIPT_DIR/ui_vm_common.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER_LINK="$REPO_ROOT/.shadow-vm/ui-vm-runner"
SOCKET_PATH="$REPO_ROOT/.shadow-vm/shadow-ui-vm.sock"
RUNTIME_ENV_PATH="$REPO_ROOT/.shadow-vm/runtime-host-session-env.sh"

cd "$REPO_ROOT"
mkdir -p .shadow-vm
runtime_env_tmp=""
ui_vm_enable_podcast_app="${SHADOW_UI_VM_ENABLE_PODCAST_APP:-1}"
ui_vm_start_app_id="${SHADOW_UI_VM_START_APP_ID:-shell}"
ui_vm_state_dir="/var/lib/shadow-ui"
ui_vm_ssh_port_value="${SHADOW_UI_VM_SSH_PORT:-$(ui_vm_ssh_port)}"
runtime_audio_backend="${SHADOW_RUNTIME_AUDIO_BACKEND:-}"

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

if lsof -nP -iTCP:"$ui_vm_ssh_port_value" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "ui-vm-run: SSH port $ui_vm_ssh_port_value is already in use" >&2
  echo "ui-vm-run: stop the current worktree VM first with 'just ui-vm-stop' or set SHADOW_UI_VM_SSH_PORT" >&2
  exit 1
fi

if [[ -S "$SOCKET_PATH" ]]; then
  rm -f "$SOCKET_PATH"
fi

rm -f .shadow-vm/nix-store-overlay.img
if [[ ! -s "$RUNTIME_ENV_PATH" || -n "${SHADOW_UI_VM_REFRESH_RUNTIME_ENV:-}" ]] \
  || ! grep -Fq 'SHADOW_RUNTIME_APP_CAMERA_BUNDLE_PATH=' "$RUNTIME_ENV_PATH" 2>/dev/null \
  || ! grep -Fq 'SHADOW_RUNTIME_APP_TIMELINE_BUNDLE_PATH=' "$RUNTIME_ENV_PATH" 2>/dev/null \
  || ! grep -Fq 'SHADOW_RUNTIME_APP_CASHU_BUNDLE_PATH=' "$RUNTIME_ENV_PATH" 2>/dev/null \
  || ! grep -Fq 'SHADOW_RUNTIME_CASHU_DATA_DIR=/var/lib/shadow-ui/runtime-cashu' "$RUNTIME_ENV_PATH" 2>/dev/null \
  || ! grep -Fq 'SHADOW_RUNTIME_NOSTR_DB_PATH=/var/lib/shadow-ui/runtime-nostr.sqlite3' "$RUNTIME_ENV_PATH" 2>/dev/null \
  || { [[ "$ui_vm_enable_podcast_app" == "1" ]] && ! grep -Fq 'SHADOW_RUNTIME_APP_PODCAST_BUNDLE_PATH=' "$RUNTIME_ENV_PATH" 2>/dev/null; } \
  || { [[ "$ui_vm_start_app_id" == "shell" ]] && grep -Fq 'SHADOW_COMPOSITOR_AUTO_LAUNCH=' "$RUNTIME_ENV_PATH" 2>/dev/null; } \
  || { [[ "$ui_vm_start_app_id" != "shell" ]] && ! grep -Fq "SHADOW_COMPOSITOR_START_APP_ID=$ui_vm_start_app_id" "$RUNTIME_ENV_PATH" 2>/dev/null; } \
  || { [[ -z "$runtime_audio_backend" ]] && grep -Fq 'SHADOW_RUNTIME_AUDIO_BACKEND=' "$RUNTIME_ENV_PATH" 2>/dev/null; } \
  || { [[ -n "$runtime_audio_backend" ]] && ! grep -Fqx "export SHADOW_RUNTIME_AUDIO_BACKEND=$runtime_audio_backend" "$RUNTIME_ENV_PATH" 2>/dev/null; } \
  || ! grep -Fq "SHADOW_RUNTIME_CASHU_DATA_DIR=$ui_vm_state_dir/runtime-cashu" "$RUNTIME_ENV_PATH" 2>/dev/null \
  || ! grep -Fq "SHADOW_RUNTIME_NOSTR_DB_PATH=$ui_vm_state_dir/runtime-nostr.sqlite3" "$RUNTIME_ENV_PATH" 2>/dev/null; then
  runtime_env_tmp="$(mktemp "$REPO_ROOT/.shadow-vm/runtime-host-session-env.XXXXXX")"
  SHADOW_RUNTIME_APP_BUNDLE_REWRITE_FROM="$REPO_ROOT" \
  SHADOW_RUNTIME_APP_BUNDLE_REWRITE_TO="/work/shadow" \
  SHADOW_RUNTIME_AUDIO_BACKEND="$runtime_audio_backend" \
  SHADOW_STATE_DIR="/var/lib/shadow-ui" \
  SHADOW_RUNTIME_ENABLE_PODCAST_APP="$ui_vm_enable_podcast_app" \
  SHADOW_STATE_DIR="$ui_vm_state_dir" \
  SHADOW_RUNTIME_HOST_PACKAGE_ATTR_OVERRIDE="${SHADOW_UI_VM_RUNTIME_HOST_PACKAGE_ATTR:-$ui_vm_runtime_host_package_attr_default}" \
  SHADOW_RUNTIME_HOST_BINARY_NAME_OVERRIDE="${SHADOW_UI_VM_RUNTIME_HOST_BINARY_NAME:-shadow-runtime-host}" \
    ./scripts/runtime_prepare_host_session_env.sh >"$runtime_env_tmp"
  case "$ui_vm_start_app_id" in
    shell)
      ;;
    counter|timeline|camera|podcast|cashu)
      {
        printf 'export SHADOW_COMPOSITOR_AUTO_LAUNCH=1\n'
        printf 'export SHADOW_COMPOSITOR_START_APP_ID=%q\n' "$ui_vm_start_app_id"
      } >>"$runtime_env_tmp"
      ;;
    *)
      echo "ui-vm-run: unsupported SHADOW_UI_VM_START_APP_ID=$ui_vm_start_app_id" >&2
      exit 1
      ;;
  esac
  mv "$runtime_env_tmp" "$RUNTIME_ENV_PATH"
  chmod 0644 "$RUNTIME_ENV_PATH"
  runtime_env_tmp=""
fi
SHADOW_UI_VM_SOURCE="$REPO_ROOT" \
  SHADOW_UI_VM_SSH_PORT="$ui_vm_ssh_port_value" \
  nix build --impure --accept-flake-config -o "$RUNNER_LINK" .#ui-vm >/dev/null

echo "ui-vm-run: launching Shadow UI VM"
echo "ui-vm-run: qemu window will host the real Linux compositor"
echo "ui-vm-run: ssh endpoint shadow@127.0.0.1:$ui_vm_ssh_port_value"
echo "ui-vm-run: state image .shadow-vm/shadow-ui-state.img"
echo "ui-vm-run: first boot or dependency changes may spend time compiling in guest"
echo "ui-vm-run: use 'just ui-vm-doctor' or 'just ui-vm-wait-ready' while the screen is blank"

trap - EXIT
exec "$RUNNER_LINK/bin/microvm-run"
