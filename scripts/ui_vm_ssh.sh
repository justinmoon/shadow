#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=./ui_vm_common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ui_vm_common.sh"

exec ssh \
  -p "$(ui_vm_ssh_port)" \
  -o LogLevel=ERROR \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  shadow@127.0.0.1 \
  "$@"
