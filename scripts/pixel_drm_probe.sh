#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs
serial="$(pixel_resolve_serial)"
repo="$(repo_root)"
out_link="$(pixel_dir)/drm-probe-result"
artifact="$(pixel_artifact_path drm-rect)"
probe_paths="${PIXEL_DRM_PROBE_PATHS-/dev/dri/card0:/dev/dri/renderD128}"

rm -f "$out_link"
nix build "$repo#drm-rect-device" --out-link "$out_link" >/dev/null
cp "$out_link/bin/drm-rect" "$artifact"
chmod 0755 "$artifact"
file "$artifact"

pixel_adb "$serial" push "$artifact" /data/local/tmp/drm-rect >/dev/null

pixel_root_shell "$serial" "id; getenforce; sh -c 'exec 3</dev/kgsl-3d0 && echo kgsl-open-ok || echo kgsl-open-fail'; SHADOW_DRM_RECT_MODE=probe SHADOW_DRM_PROBE_PATHS=$probe_paths /data/local/tmp/drm-rect"
