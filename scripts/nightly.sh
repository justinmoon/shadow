#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shadow_common.sh
source "$SCRIPT_DIR/shadow_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

# Keep nightly truthful until the heavier lanes exist.
just pre-merge
