#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_IMAGE="${INIT_BOOT_OUT:-$(build_dir)/init_boot.drm_rect.img}"
DRM_RECT_BIN="${DRM_RECT_BIN:-$(build_dir)/drm-rect}"

if [[ ! -f "$DRM_RECT_BIN" ]]; then
  "$SCRIPT_DIR/build_drm_rect.sh"
fi

"$SCRIPT_DIR/init_boot_wrapper.sh" \
  --output "$OUTPUT_IMAGE" \
  --extra-bin /drm-rect="$DRM_RECT_BIN"
