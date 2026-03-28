#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/ui_vm_ssh.sh" \
  "journalctl -b -u greetd.service -u shadow-ui-smoke.service --no-pager"
