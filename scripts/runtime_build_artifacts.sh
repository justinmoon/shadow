#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
runtime_flake_ref=""
runtime_host_package_attr=""
passthrough=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --flake-ref)
      runtime_flake_ref="${2:-}"
      shift 2
      ;;
    --runtime-host-package)
      runtime_host_package_attr="${2:-}"
      shift 2
      ;;
    *)
      passthrough+=("$1")
      shift
      ;;
  esac
done

REPO_FLAKE_REF="${runtime_flake_ref:-${REPO_ROOT}}"

if [[ -n "$runtime_host_package_attr" ]]; then
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

cd "$REPO_ROOT"
exec nix develop --accept-flake-config "${REPO_FLAKE_REF}#runtime" -c \
  deno run --quiet \
    --allow-env --allow-read --allow-write --allow-run \
    scripts/runtime_build_artifacts.ts \
    "${passthrough[@]}"
