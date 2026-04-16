#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/ui_vm_ssh.sh" '
  systemctl --no-pager --full status shadow-ui-smoke.service || true
  echo
  echo "== shadow processes =="
  ps -ef | grep -E "shadow-compositor|shadow-blitz-demo" | grep -v grep || true
'
