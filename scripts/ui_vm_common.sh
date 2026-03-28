#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$REPO_ROOT/.shadow-vm"
RUNNER_LINK="$STATE_DIR/ui-vm-runner"
INSTANCE_ENV_FILE="$STATE_DIR/instance.env"

_ui_vm_shell_quote() {
  python3 - "$1" <<'PY'
import shlex
import sys

print(shlex.quote(sys.argv[1]))
PY
}

ui_vm_compute_identity() {
  python3 - "$REPO_ROOT" "$STATE_DIR" <<'PY'
import hashlib
import pathlib
import re
import shlex
import sys

repo_root = pathlib.Path(sys.argv[1]).resolve()
state_dir = pathlib.Path(sys.argv[2]).resolve()
raw_label = repo_root.name or "shadow"
label = re.sub(r"[^a-z0-9]+", "-", raw_label.lower()).strip("-") or "shadow"
digest = hashlib.sha256(str(repo_root).encode("utf-8")).hexdigest()
suffix = digest[:8]
instance_id = f"{label}-{suffix}"
vm_name = f"shadow-ui-vm-{instance_id}"
host_name = vm_name[:63]
ssh_port = 22000 + (int(digest[8:16], 16) % 20000)
qmp_socket = state_dir / f"{vm_name}.sock"
mac = f"02:00:{digest[0:2]}:{digest[2:4]}:{digest[4:6]}:{digest[6:8]}"
uuid_hex = digest[:32]
uuid = (
    f"{uuid_hex[0:8]}-{uuid_hex[8:12]}-{uuid_hex[12:16]}-"
    f"{uuid_hex[16:20]}-{uuid_hex[20:32]}"
)

fields = {
    "SHADOW_UI_VM_INSTANCE_ID": instance_id,
    "SHADOW_UI_VM_NAME": vm_name,
    "SHADOW_UI_VM_HOSTNAME": host_name,
    "SHADOW_UI_VM_PROCESS_PATTERN": f"microvm@{vm_name}",
    "SHADOW_UI_VM_SSH_PORT": str(ssh_port),
    "SHADOW_UI_VM_QMP_SOCKET": str(qmp_socket),
    "SHADOW_UI_VM_MAC_ADDRESS": mac,
    "SHADOW_UI_VM_UUID": uuid,
    "SHADOW_UI_VM_SOURCE": str(repo_root),
}

for key, value in fields.items():
    print(f"export {key}={shlex.quote(value)}")
PY
}

ui_vm_load_identity() {
  mkdir -p "$STATE_DIR"
  eval "$(ui_vm_compute_identity)"
  SOCKET_PATH="$SHADOW_UI_VM_QMP_SOCKET"
}

ui_vm_write_identity_file() {
  ui_vm_load_identity
  cat >"$INSTANCE_ENV_FILE" <<EOF
export SHADOW_UI_VM_INSTANCE_ID=$(_ui_vm_shell_quote "$SHADOW_UI_VM_INSTANCE_ID")
export SHADOW_UI_VM_NAME=$(_ui_vm_shell_quote "$SHADOW_UI_VM_NAME")
export SHADOW_UI_VM_HOSTNAME=$(_ui_vm_shell_quote "$SHADOW_UI_VM_HOSTNAME")
export SHADOW_UI_VM_PROCESS_PATTERN=$(_ui_vm_shell_quote "$SHADOW_UI_VM_PROCESS_PATTERN")
export SHADOW_UI_VM_SSH_PORT=$(_ui_vm_shell_quote "$SHADOW_UI_VM_SSH_PORT")
export SHADOW_UI_VM_QMP_SOCKET=$(_ui_vm_shell_quote "$SHADOW_UI_VM_QMP_SOCKET")
export SHADOW_UI_VM_MAC_ADDRESS=$(_ui_vm_shell_quote "$SHADOW_UI_VM_MAC_ADDRESS")
export SHADOW_UI_VM_UUID=$(_ui_vm_shell_quote "$SHADOW_UI_VM_UUID")
export SHADOW_UI_VM_SOURCE=$(_ui_vm_shell_quote "$SHADOW_UI_VM_SOURCE")
EOF
}
