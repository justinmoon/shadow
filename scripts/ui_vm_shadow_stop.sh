#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

read -r -d '' REMOTE_SCRIPT <<'EOF' || true
set -euo pipefail

STATE_DIR="/var/lib/shadow-ui"
COMPOSITOR_ENV_FILE="$STATE_DIR/shadow-compositor-session-env.sh"
LOG_FILE="$STATE_DIR/log/shadow-compositor.log"

matching_processes() {
  ps -eo pid=,comm=,args= | awk '
    $2 == "shadow-compositor" { print $1; next }
    $2 == "cargo" {
      command_start = index($0, $3)
      command = substr($0, command_start)
      if (command ~ "^cargo run( --locked)? --manifest-path ui/Cargo.toml -p shadow-compositor$") {
        print $1
      }
    }
  '
}

pids="$(matching_processes)"
if [[ -z "$pids" ]]; then
  rm -f "$COMPOSITOR_ENV_FILE"
  echo "ui-vm-shadow-stop: shadow-compositor is not running"
  exit 0
fi

while read -r pid; do
  [[ -n "$pid" ]] || continue
  kill -TERM "$pid" 2>/dev/null || true
done <<<"$pids"

for _ in $(seq 1 20); do
  if [[ -z "$(matching_processes)" ]]; then
    rm -f "$COMPOSITOR_ENV_FILE"
    echo "ui-vm-shadow-stop: stopped shadow-compositor"
    exit 0
  fi
  sleep 1
done

while read -r pid; do
  [[ -n "$pid" ]] || continue
  kill -KILL "$pid" 2>/dev/null || true
done <<<"$(matching_processes)"

rm -f "$COMPOSITOR_ENV_FILE"
echo "ui-vm-shadow-stop: force-stopped shadow-compositor"
tail -n 80 "$LOG_FILE" 2>/dev/null || true
EOF

exec "$SCRIPT_DIR/ui_vm_ssh.sh" "bash -c $(printf '%q' "$REMOTE_SCRIPT")"
