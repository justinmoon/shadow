#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/shadow_common.sh
source "$SCRIPT_DIR/../lib/shadow_common.sh"
# shellcheck source=../lib/ci_common.sh
source "$SCRIPT_DIR/../lib/ci_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

run_id="$(shadow_ci_run_id)"
summary_dir="$(shadow_ci_summary_dir)"
summary_path="${summary_dir}/${run_id}-pre-merge.json"
current_system="$(shadow_ci_current_system)"
target_system="$(shadow_ci_system)"
executor_kind="${SHADOW_CI_EXECUTOR_KIND:-linux-local}"
executor_host="${SHADOW_CI_EXECUTOR_HOST:-$(hostname -f 2>/dev/null || hostname)}"
boot_demo_mode="${SHADOW_BOOT_DEMO_CHECK_MODE:-auto}"
boot_demo_changed_files="${SHADOW_BOOT_DEMO_CHANGED_FILES:-}"
skip_pre_commit="${SHADOW_SKIP_PRE_COMMIT:-0}"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_unix="$(date +%s)"
declare -A step_secs=()
declare -A step_status=()

mkdir -p "$summary_dir"

if [[ "$current_system" != "$target_system" ]]; then
  echo "pre-merge: expected CI system ${target_system}, found ${current_system}" >&2
  exit 1
fi

run_step() {
  local label="$1"
  shift
  local started finished status
  started="$(date +%s)"
  set +e
  "$@"
  status=$?
  set -e
  finished="$(date +%s)"
  step_secs["$label"]=$((finished - started))
  step_status["$label"]=$status
  return "$status"
}

write_summary() {
  local status="$1"
  local finished_at finished_unix vm_smoke_summary_path
  local step_dump
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  finished_unix="$(date +%s)"
  vm_smoke_summary_path=""
  if [[ -f build/ui-vm/ui-vm-smoke-summary.json ]]; then
    vm_smoke_summary_path="build/ui-vm/ui-vm-smoke-summary.json"
  fi
  step_dump="$(
    for label in "${!step_secs[@]}"; do
      printf '%s=%s=%s\n' "$label" "${step_status[$label]:-1}" "${step_secs[$label]}"
    done | sort
  )"
  python3 - "$summary_path" "$run_id" "$status" "$started_at" "$finished_at" "$started_unix" "$finished_unix" "$current_system" "$target_system" "$executor_kind" "$executor_host" "$boot_demo_mode" "$skip_pre_commit" "$boot_demo_changed_files" "$step_dump" "$vm_smoke_summary_path" <<'PY'
import json
import pathlib
import sys

(
    summary_path,
    run_id,
    status,
    started_at,
    finished_at,
    started_unix,
    finished_unix,
    current_system,
    target_system,
    executor_kind,
    executor_host,
    boot_demo_mode,
    skip_pre_commit,
    boot_demo_changed_files,
    step_dump,
    vm_smoke_summary_path,
) = sys.argv[1:]

steps = {}
for line in step_dump.splitlines():
    parts = line.split("=", 2)
    if len(parts) != 3:
        continue
    key, status, secs = parts
    steps[key] = {
        "status": int(status),
        "ok": int(status) == 0,
        "secs": int(secs),
    }

payload = {
    "schemaVersion": 1,
    "gate": "pre-merge",
    "runId": run_id,
    "status": int(status),
    "ok": int(status) == 0,
    "startedAt": started_at,
    "finishedAt": finished_at,
    "totalSecs": int(finished_unix) - int(started_unix),
    "currentSystem": current_system,
    "targetSystem": target_system,
    "executorKind": executor_kind,
    "executorHost": executor_host,
    "skipPreCommit": skip_pre_commit == "1",
    "bootDemoMode": boot_demo_mode,
    "bootDemoChangedFiles": [line for line in boot_demo_changed_files.splitlines() if line],
    "steps": steps,
    "vmSmokeSummaryPath": vm_smoke_summary_path or None,
}

path = pathlib.Path(summary_path)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

main() {
  if [[ "$skip_pre_commit" != "1" ]]; then
    run_step preCommit scripts/pre_commit.sh
  fi
  run_step preMergeCheck nix build --accept-flake-config --no-link -L ".#checks.${target_system}.preMergeCheck"

  case "$boot_demo_mode" in
    auto)
      run_step bootDemo scripts/ci/pixel_boot_demo_check.sh --if-changed
      ;;
    run)
      if [[ -n "$boot_demo_changed_files" ]]; then
        printf 'pre-merge: boot demo check selected for changed paths:\n%s\n' "$boot_demo_changed_files"
      else
        echo "pre-merge: boot demo check forced by caller"
      fi
      run_step bootDemo scripts/ci/pixel_boot_demo_check.sh
      ;;
    skip)
      echo "pre-merge: skip boot demo check; branch does not touch demo-owned boot paths"
      ;;
    *)
      echo "pre-merge: unsupported SHADOW_BOOT_DEMO_CHECK_MODE=${boot_demo_mode}" >&2
      return 2
      ;;
  esac

  run_step vmSmoke "$SCRIPT_DIR/required_vm_smoke.sh"
}

if main; then
  status=0
else
  status=$?
fi

write_summary "$status"
exit "$status"
