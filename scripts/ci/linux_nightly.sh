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
summary_path="${summary_dir}/${run_id}-nightly.json"
current_system="$(shadow_ci_current_system)"
target_system="$(shadow_ci_system)"
executor_kind="${SHADOW_CI_EXECUTOR_KIND:-linux-local}"
executor_host="${SHADOW_CI_EXECUTOR_HOST:-$(hostname -f 2>/dev/null || hostname)}"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_unix="$(date +%s)"
declare -A step_secs=()
declare -A step_status=()

mkdir -p "$summary_dir"

if [[ "$current_system" != "$target_system" ]]; then
  echo "nightly: expected CI system ${target_system}, found ${current_system}" >&2
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
  local finished_at finished_unix
  local step_dump
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  finished_unix="$(date +%s)"
  step_dump="$(
    for label in "${!step_secs[@]}"; do
      printf '%s=%s=%s\n' "$label" "${step_status[$label]:-1}" "${step_secs[$label]}"
    done | sort
  )"
  python3 - "$summary_path" "$run_id" "$status" "$started_at" "$finished_at" "$started_unix" "$finished_unix" "$current_system" "$target_system" "$executor_kind" "$executor_host" "$step_dump" <<'PY'
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
    step_dump,
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
    "gate": "nightly",
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
    "steps": steps,
}

path = pathlib.Path(summary_path)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

main() {
  local tmp_hello_init tmp_orange_init

  run_step preMerge "$SCRIPT_DIR/linux_pre_merge.sh"
  run_step uiCheck scripts/ui_check.sh
  run_step pixelBootCheck nix build --accept-flake-config --no-link -L ".#legacyPackages.${target_system}.ci.pixelBootCheck"
  run_step pixelBootOrangeGpuSmoke scripts/ci/pixel_boot_orange_gpu_smoke.sh
  run_step pixelBootRustBridgeSmoke scripts/ci/pixel_boot_rust_bridge_smoke.sh
  run_step pixelBootRustBridgeRunSmoke scripts/ci/pixel_boot_rust_bridge_run_smoke.sh

  tmp_hello_init="$(mktemp "${TMPDIR:-/tmp}/shadow-hello-init.XXXXXX")"
  rm -f "$tmp_hello_init"
  run_step helloInit scripts/pixel/pixel_build_hello_init.sh --output "$tmp_hello_init"
  rm -f "$tmp_hello_init" "$tmp_hello_init.build-id"

  tmp_orange_init="$(mktemp "${TMPDIR:-/tmp}/shadow-orange-init.XXXXXX")"
  rm -f "$tmp_orange_init"
  run_step orangeInit scripts/pixel/pixel_build_orange_init.sh --output "$tmp_orange_init"
  rm -f "$tmp_orange_init" "$tmp_orange_init.build-id"
}

if main; then
  status=0
else
  status=$?
fi

write_summary "$status"
exit "$status"
