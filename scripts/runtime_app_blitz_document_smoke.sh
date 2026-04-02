#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

nix develop .#ui -c cargo test --manifest-path ui/Cargo.toml -p shadow-blitz-demo runtime_document

printf 'Runtime app Blitz document smoke succeeded\n'
