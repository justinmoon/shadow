#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

bash -n scripts/*.sh
nix flake check --no-build
just ui-check

if [[ -f "$(cached_boot_image)" && -f "$(cached_init_boot_image)" && -f "$(cached_avb_testkey)" ]]; then
  just init-boot-repack
  scripts/assert_repacked_identity.sh
else
  echo "pre-commit: skipping init_boot repack; local artifact cache is missing"
  echo "pre-commit: run 'just artifacts-fetch' once, or rely on 'just ci' for the remote-backed path"
fi
