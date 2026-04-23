#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/shadow_common.sh
source "$SCRIPT_DIR/../lib/shadow_common.sh"
# shellcheck source=../lib/ci_common.sh
source "$SCRIPT_DIR/../lib/ci_common.sh"

usage() {
  cat <<'EOF'
Usage: remote_ci.sh <pre-merge|nightly>

Sync the current Shadow worktree to the configured Linux CI executor and run
the canonical Linux gate there.
EOF
}

build_rsync_ssh_cmd() {
  local ssh_cmd="ssh"
  local opt
  for opt in "${SSH_OPTS[@]}"; do
    ssh_cmd+=" $(printf '%q' "$opt")"
  done
  printf '%s\n' "$ssh_cmd"
}

stream_tracked_repo_snapshot() {
  (
    cd "$(repo_root)"
    git ls-files -z | tar --null --files-from=- --create --file=-
  )
}

sync_remote_repo() {
  local remote_repo_dir="$1"
  remote_shell "mkdir -p $(printf '%q' "$remote_repo_dir") && find $(printf '%q' "$remote_repo_dir") -mindepth 1 -maxdepth 1 ! -name .shadow-ci -exec rm -rf {} +"
  if is_local_host; then
    stream_tracked_repo_snapshot | tar -xf - -C "$remote_repo_dir"
    return 0
  fi
  stream_tracked_repo_snapshot \
    | ssh_retry "$REMOTE_HOST" "mkdir -p $(printf '%q' "$remote_repo_dir") && tar -xf - -C $(printf '%q' "$remote_repo_dir")"
}

pull_remote_artifacts() {
  local remote_repo_dir="$1"
  local ssh_cmd
  ssh_cmd="$(build_rsync_ssh_cmd)"
  mkdir -p "$(repo_root)/build"
  if remote_shell "[ -d $(printf '%q' "$remote_repo_dir")/build/ci ]"; then
    if ! rsync -az -e "$ssh_cmd" \
      "${REMOTE_HOST}:$remote_repo_dir/build/ci/" \
      "$(repo_root)/build/ci/" >/dev/null 2>&1; then
      echo "ci: warning: failed to pull build/ci artifacts from ${REMOTE_HOST}" >&2
    fi
  fi
  if remote_shell "[ -d $(printf '%q' "$remote_repo_dir")/build/ui-vm ]"; then
    if ! rsync -az -e "$ssh_cmd" \
      "${REMOTE_HOST}:$remote_repo_dir/build/ui-vm/" \
      "$(repo_root)/build/ui-vm/" >/dev/null 2>&1; then
      echo "ci: warning: failed to pull build/ui-vm artifacts from ${REMOTE_HOST}" >&2
    fi
  fi
}

case "${1:-}" in
  pre-merge)
    remote_gate_script="scripts/ci/linux_pre_merge.sh"
    ;;
  nightly)
    remote_gate_script="scripts/ci/linux_nightly.sh"
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

REMOTE_HOST="$(shadow_ci_remote_host)"
run_id="$(shadow_ci_run_id)"
remote_repo_dir="$(shadow_ci_remote_repo_dir)"
boot_demo_mode="${SHADOW_BOOT_DEMO_CHECK_MODE:-skip}"
boot_demo_changed_files="${SHADOW_BOOT_DEMO_CHANGED_FILES:-}"
root_master_vm_smoke_inputs_id="${SHADOW_VM_SMOKE_ROOT_MASTER_INPUTS_ID:-$(shadow_ci_root_master_vm_smoke_inputs_id || true)}"
skip_pre_commit="${SHADOW_SKIP_PRE_COMMIT:-0}"

echo "ci: syncing worktree to ${REMOTE_HOST}:${remote_repo_dir}"
sync_remote_repo "$remote_repo_dir"

set +e
remote_shell "$(cat <<EOF
set -euo pipefail
cd $(printf '%q' "$remote_repo_dir")
export SHADOW_CI_RUN_ID=$(printf '%q' "$run_id")
export SHADOW_CI_EXECUTOR_KIND=remote-linux
export SHADOW_CI_EXECUTOR_HOST=$(printf '%q' "$REMOTE_HOST")
export SHADOW_BOOT_DEMO_CHECK_MODE=$(printf '%q' "$boot_demo_mode")
export SHADOW_BOOT_DEMO_CHANGED_FILES=$(printf '%q' "$boot_demo_changed_files")
export SHADOW_VM_SMOKE_ROOT_MASTER_INPUTS_ID=$(printf '%q' "$root_master_vm_smoke_inputs_id")
export SHADOW_SKIP_PRE_COMMIT=$(printf '%q' "$skip_pre_commit")
exec $(printf '%q' "$remote_gate_script")
EOF
)"
status=$?
set -e

pull_remote_artifacts "$remote_repo_dir"

if (( status != 0 )); then
  echo "ci: remote gate failed on ${REMOTE_HOST}" >&2
fi

exit "$status"
