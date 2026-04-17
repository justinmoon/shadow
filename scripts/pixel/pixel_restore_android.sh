#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
pixel_root_shell "$serial" "$(pixel_takeover_start_services_script)"
if ! pixel_wait_for_condition 60 1 pixel_android_display_restored "$serial"; then
  if [[ "${PIXEL_RESTORE_ANDROID_REBOOT_ON_FAILURE:-1}" != "0" ]]; then
    echo "pixel_restore_android: direct restore did not complete cleanly; rebooting fallback" >&2
    if pixel_reboot_and_wait_android_display \
      "$serial" \
      "${PIXEL_TAKEOVER_RESTORE_REBOOT_TIMEOUT_SECS:-120}"; then
      printf 'Pixel Android display stack restored on %s via reboot fallback\n' "$serial"
      exit 0
    fi
  fi
  echo "pixel_restore_android: Android display stack did not restore cleanly" >&2
  exit 1
fi
printf 'Pixel Android display stack restored on %s\n' "$serial"
