#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"

pixel_adb "$serial" shell settings put global stay_on_while_plugged_in 15
pixel_adb "$serial" shell settings put system screen_off_timeout 1800000
pixel_adb "$serial" shell settings put secure screensaver_enabled 0
pixel_adb "$serial" shell settings put secure screensaver_activate_on_dock 0
pixel_adb "$serial" shell settings put secure screensaver_activate_on_sleep 0
pixel_adb "$serial" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
pixel_adb "$serial" shell wm dismiss-keyguard >/dev/null 2>&1 || true

cat <<EOF
Pixel prep settings applied on $serial
stay_on_while_plugged_in=$(pixel_adb "$serial" shell settings get global stay_on_while_plugged_in | tr -d '\r')
screen_off_timeout=$(pixel_adb "$serial" shell settings get system screen_off_timeout | tr -d '\r')
screensaver_enabled=$(pixel_adb "$serial" shell settings get secure screensaver_enabled | tr -d '\r')
screensaver_activate_on_dock=$(pixel_adb "$serial" shell settings get secure screensaver_activate_on_dock | tr -d '\r')
screensaver_activate_on_sleep=$(pixel_adb "$serial" shell settings get secure screensaver_activate_on_sleep | tr -d '\r')
EOF
