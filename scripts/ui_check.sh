#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

nix develop .#ui -c cargo fmt --manifest-path ui/Cargo.toml --all --check
nix develop .#ui -c cargo test --manifest-path ui/Cargo.toml -p shadow-ui-core
nix develop .#ui -c cargo test --manifest-path ui/Cargo.toml -p shadow-counter
nix develop .#ui -c cargo check --manifest-path ui/Cargo.toml -p shadow-counter
nix develop .#ui -c cargo test --manifest-path ui/Cargo.toml -p shadow-blitz-demo runtime_document
nix develop .#ui -c cargo check --manifest-path ui/Cargo.toml -p shadow-ui-desktop

if [[ "$(uname -s)" == "Linux" ]]; then
  nix develop .#ui -c cargo check --manifest-path ui/Cargo.toml -p shadow-compositor
  nix develop .#ui -c cargo check --manifest-path ui/Cargo.toml -p shadow-compositor-guest
  nix develop .#ui -c cargo check --manifest-path ui/Cargo.toml -p shadow-counter-guest
fi
