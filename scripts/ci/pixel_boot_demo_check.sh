#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/shadow_common.sh
source "$SCRIPT_DIR/../lib/shadow_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

boot_demo_regex='^(scripts/ci/pixel_boot_|scripts/pixel/pixel_boot_|scripts/pixel/pixel_build_hello_init\.sh|scripts/pixel/pixel_build_orange_init\.sh|scripts/pixel/pixel_gpu_smoke\.sh|scripts/pixel/pixel_prepare_gpu_smoke_bundle\.sh|scripts/pixel/pixel_hello_init\.c|rust/drm-rect/|ui/crates/shadow-gpu-smoke/)'

usage() {
  cat <<'EOF'
Usage: pixel_boot_demo_check.sh [--if-changed]

Runs the dedicated host-side boot demo gate. With --if-changed, the gate runs
only when the current branch differs from root master in demo-owned paths.
EOF
}

root_repo() {
  local common_git_dir
  common_git_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
  cd "$common_git_dir/.." && pwd
}

changed_boot_demo_files() {
  local root master_commit
  root="$(root_repo)"
  master_commit="$(git -C "$root" rev-parse master)"
  git diff --name-only "$master_commit"...HEAD | grep -E "$boot_demo_regex" || true
}

run_boot_demo_gate() {
  scripts/ci/pixel_boot_hello_init_smoke.sh
  scripts/ci/pixel_boot_orange_init_smoke.sh
  scripts/ci/pixel_boot_orange_gpu_smoke.sh

  # Keep the real cross-builds here so the hermetic smokes cannot hide a broken
  # flake/package seam, but keep them out of the repo-wide fast gate.
  tmp_hello_init="$(mktemp "${TMPDIR:-/tmp}/shadow-hello-init.XXXXXX")"
  rm -f "$tmp_hello_init"
  scripts/pixel/pixel_build_hello_init.sh --output "$tmp_hello_init"
  rm -f "$tmp_hello_init" "$tmp_hello_init.build-id"

  tmp_orange_init="$(mktemp "${TMPDIR:-/tmp}/shadow-orange-init.XXXXXX")"
  rm -f "$tmp_orange_init"
  scripts/pixel/pixel_build_orange_init.sh --output "$tmp_orange_init"
  rm -f "$tmp_orange_init" "$tmp_orange_init.build-id"

  tmp_orange_gpu="$(mktemp "${TMPDIR:-/tmp}/shadow-orange-gpu.XXXXXX.img")"
  rm -f "$tmp_orange_gpu"
  scripts/pixel/pixel_boot_build_orange_gpu.sh --output "$tmp_orange_gpu" >/dev/null
  rm -f "$tmp_orange_gpu" "$tmp_orange_gpu.hello-init.json"
  scripts/ci/pixel_boot_tooling_smoke.sh
  scripts/ci/pixel_boot_collect_logs_smoke.sh
  scripts/ci/pixel_boot_safety_smoke.sh
  nix develop .#runtime -c cargo check --manifest-path ui/Cargo.toml -p shadow-gpu-smoke
}

if_changed=false
case "${1-}" in
  "")
    ;;
  --if-changed)
    if_changed=true
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

if [[ "$if_changed" == true && -z "${SHADOW_FORCE_BOOT_DEMO_CHECK:-}" ]]; then
  changed_files="$(changed_boot_demo_files)"
  if [[ -z "$changed_files" ]]; then
    echo "pixel_boot_demo_check: skipped; branch does not touch demo-owned boot paths"
    exit 0
  fi
  printf 'pixel_boot_demo_check: running for changed paths:\n%s\n' "$changed_files"
fi

run_boot_demo_gate
