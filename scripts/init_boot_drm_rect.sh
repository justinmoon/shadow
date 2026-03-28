#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_IMAGE="${INIT_BOOT_OUT:-$(build_dir)/init_boot.drm_rect.img}"
DRM_RECT_BIN="${DRM_RECT_BIN:-$(build_dir)/drm-rect}"
SHADOW_SESSION_BIN="${SHADOW_SESSION_BIN:-$(build_dir)/shadow-session}"
SHADOW_SESSION_RC="${SHADOW_SESSION_RC:-$(build_dir)/init.shadow.drm-rect.rc}"
INIT_CUTF_CVM_RC="${INIT_CUTF_CVM_RC:-$(build_dir)/init.cutf_cvm.shadow.rc}"

if [[ ! -f "$DRM_RECT_BIN" ]]; then
  "$SCRIPT_DIR/build_drm_rect.sh"
fi

if [[ ! -f "$SHADOW_SESSION_BIN" ]]; then
  "$SCRIPT_DIR/build_shadow_session.sh"
fi

"$SCRIPT_DIR/write_shadow_session_rc.sh" \
  --mode drm-rect \
  --output "$SHADOW_SESSION_RC"

printf '%s\n' \
  'import /vendor/etc/init/hw/init.cutf_cvm.rc' \
  >"$INIT_CUTF_CVM_RC"
printf '\n' >>"$INIT_CUTF_CVM_RC"
cat "$SHADOW_SESSION_RC" >>"$INIT_CUTF_CVM_RC"

"$SCRIPT_DIR/init_boot_wrapper.sh" \
  --output "$OUTPUT_IMAGE" \
  --extra-bin /drm-rect="$DRM_RECT_BIN" \
  --extra-bin /shadow-session="$SHADOW_SESSION_BIN" \
  --extra-file /init.shadow.rc="$SHADOW_SESSION_RC" \
  --extra-file /init.cutf_cvm.rc="$INIT_CUTF_CVM_RC"
