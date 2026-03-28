#!/usr/bin/env bash

ui_vm_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

ui_vm_state_dir() {
  printf '%s/.shadow-vm\n' "$(ui_vm_repo_root)"
}

ui_vm_runner_link() {
  printf '%s/ui-vm-runner\n' "$(ui_vm_state_dir)"
}

ui_vm_socket_path() {
  printf '%s/shadow-ui-vm.sock\n' "$(ui_vm_state_dir)"
}

ui_vm_ssh_port() {
  printf '%s\n' "${SHADOW_UI_VM_SSH_PORT:-2222}"
}

ui_vm_build_runner() {
  mkdir -p "$(ui_vm_state_dir)"
  SHADOW_UI_VM_SOURCE="$(ui_vm_repo_root)" \
    nix build --impure --accept-flake-config -o "$(ui_vm_runner_link)" .#ui-vm >/dev/null
}

ui_vm_ssh() {
  ssh \
    -p "$(ui_vm_ssh_port)" \
    -o LogLevel=ERROR \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    shadow@127.0.0.1 \
    "$@"
}
