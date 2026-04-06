#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RENDERER="${SHADOW_BLITZ_RENDERER:-gpu}"

declare -a cargo_renderer_args=()
case "$RENDERER" in
  cpu) ;;
  gpu)
    cargo_renderer_args=(--no-default-features --features gpu)
    ;;
  hybrid)
    cargo_renderer_args=(--no-default-features --features hybrid)
    ;;
  *)
    printf 'unsupported SHADOW_BLITZ_RENDERER: %s\n' "$RENDERER" >&2
    exit 1
    ;;
esac

cd "$REPO_ROOT"

exec cargo run --quiet --manifest-path ui/Cargo.toml -p shadow-blitz-demo "${cargo_renderer_args[@]}"
