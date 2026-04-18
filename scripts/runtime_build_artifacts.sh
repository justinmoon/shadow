#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
runtime_flake_ref=""
runtime_repo_root="$REPO_ROOT"
runtime_host_package_attr=""
runtime_host_binary_path=""
passthrough=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flake-ref)
      runtime_flake_ref="${2:-}"
      shift 2
      ;;
    --repo-root)
      runtime_repo_root="${2:-}"
      shift 2
      ;;
    --runtime-host-package)
      runtime_host_package_attr="${2:-}"
      shift 2
      ;;
    --runtime-host-binary-path)
      runtime_host_binary_path="${2:-}"
      shift 2
      ;;
    *)
      passthrough+=("$1")
      shift
      ;;
  esac
done

runtime_repo_root="$(cd "$runtime_repo_root" && pwd)"
REPO_FLAKE_REF="${runtime_flake_ref:-${runtime_repo_root}}"

if [[ -n "$runtime_host_binary_path" ]]; then
  if [[ -n "$runtime_host_package_attr" ]]; then
    passthrough+=(--runtime-host-package "$runtime_host_package_attr")
  fi
  passthrough+=(
    --runtime-host-binary-path "$runtime_host_binary_path"
  )
elif [[ -n "$runtime_host_package_attr" ]]; then
  runtime_host_prefix="$(
    nix build --accept-flake-config "${REPO_FLAKE_REF}#${runtime_host_package_attr}" \
      --no-link \
      --print-out-paths
  )"
  passthrough+=(
    --runtime-host-package "$runtime_host_package_attr"
    --runtime-host-binary-path "$runtime_host_prefix/bin/shadow-runtime-host"
  )
fi

cd "$runtime_repo_root"
exec nix develop --accept-flake-config "${REPO_FLAKE_REF}#runtime" -c \
  deno run --quiet \
    --allow-env --allow-read --allow-write --allow-run \
    scripts/runtime/runtime_build_artifacts.ts \
    "${passthrough[@]}"
