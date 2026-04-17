#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

repo="$(repo_root)"
package_system="${PIXEL_LINUX_BUILD_SYSTEM:-aarch64-linux}"
package_ref="$repo#packages.${package_system}.shadow-local-turnip-mesa-aarch64-linux"
local_mesa_source="${SHADOW_LOCAL_MESA_SOURCE:-$HOME/code/mesa}"
turnip_out_link="$(pixel_dir)/shadow-local-turnip-mesa-aarch64-linux-result"

if [[ ! -d "$local_mesa_source" ]]; then
  echo "pixel_build_local_turnip: missing local Mesa checkout: $local_mesa_source" >&2
  exit 1
fi

export SHADOW_LOCAL_MESA_SOURCE="$local_mesa_source"
pixel_prepare_dirs

turnip_out="$(
  nix build \
    --accept-flake-config \
    --impure \
    --out-link "$turnip_out_link" \
    --print-out-paths \
    "$package_ref" | tail -n 1
)"
turnip_lib="$turnip_out/lib/libvulkan_freedreno.so"

if [[ ! -f "$turnip_lib" ]]; then
  echo "pixel_build_local_turnip: missing libvulkan_freedreno.so in $turnip_out" >&2
  exit 1
fi

python3 - "$local_mesa_source" "$package_ref" "$turnip_out" "$turnip_lib" <<'PY'
import json
import os
import sys

local_mesa_source, package_ref, turnip_out, turnip_lib = sys.argv[1:5]
print(json.dumps({
    "localMesaSource": os.path.abspath(local_mesa_source),
    "packageRef": package_ref,
    "turnipOutputPath": os.path.abspath(turnip_out),
    "turnipLibPath": os.path.abspath(turnip_lib),
}, indent=2))
PY
