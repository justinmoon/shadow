#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shadow_common.sh
source "$SCRIPT_DIR/lib/shadow_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

just pre-commit
host_system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build --accept-flake-config --no-link -L ".#checks.${host_system}.preMergeCheck"
scripts/ci/pixel_boot_demo_check.sh --if-changed
"$SCRIPT_DIR/ci/required_vm_smoke.sh"
