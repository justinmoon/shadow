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

run_rustfmt_checks() {
  local manifest_path
  while IFS= read -r manifest_path; do
    cargo fmt --manifest-path "$manifest_path" --all --check
  done <<'EOF'
ui/Cargo.toml
rust/Cargo.toml
rust/init-wrapper/Cargo.toml
EOF

  cargo fmt --manifest-path rust/drm-rect/Cargo.toml -p drm-rect --check
  cargo fmt --manifest-path rust/shadow-camera-provider-host/Cargo.toml -p shadow-camera-provider-host --check
  cargo fmt --manifest-path rust/shadow-linux-audio-spike/Cargo.toml -p shadow-linux-audio-spike --check
  cargo fmt --manifest-path rust/shadow-session/Cargo.toml -p shadow-session --check
}

runtime_typescript_paths() {
  find runtime scripts/runtime -type f \
    \( -name '*.ts' -o -name '*.tsx' -o -name '*.mts' -o -name '*.cts' \) \
    | sort
}

run_runtime_deno_fmt_check() {
  local runtime_ts_files=()
  while IFS= read -r source_path; do
    runtime_ts_files+=("$source_path")
  done < <(runtime_typescript_paths)
  if ((${#runtime_ts_files[@]})); then
    deno fmt --check "${runtime_ts_files[@]}"
  fi
}

run_runtime_deno_typecheck() {
  deno check --config deno.json \
    scripts/runtime/runtime_build_artifacts.ts \
    scripts/runtime/runtime_compile_solid.ts \
    scripts/runtime/runtime_prepare_app_bundle.ts \
    scripts/runtime/runtime_prepare_app_bundle_test.ts
}

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
start_parallel_check rustfmt run_rustfmt_checks
start_parallel_check runtime-deno-fmt run_runtime_deno_fmt_check
start_parallel_check runtime-deno-check run_runtime_deno_typecheck
start_parallel_check app-metadata scripts/ci/app_metadata_manifest_smoke.sh
start_parallel_check operator-cli scripts/ci/operator_cli_smoke.sh
start_parallel_check pixel-nix-progress scripts/ci/pixel_nix_build_progress_smoke.sh
start_parallel_check pixel-guest-startup scripts/ci/pixel_guest_startup_config_smoke.sh
start_parallel_check pixel-audio-config scripts/ci/pixel_audio_backend_config_smoke.sh
start_parallel_check vm-smoke-logical-inputs scripts/ci/vm_smoke_logical_inputs_smoke.sh
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
