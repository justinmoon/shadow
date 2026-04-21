#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-pixel-nix-progress.XXXXXX")"
COMBINED_LOG="$TMP_DIR/combined.log"
FAKE_OUT="/tmp/shadow-pixel-nix-progress-out"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

(
  export PIXEL_NIX_BUILD_RETRIES=1
  export PIXEL_NIX_BUILD_HEARTBEAT_SECS=0
  pixel_retry_nix_build_print_out_paths bash -lc '
    echo progress-1 >&2
    sleep 2
    echo progress-2 >&2
    sleep 2
    echo '"$FAKE_OUT"'
  '
) >"$COMBINED_LOG" 2>&1 &
helper_pid=$!

deadline=$((SECONDS + 3))
progress_seen_while_running=false
while kill -0 "$helper_pid" >/dev/null 2>&1; do
  if grep -Fq 'progress-1' "$COMBINED_LOG"; then
    progress_seen_while_running=true
    break
  fi
  if (( SECONDS >= deadline )); then
    break
  fi
  sleep 0.1
done

if [[ "$progress_seen_while_running" != true ]]; then
  wait "$helper_pid" || true
  cat "$COMBINED_LOG" >&2
  echo "pixel_nix_build_progress_smoke: expected stderr progress before command completion" >&2
  exit 1
fi

wait "$helper_pid"

grep -Fq 'progress-2' "$COMBINED_LOG" || {
  cat "$COMBINED_LOG" >&2
  echo "pixel_nix_build_progress_smoke: missing second progress line" >&2
  exit 1
}

grep -Fq "$FAKE_OUT" "$COMBINED_LOG" || {
  cat "$COMBINED_LOG" >&2
  echo "pixel_nix_build_progress_smoke: missing printed output path" >&2
  exit 1
}

echo "pixel_nix_build_progress_smoke: ok"
