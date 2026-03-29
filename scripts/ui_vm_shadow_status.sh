#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/ui_vm_ssh.sh" '
  echo "== nested compositor env =="
  cat /var/lib/shadow-ui/shadow-compositor-session-env.sh 2>/dev/null || echo "(missing)"
  echo
  echo "== shadow processes =="
  ps -ef | grep -E "weston|shadow-compositor|shadow-counter|shadow-status|shadow-blitz-demo|cargo run( --locked)? --manifest-path ui/Cargo.toml" | grep -v grep || true
'
