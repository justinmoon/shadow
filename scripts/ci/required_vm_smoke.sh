#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./shadow_common.sh
source "$SCRIPT_DIR/lib/shadow_common.sh"
# shellcheck source=./ci_vm_smoke_common.sh
source "$SCRIPT_DIR/lib/ci_vm_smoke_common.sh"

REPO_ROOT="$(repo_root)"
ROOT_REPO="$(vm_smoke_root_repo "$REPO_ROOT")"
current_inputs_path="$(vm_smoke_inputs_path "$REPO_ROOT")"

if [[ "$ROOT_REPO" != "$REPO_ROOT" ]] \
  && [[ "$(git -C "$ROOT_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)" == "master" ]] \
  && [[ -z "$(git -C "$ROOT_REPO" status --short 2>/dev/null || true)" ]]; then
  if root_inputs_path="$(vm_smoke_inputs_path "$ROOT_REPO" 2>/dev/null)"; then
    if [[ "$current_inputs_path" == "$root_inputs_path" ]]; then
      echo "pre-merge: skip vm smoke; logical inputs match root master"
      exit 0
    fi
  fi
fi

if vm_smoke_has_cached_success "$current_inputs_path" "$REPO_ROOT"; then
  echo "pre-merge: reuse vm smoke for logical inputs $current_inputs_path"
  exit 0
fi

exec "$SCRIPT_DIR/ci/ui_vm_smoke.sh" --prepared-inputs "$current_inputs_path"
