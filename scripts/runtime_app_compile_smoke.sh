#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INPUT_PATH="runtime/app-compile-smoke/app.tsx"
CACHE_DIR="build/runtime/app-compile-smoke"

cd "$REPO_ROOT"

first_run="$(
  deno run --quiet --allow-env --allow-read --allow-write \
    scripts/runtime_compile_solid.ts \
    --input "$INPUT_PATH" \
    --cache-dir "$CACHE_DIR"
)"
printf '%s\n' "$first_run"

second_run="$(
  deno run --quiet --allow-env --allow-read --allow-write \
    scripts/runtime_compile_solid.ts \
    --input "$INPUT_PATH" \
    --cache-dir "$CACHE_DIR" \
    --expect-cache-hit
)"
printf '%s\n' "$second_run"

printf 'Runtime app compile smoke succeeded: %s\n' "$CACHE_DIR"
