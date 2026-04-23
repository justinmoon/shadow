#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./shadow_common.sh
source "$SCRIPT_DIR/lib/shadow_common.sh"
# shellcheck source=./ci_vm_smoke_common.sh
source "$SCRIPT_DIR/lib/ci_vm_smoke_common.sh"

REPO_ROOT="$(repo_root)"
ROOT_REPO="$(vm_smoke_root_repo "$REPO_ROOT")"
current_inputs_id="$(vm_smoke_inputs_drv_path "$REPO_ROOT")"
root_master_inputs_id="${SHADOW_VM_SMOKE_ROOT_MASTER_INPUTS_ID:-}"

if [[ -n "$root_master_inputs_id" && "$current_inputs_id" == "$root_master_inputs_id" ]]; then
  echo "pre-merge: skip vm smoke; logical inputs match root master"
  exit 0
fi

if ci_vm_smoke_has_git "$REPO_ROOT" \
  && [[ "$ROOT_REPO" != "$REPO_ROOT" ]] \
  && [[ "$(git -C "$ROOT_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)" == "master" ]] \
  && [[ -z "$(git -C "$ROOT_REPO" status --short 2>/dev/null || true)" ]]; then
  if root_inputs_id="$(vm_smoke_inputs_drv_path "$ROOT_REPO" 2>/dev/null)"; then
    if [[ "$current_inputs_id" == "$root_inputs_id" ]]; then
      echo "pre-merge: skip vm smoke; logical inputs match root master"
      exit 0
    fi
  fi
fi

if vm_smoke_has_cached_success "$current_inputs_id" "$REPO_ROOT"; then
  echo "pre-merge: reuse vm smoke for logical inputs $current_inputs_id"
  exit 0
fi

current_inputs_path="$(vm_smoke_inputs_path "$REPO_ROOT")"

exec "$SCRIPT_DIR/ci/ui_vm_smoke.sh" \
  --logical-inputs-id "$current_inputs_id" \
  --prepared-inputs "$current_inputs_path"
