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

stream_tracked_repo_snapshot() {
  (
    cd "$(repo_root)"
    python3 - <<'PY' | tar --null --files-from=- --create --file=-
import os
import subprocess
import sys

for path in subprocess.check_output(["git", "ls-files", "-z"]).split(b"\0"):
    if not path:
        continue
    if os.path.lexists(path):
        sys.stdout.buffer.write(path + b"\0")
PY
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

pull_remote_file() {
  local remote_path="$1"
  local local_path="$2"
  mkdir -p "$(dirname "$local_path")"
  if is_local_host; then
    cp "$remote_path" "$local_path" >/dev/null 2>&1
    return 0
  fi
  scp_retry "${REMOTE_HOST}:$remote_path" "$local_path" >/dev/null 2>&1
}

pull_remote_required_artifact() {
  local remote_path="$1"
  local local_path="$2"
  local label="$3"
  if ! remote_shell "[ -f $(printf '%q' "$remote_path") ]"; then
    echo "ci: warning: missing ${label} on ${REMOTE_HOST}" >&2
    return 1
  fi
  if ! pull_remote_file "$remote_path" "$local_path"; then
    echo "ci: warning: failed to pull ${label} from ${REMOTE_HOST}" >&2
    return 1
  fi
}

pull_remote_optional_artifact() {
  local remote_path="$1"
  local local_path="$2"
  if ! remote_shell "[ -f $(printf '%q' "$remote_path") ]"; then
    return 0
  fi
  pull_remote_file "$remote_path" "$local_path"
}

pull_remote_artifacts() {
  local remote_repo_dir="$1"
  local local_repo_dir required_failed=0
  local remote_path local_path file_name
  local_repo_dir="$(repo_root)"

  pull_remote_required_artifact \
    "$remote_repo_dir/build/ci/runs/${run_id}-pre-merge.json" \
    "$local_repo_dir/build/ci/runs/${run_id}-pre-merge.json" \
    "build/ci/runs/${run_id}-pre-merge.json" || required_failed=1

  if [[ "$remote_gate_script" == "scripts/ci/linux_nightly.sh" ]]; then
    pull_remote_required_artifact \
      "$remote_repo_dir/build/ci/runs/${run_id}-nightly.json" \
      "$local_repo_dir/build/ci/runs/${run_id}-nightly.json" \
      "build/ci/runs/${run_id}-nightly.json" || required_failed=1
  fi

  for file_name in \
    ui-vm-smoke.log \
    ui-vm-smoke-summary.json \
    ui-vm-smoke.png \
    ui-vm-home-surface.ppm; do
    remote_path="$remote_repo_dir/build/ui-vm/$file_name"
    local_path="$local_repo_dir/build/ui-vm/$file_name"
    pull_remote_optional_artifact "$remote_path" "$local_path" || true
  done

  return "$required_failed"
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

artifact_status=0
if ! pull_remote_artifacts "$remote_repo_dir"; then
  artifact_status=$?
fi

if (( status != 0 )); then
  echo "ci: remote gate failed on ${REMOTE_HOST}" >&2
elif (( artifact_status != 0 )); then
  echo "ci: failed to pull one or more CI artifacts from ${REMOTE_HOST}" >&2
  status=$artifact_status
fi

exit "$status"
