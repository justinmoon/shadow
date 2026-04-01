#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REMOTE_HOST="${SHADOW_UI_REMOTE_HOST:-${CUTTLEFISH_REMOTE_HOST:-hetzner}}"
REMOTE_DIR_CACHE="${SHADOW_UI_REMOTE_DIR:-}"
UI_SMOKE_TMPDIR=""
UI_SMOKE_TIMEOUT_SECS="${SHADOW_UI_SMOKE_TIMEOUT:-300}"
UI_SMOKE_NAMESPACE="${SHADOW_UI_SMOKE_NAMESPACE:-$(basename "$REPO_ROOT")-$$}"
UI_SMOKE_SSH_RETRIES="${SHADOW_UI_SMOKE_SSH_RETRIES:-3}"
UI_SMOKE_SSH_RETRY_SLEEP="${SHADOW_UI_SMOKE_SSH_RETRY_SLEEP:-2}"

repo_root() {
  printf '%s\n' "$REPO_ROOT"
}

flake_path() {
  printf '%s#ui\n' "$(repo_root)"
}

ensure_ui_shell() {
  if [[ "${SHADOW_UI_SHELL:-}" == "1" ]]; then
    return 0
  fi

  exec nix develop "$(flake_path)" -c "$0" "$@"
}

remote_home() {
  remote_ssh 'printf %s "$HOME"'
}

remote_ssh() {
  local attempt script status
  script="${1:?remote_ssh requires a script}"
  status=0
  for attempt in $(seq 1 "$UI_SMOKE_SSH_RETRIES"); do
    if ssh \
      -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=3 \
      "$REMOTE_HOST" \
      /bin/bash -lc "$(printf '%q' "$script")"; then
      return 0
    fi
    status=$?
    if (( attempt == UI_SMOKE_SSH_RETRIES )); then
      return "$status"
    fi
    sleep "$UI_SMOKE_SSH_RETRY_SLEEP"
  done
  return "$status"
}

remote_dir() {
  if [[ -n "${REMOTE_DIR_CACHE:-}" ]]; then
    printf '%s\n' "$REMOTE_DIR_CACHE"
    return
  fi

  REMOTE_DIR_CACHE="$(remote_home)/.cache/shadow-ui-smoke-${UI_SMOKE_NAMESPACE}"
  printf '%s\n' "$REMOTE_DIR_CACHE"
}

sync_remote_tree() {
  local dir
  dir="$(remote_dir)"

  tar \
    --exclude=.git \
    --exclude=artifacts \
    --exclude=build \
    --exclude=ui/target \
    --exclude=worktrees \
    -cf - \
    flake.nix \
    flake.lock \
    justfile \
    scripts \
    ui \
    | remote_ssh "mkdir -p $(printf '%q' "$dir") && rm -rf $(printf '%q' "$dir/scripts") $(printf '%q' "$dir/ui") $(printf '%q' "$dir/flake.nix") $(printf '%q' "$dir/flake.lock") $(printf '%q' "$dir/justfile") && tar -xf - -C $(printf '%q' "$dir")"
}

dump_logs() {
  local dir
  dir="$1"
  if [[ -f "$dir/compositor.log" ]]; then
    printf '\n== compositor.log ==\n'
    sed -n '1,320p' "$dir/compositor.log"
  fi
}

run_local_linux_smoke() {
  local tmpdir compositor_log compositor_pid start now

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/shadow-ui-smoke.XXXXXX")"
  UI_SMOKE_TMPDIR="$tmpdir"
  compositor_log="$tmpdir/compositor.log"
  compositor_pid=""

  cleanup() {
    if [[ -n "${compositor_pid:-}" ]]; then
      kill "$compositor_pid" 2>/dev/null || true
      wait "$compositor_pid" 2>/dev/null || true
    fi
    if [[ -n "${UI_SMOKE_TMPDIR:-}" ]]; then
      rm -rf "$UI_SMOKE_TMPDIR"
    fi
  }
  trap cleanup EXIT

  (
    cd "$REPO_ROOT"
    export SHADOW_COMPOSITOR_HEADLESS=1
    export SHADOW_COMPOSITOR_AUTO_LAUNCH=1
    export RUST_LOG="${RUST_LOG:-shadow_compositor=info,smithay=warn}"
    cargo run --manifest-path ui/Cargo.toml -p shadow-compositor
  ) >"$compositor_log" 2>&1 &
  compositor_pid=$!

  start="$(date +%s)"
  while true; do
    if grep -Fq '[shadow-compositor] mapped-window' "$compositor_log" \
      && grep -Fq '[shadow-counter] configured' "$compositor_log"; then
      printf 'UI smoke passed. Logs: %s\n' "$tmpdir"
      return 0
    fi

    if ! kill -0 "$compositor_pid" 2>/dev/null; then
      dump_logs "$tmpdir"
      echo "shadow-compositor exited before smoke markers appeared" >&2
      return 1
    fi

    now="$(date +%s)"
    if (( now - start > UI_SMOKE_TIMEOUT_SECS )); then
      dump_logs "$tmpdir"
      echo "timed out waiting for compositor smoke markers" >&2
      return 1
    fi

    sleep 0.5
  done
}

run_remote_smoke() {
  local dir command status
  dir="$(remote_dir)"
  sync_remote_tree
  command="cd $(printf '%q' "$dir") && SHADOW_UI_SMOKE_REMOTE=1 SHADOW_UI_SMOKE_NAMESPACE=$(printf '%q' "$UI_SMOKE_NAMESPACE") nix develop .#ui -c bash scripts/ui_smoke.sh"
  if remote_ssh "$command"; then
    status=0
  else
    status=$?
  fi
  remote_ssh "rm -rf $(printf '%q' "$dir")" >/dev/null 2>&1 || true
  return "$status"
}

main() {
  ensure_ui_shell "$@"

  if [[ "$(uname -s)" == "Linux" || "${SHADOW_UI_SMOKE_REMOTE:-}" == "1" ]]; then
    run_local_linux_smoke
    return
  fi

  run_remote_smoke
}

main "$@"
