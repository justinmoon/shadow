#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shadow_common.sh
source "$SCRIPT_DIR/lib/shadow_common.sh"

require_clean_tree() {
  local repo_path="$1"
  local label="$2"
  if [[ "$(git -C "$repo_path" rev-parse --is-bare-repository)" == "true" ]]; then
    return 0
  fi
  if [[ -n "$(git -C "$repo_path" status --short)" ]]; then
    echo "land: $label has uncommitted changes" >&2
    git -C "$repo_path" status --short >&2
    exit 1
  fi
}

sync_dispatch_plans_from_root() {
  local project_file
  local project_id

  if [[ "$ROOT_IS_BARE" == "true" ]]; then
    echo "land: skipping dispatch plan sync for bare root repo"
    return 0
  fi
  if [[ ! -d "$ROOT_REPO/.agents/dispatch/projects" ]]; then
    return 0
  fi

  echo "land: linting dispatch plans from root master"
  (cd "$ROOT_REPO" && python3 scripts/debug/dispatch.py plan-lint --all)

  echo "land: importing dispatch plans from root master"
  for project_file in "$ROOT_REPO"/.agents/dispatch/projects/*.json; do
    [[ -e "$project_file" ]] || return 0
    project_id="$(basename "$project_file" .json)"
    (cd "$ROOT_REPO" && python3 scripts/debug/dispatch.py queue-import-plan --project "$project_id")
  done
}

REPO_ROOT="$(repo_root)"
COMMON_GIT_DIR="$(git rev-parse --path-format=absolute --git-common-dir)"
ROOT_REPO="$(cd "$COMMON_GIT_DIR/.." && pwd)"
EXPECTED_ROOT="$(cd "$REPO_ROOT/../.." && pwd)"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
ROOT_IS_BARE="$(git -C "$ROOT_REPO" rev-parse --is-bare-repository)"

if [[ "$ROOT_REPO" != "$EXPECTED_ROOT" ]]; then
  echo "land: expected root repo at $EXPECTED_ROOT, found $ROOT_REPO" >&2
  exit 1
fi

if [[ "$REPO_ROOT" == "$ROOT_REPO" ]]; then
  echo "land: run this from an implementation worktree, not the root repo" >&2
  exit 1
fi

if [[ "$BRANCH" == "HEAD" ]]; then
  echo "land: detached HEAD is not supported" >&2
  exit 1
fi

if [[ "$BRANCH" == "master" ]]; then
  echo "land: current worktree is already on master; use an implementation branch" >&2
  exit 1
fi

require_clean_tree "$REPO_ROOT" "current worktree"
require_clean_tree "$ROOT_REPO" "root repo"

if [[ "$ROOT_IS_BARE" != "true" ]] && [[ "$(git -C "$ROOT_REPO" rev-parse --abbrev-ref HEAD)" != "master" ]]; then
  git -C "$ROOT_REPO" switch master >/dev/null
fi

master_commit="$(git -C "$ROOT_REPO" rev-parse master)"

echo "land: rebasing $BRANCH onto root master ($master_commit)"
git rebase "$master_commit"

echo "land: running just pre-merge"
just pre-merge

require_clean_tree "$REPO_ROOT" "current worktree"
require_clean_tree "$ROOT_REPO" "root repo"

if [[ "$ROOT_IS_BARE" != "true" ]] && [[ "$(git -C "$ROOT_REPO" rev-parse --abbrev-ref HEAD)" != "master" ]]; then
  git -C "$ROOT_REPO" switch master >/dev/null
fi

echo "land: fast-forwarding root master to $BRANCH"
if [[ "$ROOT_IS_BARE" == "true" ]]; then
  git -C "$ROOT_REPO" merge-base --is-ancestor master "$BRANCH"
  git -C "$ROOT_REPO" update-ref refs/heads/master \
    "$(git -C "$ROOT_REPO" rev-parse "$BRANCH")" \
    "$(git -C "$ROOT_REPO" rev-parse master)"
else
  git -C "$ROOT_REPO" merge --ff-only "$BRANCH"
fi

sync_dispatch_plans_from_root

echo "land: merged $BRANCH into root master"
