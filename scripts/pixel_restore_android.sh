#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
pixel_root_shell "$serial" "$(pixel_takeover_start_services_script)"
if ! pixel_wait_for_condition 15 1 pixel_android_display_restored "$serial"; then
  echo "pixel_restore_android: Android display stack did not restore cleanly" >&2
  exit 1
fi
printf 'Pixel Android display stack restored on %s\n' "$serial"
