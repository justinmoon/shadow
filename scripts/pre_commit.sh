#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shadow_common.sh
source "$SCRIPT_DIR/shadow_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

bash -n scripts/*.sh
scripts/ui_run_arg_smoke.sh
scripts/ui_run_dispatch_smoke.sh
nix flake check --no-build
just ui-check
