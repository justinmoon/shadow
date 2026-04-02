#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXIT_DELAY_MS="${SHADOW_BLITZ_RUNTIME_EXIT_DELAY_MS:-900}"

cd "$REPO_ROOT"

output="$(
  nix develop .#ui -c env \
    SHADOW_BLITZ_DEMO_MODE=runtime \
    SHADOW_BLITZ_RUNTIME_EXIT_DELAY_MS="$EXIT_DELAY_MS" \
    cargo run --quiet --manifest-path ui/Cargo.toml -p shadow-blitz-demo 2>&1
)"
printf '%s\n' "$output"

printf '%s\n' "$output" | grep -F "[shadow-runtime-demo] runtime-document-ready" >/dev/null
printf '%s\n' "$output" | grep -F "[shadow-runtime-demo] exit-requested" >/dev/null

printf 'Runtime app host smoke succeeded\n'
