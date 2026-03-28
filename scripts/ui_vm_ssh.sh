#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=./ui_vm_common.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ui_vm_common.sh"

ui_vm_write_identity_file

exec ssh \
  -p "$SHADOW_UI_VM_SSH_PORT" \
  -o LogLevel=ERROR \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  shadow@127.0.0.1 \
  "$@"
