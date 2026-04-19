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

ui_vm_runtime_artifact_dir() {
  printf '%s/runtime-artifacts\n' "$(ui_vm_state_dir)"
}

ui_vm_runtime_env_path() {
  printf '%s/runtime-system-session-env.sh\n' "$(ui_vm_runtime_artifact_dir)"
}

ui_vm_runtime_guest_dir() {
  printf '/opt/shadow-runtime\n'
}

ui_vm_socket_path() {
  printf '%s/shadow-ui-vm.sock\n' "$(ui_vm_state_dir)"
}

ui_vm_ssh_port() {
  if [[ -n "${SHADOW_UI_VM_SSH_PORT:-}" ]]; then
    printf '%s\n' "$SHADOW_UI_VM_SSH_PORT"
    return 0
  fi

  python3 - "$(ui_vm_repo_root)" <<'PY'
import hashlib
import sys

path = sys.argv[1]
base = 44000
span = 10000
digest = hashlib.sha256(path.encode("utf-8")).hexdigest()
print(base + (int(digest[:8], 16) % span))
PY
}

ui_vm_build_runner() {
  mkdir -p "$(ui_vm_state_dir)" "$(ui_vm_runtime_artifact_dir)"
  SHADOW_UI_VM_SSH_PORT="$(ui_vm_ssh_port)" \
    nix build --impure --accept-flake-config -o "$(ui_vm_runner_link)" .#ui-vm-ci >/dev/null
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
