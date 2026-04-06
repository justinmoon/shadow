#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

export SHADOW_UI_SMOKE_NAMESPACE="${SHADOW_UI_SMOKE_NAMESPACE:-ci-$(worktree_basename)-ui-smoke-$$}"

just pre-commit
just ui-smoke
