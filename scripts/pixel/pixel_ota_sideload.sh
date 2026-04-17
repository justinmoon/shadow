#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

"$SCRIPT_DIR/pixel/pixel_root_prep.sh"

serial="$(pixel_resolve_serial)"
ota_zip="$(pixel_root_ota_zip)"

cat <<EOF
Rebooting the Pixel into recovery.

When recovery appears on the phone:
1. Choose "Apply update".
2. Choose "Apply from ADB".
3. Leave the phone plugged in.

This script will wait for adb sideload mode and then send:
  $ota_zip
EOF

pixel_adb "$serial" reboot recovery
pixel_wait_for_sideload "$serial" 300

printf 'Starting adb sideload for %s\n' "$ota_zip"
adb -s "$serial" sideload "$ota_zip"

cat <<'EOF'
OTA sideload finished.

On the phone:
1. Choose "Reboot system now".
2. Let Android boot fully.
3. Re-enable USB debugging if Android asks again.

Then continue with:
  sc -t pixel root-patch
EOF
