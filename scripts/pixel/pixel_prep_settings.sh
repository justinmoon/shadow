#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_args=()
if [[ -n "${PIXEL_SERIAL:-}" ]]; then
  target_args=(-t "$PIXEL_SERIAL")
fi

exec "$SCRIPT_DIR/shadowctl" prep-settings "${target_args[@]}" "$@"
