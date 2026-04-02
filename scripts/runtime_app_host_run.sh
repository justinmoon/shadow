#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

nix develop .#ui -c env \
  SHADOW_BLITZ_DEMO_MODE=runtime \
  cargo run --quiet --manifest-path ui/Cargo.toml -p shadow-blitz-demo
