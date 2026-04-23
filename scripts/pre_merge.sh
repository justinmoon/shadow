#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shadow_common.sh
source "$SCRIPT_DIR/lib/shadow_common.sh"
# shellcheck source=./ci_common.sh
source "$SCRIPT_DIR/lib/ci_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

if shadow_ci_can_run_locally; then
  exec "$SCRIPT_DIR/ci/linux_pre_merge.sh"
fi

just pre-commit
boot_demo_changed_files="$(shadow_ci_boot_demo_changed_files)"
if [[ -n "${SHADOW_FORCE_BOOT_DEMO_CHECK:-}" || -n "$boot_demo_changed_files" ]]; then
  boot_demo_mode="run"
else
  boot_demo_mode="skip"
fi

SHADOW_CI_RUN_ID="${SHADOW_CI_RUN_ID:-$(shadow_ci_run_id)}" \
SHADOW_SKIP_PRE_COMMIT=1 \
SHADOW_BOOT_DEMO_CHECK_MODE="$boot_demo_mode" \
SHADOW_BOOT_DEMO_CHANGED_FILES="$boot_demo_changed_files" \
  exec "$SCRIPT_DIR/ci/remote_ci.sh" pre-merge
