#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

INSTANCE="$(active_instance_name)"
if [[ -z "$INSTANCE" ]]; then
  echo "cf_kill: no recorded instance" >&2
  exit 1
fi

ADB_PORT="$(adb_port_for_instance "$INSTANCE")"
printf 'Cleaning up cuttlefish instance %s on %s\n' "$INSTANCE" "$REMOTE_HOST"
cleanup_remote_instance "$INSTANCE" "$ADB_PORT"
if [[ "$(recorded_instance 2>/dev/null || true)" == "$INSTANCE" ]]; then
  clear_recorded_instance
fi
