#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shadow_common.sh
source "$SCRIPT_DIR/lib/shadow_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

just pre-merge
just ui-check
host_system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build --accept-flake-config --no-link -L ".#legacyPackages.${host_system}.ci.pixelBootCheck"
tmp_hello_init="$(mktemp "${TMPDIR:-/tmp}/shadow-hello-init.XXXXXX")"
rm -f "$tmp_hello_init"
scripts/pixel/pixel_build_hello_init.sh --output "$tmp_hello_init"
rm -f "$tmp_hello_init" "$tmp_hello_init.build-id"
tmp_orange_init="$(mktemp "${TMPDIR:-/tmp}/shadow-orange-init.XXXXXX")"
rm -f "$tmp_orange_init"
scripts/pixel/pixel_build_orange_init.sh --output "$tmp_orange_init"
rm -f "$tmp_orange_init" "$tmp_orange_init.build-id"
