#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

target="${1:-desktop}"

case "$target" in
  desktop|vm|pixel)
    ;;
  *)
    export PIXEL_SERIAL="$target"
    target="pixel"
    ;;
esac

case "$target" in
  desktop)
    echo "ui-stop: target=desktop has no managed stop action" >&2
    ;;
  vm)
    exec "$SCRIPT_DIR/ui_vm_stop.sh"
    ;;
  pixel)
    exec "$SCRIPT_DIR/pixel_restore_android.sh"
    ;;
  *)
    echo "ui-stop: unsupported target '$target'" >&2
    exit 1
    ;;
esac
