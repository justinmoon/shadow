#!/usr/bin/env bash

ui_vm_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

ui_vm_state_dir() {
  printf '%s/.shadow-vm\n' "$(ui_vm_repo_root)"
}

ui_vm_ssh_share_dir() {
  printf '%s/ssh\n' "$(ui_vm_state_dir)"
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

ui_vm_runtime_config_path() {
  printf '%s/session-config.json\n' "$(ui_vm_runtime_artifact_dir)"
}

ui_vm_runtime_guest_dir() {
  printf '/opt/shadow-runtime\n'
}

ui_vm_socket_path() {
  printf '%s/shadow-ui-vm.sock\n' "$(ui_vm_state_dir)"
}

ui_vm_ssh_key_path() {
  printf '%s/shadow-ui-vm-key\n' "$(ui_vm_state_dir)"
}

ui_vm_ssh_public_key_path() {
  printf '%s.pub\n' "$(ui_vm_ssh_key_path)"
}

ui_vm_prepare_ssh_key() {
  local target_path public_path share_dir
  target_path="$(ui_vm_ssh_key_path)"
  public_path="$(ui_vm_ssh_public_key_path)"
  share_dir="$(ui_vm_ssh_share_dir)"
  mkdir -p "$share_dir"
  if [[ ! -f "$target_path" || ! -f "$public_path" ]]; then
    rm -f "$target_path" "$public_path"
    ssh-keygen -q -t ed25519 -N "" -C "shadow-ui-vm-ci" -f "$target_path"
    chmod 0600 "$target_path"
    chmod 0644 "$public_path"
  fi
  install -m 0600 "$public_path" "$share_dir/authorized_keys"
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

ui_vm_ssh() {
  ssh \
    -i "$(ui_vm_ssh_key_path)" \
    -p "$(ui_vm_ssh_port)" \
    -o IdentitiesOnly=yes \
    -o LogLevel=ERROR \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    shadow@127.0.0.1 \
    "$@"
}
