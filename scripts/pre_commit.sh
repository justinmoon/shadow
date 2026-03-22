#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

bash -n scripts/*.sh
nix flake check --no-build
just artifacts-fetch
just init-boot-repack
scripts/assert_repacked_identity.sh
