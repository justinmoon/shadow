#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shadow_common.sh
source "$SCRIPT_DIR/shadow_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

bash -n scripts/*.sh
scripts/operator_cli_smoke.sh
scripts/timeline_sync_defaults_smoke.sh
nix flake check --no-build
just ui-check
