#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

cleanup() {
  CUTTLEFISH_INSTANCE_OVERRIDE="ci-stock" just cf-kill >/dev/null 2>&1 || true
  CUTTLEFISH_INSTANCE_OVERRIDE="ci-repacked-initboot" just cf-kill >/dev/null 2>&1 || true
}

trap cleanup EXIT

just pre-commit

CUTTLEFISH_INSTANCE_OVERRIDE="ci-stock" just cf-stock
CUTTLEFISH_INSTANCE_OVERRIDE="ci-stock" just cf-kill

CUTTLEFISH_INSTANCE_OVERRIDE="ci-repacked-initboot" just cf-repacked-initboot
CUTTLEFISH_INSTANCE_OVERRIDE="ci-repacked-initboot" just cf-kill
