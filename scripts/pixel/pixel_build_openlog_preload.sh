#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs
repo="$(repo_root)"
artifact="$(pixel_artifact_path shadow-openlog-preload.so)"
source_path="$repo/scripts/pixel/pixel_openlog_preload.c"

nix shell --accept-flake-config 'nixpkgs#pkgsCross.aarch64-multiplatform.stdenv.cc' -c bash -lc "
set -euo pipefail
aarch64-unknown-linux-gnu-gcc \
  -shared -fPIC -O2 -Wall -Wextra \
  -o $(printf '%q' "$artifact") \
  $(printf '%q' "$source_path") \
  -ldl
"

chmod 0755 "$artifact"
file "$artifact"
printf 'Built shadow-openlog-preload -> %s\n' "$artifact"
