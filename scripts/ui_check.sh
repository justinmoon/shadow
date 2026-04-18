#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

host_system="$(nix eval --impure --raw --expr builtins.currentSystem)"

nix build --accept-flake-config --no-link -L ".#checks.${host_system}.uiCheck"
