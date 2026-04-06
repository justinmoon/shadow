#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXIT_DELAY_MS="${SHADOW_BLITZ_RUNTIME_EXIT_DELAY_MS:-900}"
RENDERER="${SHADOW_BLITZ_RENDERER:-cpu}"

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

session_json="$(scripts/runtime_prepare_host_session.sh)"
printf '%s\n' "$session_json"

bundle_path="$(
  printf '%s\n' "$session_json" | python3 -c 'import json, sys; print(json.load(sys.stdin)["bundlePath"])'
)"
runtime_host_binary_path="$(
  printf '%s\n' "$session_json" | python3 -c 'import json, sys; print(json.load(sys.stdin)["runtimeHostBinaryPath"])'
)"

output="$(
  nix develop .#ui -c env \
    SHADOW_BLITZ_DEMO_MODE=runtime \
    SHADOW_BLITZ_RUNTIME_EXIT_DELAY_MS="$EXIT_DELAY_MS" \
    SHADOW_BLITZ_RUNTIME_AUTO_CLICK_TARGET=counter \
    SHADOW_RUNTIME_APP_BUNDLE_PATH="$bundle_path" \
    SHADOW_RUNTIME_HOST_BINARY_PATH="$runtime_host_binary_path" \
    cargo run --quiet --manifest-path ui/Cargo.toml -p shadow-blitz-demo "${cargo_renderer_args[@]}" 2>&1
)"
printf '%s\n' "$output"

printf '%s\n' "$output" | grep -F "runtime-session-ready" >/dev/null
printf '%s\n' "$output" | grep -F "runtime-document-ready" >/dev/null
printf '%s\n' "$output" | grep -F "runtime-event-dispatched source=auto type=click target=counter" >/dev/null
printf '%s\n' "$output" | grep -F "exit-requested" >/dev/null

printf 'Runtime app host smoke succeeded\n'
