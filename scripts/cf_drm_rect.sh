#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_IMAGE="${INIT_BOOT_OUT:-$(build_dir)/init_boot.drm_rect.img}"
DRM_MARKER="${DRM_RECT_WAIT_FOR:-shadow-drm.*success}"
BOOT_MARKER="${CF_WAIT_FOR:-VIRTUAL_DEVICE_BOOT_COMPLETED|GUEST_BUILD_FINGERPRINT}"
DRM_TIMEOUT_SECS="${DRM_RECT_TIMEOUT:-120}"
BOOT_TIMEOUT_SECS="${CF_WAIT_TIMEOUT:-180}"

"$SCRIPT_DIR/init_boot_drm_rect.sh" --output "$OUTPUT_IMAGE"
"$SCRIPT_DIR/cf_launch.sh" \
  --init-boot "$OUTPUT_IMAGE" \
  --wait-for "$DRM_MARKER" \
  --timeout "$DRM_TIMEOUT_SECS"

INSTANCE="$(active_instance_name)"
printf 'Waiting for Android boot marker: %s\n' "$BOOT_MARKER"
wait_for_remote_pattern "$INSTANCE" "$BOOT_MARKER" "$BOOT_TIMEOUT_SECS"
printf 'Boot marker observed for instance %s\n' "$INSTANCE"
