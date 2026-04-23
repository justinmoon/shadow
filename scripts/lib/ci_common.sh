#!/usr/bin/env bash

shadow_ci_system() {
  printf '%s\n' "${SHADOW_CI_SYSTEM:-x86_64-linux}"
}

shadow_ci_remote_host() {
  printf '%s\n' "${SHADOW_CI_REMOTE_HOST:-pika-build}"
}

shadow_ci_current_system() {
  nix eval --impure --raw --expr builtins.currentSystem
}

shadow_ci_can_run_locally() {
  local current_system
  current_system="$(shadow_ci_current_system)"
  [[ "${SHADOW_CI_FORCE_REMOTE:-0}" != "1" ]] \
    && [[ "$current_system" == "$(shadow_ci_system)" ]] \
    && [[ "$current_system" == *-linux ]]
}

shadow_ci_run_id() {
  if [[ -n "${SHADOW_CI_RUN_ID:-}" ]]; then
    printf '%s\n' "$SHADOW_CI_RUN_ID"
    return 0
  fi

  python3 - <<'PY'
import datetime
import os
import secrets

ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
pid = os.getpid()
token = secrets.token_hex(3)
print(f"{ts}-{pid}-{token}")
PY
}

shadow_ci_repo_key() {
  python3 - "$(repo_common_root)" "$(worktree_basename)" <<'PY'
import hashlib
import pathlib
import re
import sys

repo_root = pathlib.Path(sys.argv[1]).resolve()
worktree = sys.argv[2] or "shadow"
safe_worktree = re.sub(r"[^a-zA-Z0-9._-]+", "-", worktree).strip("-") or "shadow"
digest = hashlib.sha256(str(repo_root).encode("utf-8")).hexdigest()[:10]
print(f"{safe_worktree}-{digest}")
PY
}

shadow_ci_remote_base_dir() {
  printf '%s/.cache/shadow-ci/worktrees/%s\n' \
    "$(remote_home)" \
    "$(shadow_ci_repo_key)"
}

shadow_ci_remote_repo_dir() {
  printf '%s/repo\n' "$(shadow_ci_remote_base_dir)"
}

shadow_ci_summary_dir() {
  printf '%s/build/ci/runs\n' "$(repo_root)"
}

shadow_ci_boot_demo_changed_files() {
  scripts/ci/pixel_boot_demo_check.sh --print-changed-files
}

shadow_ci_root_master_vm_smoke_inputs_id() {
  local root_repo target_system master_rev
  root_repo="$(repo_common_root)"
  target_system="$(shadow_ci_system)"
  if [[ "$(git -C "$root_repo" rev-parse --abbrev-ref HEAD 2>/dev/null || true)" != "master" ]]; then
    return 1
  fi
  if [[ -n "$(git -C "$root_repo" status --short 2>/dev/null || true)" ]]; then
    return 1
  fi
  master_rev="$(git -C "$root_repo" rev-parse master 2>/dev/null || true)"
  if [[ -z "$master_rev" ]]; then
    return 1
  fi
  nix path-info --accept-flake-config --derivation \
    "git+file://${root_repo}?rev=${master_rev}#packages.${target_system}.vm-smoke-inputs"
}
