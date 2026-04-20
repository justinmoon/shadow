#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shadow_common.sh
source "$SCRIPT_DIR/lib/shadow_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

parallel_check_labels=()
parallel_check_logs=()
parallel_check_pids=()

cleanup() {
  local pid log_path
  for pid in "${parallel_check_pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  for log_path in "${parallel_check_logs[@]:-}"; do
    rm -f "$log_path"
  done
}
trap cleanup EXIT

print_success_log() {
  local log_path="$1"
  sed -E '/^error \(ignored\): SQLite database .* is busy$/d' "$log_path"
}

start_parallel_check() {
  local label="$1"
  shift
  local log_path
  log_path="$(mktemp "${TMPDIR:-/tmp}/shadow-pre-commit.${label}.XXXXXX")"
  parallel_check_labels+=("$label")
  parallel_check_logs+=("$log_path")
  (
    "$@"
  ) >"$log_path" 2>&1 &
  parallel_check_pids+=("$!")
}

wait_parallel_checks() {
  local status=0
  local index pid log_path label
  for index in "${!parallel_check_pids[@]}"; do
    pid="${parallel_check_pids[$index]}"
    log_path="${parallel_check_logs[$index]}"
    label="${parallel_check_labels[$index]}"
    if wait "$pid"; then
      print_success_log "$log_path"
    else
      printf 'parallel check failed: %s\n' "$label" >&2
      cat "$log_path" >&2
      status=1
    fi
    rm -f "$log_path"
  done
  parallel_check_labels=()
  parallel_check_logs=()
  parallel_check_pids=()
  return "$status"
}

scripts/ci/check_script_inventory.py
scripts/runtime/generate_app_metadata.py --check
start_parallel_check app-metadata scripts/ci/app_metadata_manifest_smoke.sh
start_parallel_check operator-cli scripts/ci/operator_cli_smoke.sh
scripts/ci/cpio_edit_smoke.sh
shell_scripts=()
while IFS= read -r -d '' script_path; do
  if [[ "$script_path" == *.sh ]]; then
    shell_scripts+=("$script_path")
    continue
  fi
  first_line=""
  IFS= read -r first_line <"$script_path" || true
  case "$first_line" in
    "#!"*bash*|"#!"*sh*) shell_scripts+=("$script_path") ;;
  esac
done < <(find scripts -type f ! -path '*/__pycache__/*' -print0 | sort -z)
if ((${#shell_scripts[@]})); then
  bash -n "${shell_scripts[@]}"
fi
scripts/ci/timeline_sync_defaults_smoke.sh
scripts/lib/agent_tools.py check-docs
scripts/lib/agent_tools.py check-justfile
wait_parallel_checks
