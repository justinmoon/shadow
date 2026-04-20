#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shadow_common.sh
source "$SCRIPT_DIR/lib/shadow_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

just pre-commit
nix flake check --no-build
nix develop .#runtime -c cargo check --manifest-path rust/init-wrapper/Cargo.toml
nix develop .#runtime -c cargo test --manifest-path rust/Cargo.toml -p shadow-sdk --features nostr
nix develop .#runtime -c cargo test --manifest-path rust/Cargo.toml -p shadow-system
nix develop .#runtime -c deno test --allow-read --allow-write --allow-run --allow-env scripts/runtime/runtime_prepare_app_bundle_test.ts
scripts/ci/pixel_boot_hello_init_smoke.sh
scripts/ci/pixel_boot_orange_init_smoke.sh
scripts/ci/pixel_boot_tooling_smoke.sh
scripts/ci/pixel_boot_collect_logs_smoke.sh
scripts/ci/pixel_boot_safety_smoke.sh
"$SCRIPT_DIR/ci/required_vm_smoke.sh"
