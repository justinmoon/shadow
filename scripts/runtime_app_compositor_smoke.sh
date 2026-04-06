#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REMOTE_HOST="${SHADOW_UI_REMOTE_HOST:-${CUTTLEFISH_REMOTE_HOST:-hetzner}}"
REMOTE_DIR_CACHE="${SHADOW_UI_REMOTE_DIR:-}"
RUNTIME_APP_COMPOSITOR_TMPDIR=""
RUNTIME_APP_COMPOSITOR_TIMEOUT_SECS="${SHADOW_UI_SMOKE_TIMEOUT:-300}"
RUNTIME_APP_COMPOSITOR_NAMESPACE="${SHADOW_UI_SMOKE_NAMESPACE:-$(basename "$REPO_ROOT")-$$}"
RUNTIME_APP_COMPOSITOR_SSH_RETRIES="${SHADOW_UI_SMOKE_SSH_RETRIES:-3}"
RUNTIME_APP_COMPOSITOR_SSH_RETRY_SLEEP="${SHADOW_UI_SMOKE_SSH_RETRY_SLEEP:-2}"
RUNTIME_APP_COMPOSITOR_SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
)

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

  exec nix develop --accept-flake-config "$(flake_path)" -c "$0" "$@"
}

remote_home() {
  remote_ssh 'printf %s "$HOME"'
}

remote_ssh() {
  local attempt script status
  script="${1:?remote_ssh requires a script}"
  status=0
  for attempt in $(seq 1 "$RUNTIME_APP_COMPOSITOR_SSH_RETRIES"); do
    if ssh \
      "${RUNTIME_APP_COMPOSITOR_SSH_OPTS[@]}" \
      "$REMOTE_HOST" \
      /bin/bash -lc "$(printf '%q' "$script")"; then
      return 0
    fi
    status=$?
    if (( attempt == RUNTIME_APP_COMPOSITOR_SSH_RETRIES )); then
      return "$status"
    fi
    sleep "$RUNTIME_APP_COMPOSITOR_SSH_RETRY_SLEEP"
  done
  return "$status"
}

remote_dir() {
  if [[ -n "${REMOTE_DIR_CACHE:-}" ]]; then
    printf '%s\n' "$REMOTE_DIR_CACHE"
    return
  fi

  REMOTE_DIR_CACHE="$(remote_home)/.cache/shadow-runtime-ui-smoke-${RUNTIME_APP_COMPOSITOR_NAMESPACE}"
  printf '%s\n' "$REMOTE_DIR_CACHE"
}

sync_remote_tree() {
  local dir
  dir="$(remote_dir)"

  tar \
    --exclude=.git \
    --exclude=artifacts \
    --exclude=build \
    --exclude='rust/*/target' \
    --exclude=ui/target \
    --exclude=worktrees \
    -cf - \
    flake.nix \
    flake.lock \
    justfile \
    runtime \
    rust \
    scripts \
    ui \
    | remote_ssh "mkdir -p $(printf '%q' "$dir") && rm -rf $(printf '%q' "$dir/scripts") $(printf '%q' "$dir/ui") $(printf '%q' "$dir/runtime") $(printf '%q' "$dir/rust") $(printf '%q' "$dir/flake.nix") $(printf '%q' "$dir/flake.lock") $(printf '%q' "$dir/justfile") && tar -xf - -C $(printf '%q' "$dir")"
}

dump_logs() {
  local dir
  dir="$1"
  if [[ -f "$dir/compositor.log" ]]; then
    printf '\n== compositor.log ==\n'
    sed -n '1,360p' "$dir/compositor.log"
  fi
}

prepare_runtime_session() {
  local session_json
  session_json="$(scripts/runtime_prepare_host_session.sh)"
  printf '%s\n' "$session_json"

  RUNTIME_APP_BUNDLE_PATH="$(
    printf '%s\n' "$session_json" | python3 -c '
import json
import sys
print(json.load(sys.stdin)["bundlePath"])
'
  )"
  RUNTIME_HOST_BINARY_PATH="$(
    printf '%s\n' "$session_json" | python3 -c '
import json
import sys
print(json.load(sys.stdin)["runtimeHostBinaryPath"])
'
  )"
}

required_markers_seen() {
  local log_path marker
  log_path="$1"
  for marker in \
    '[shadow-compositor] launched-demo-client' \
    '[shadow-compositor] mapped-window' \
    'runtime-session-ready' \
    'runtime-document-ready' \
    'runtime-event-dispatched source=auto type=click target=counter'
  do
    if ! grep -Fq "$marker" "$log_path"; then
      return 1
    fi
  done
  return 0
}

run_local_linux_smoke() {
  local tmpdir runtime_dir compositor_log compositor_pid start now

  prepare_runtime_session

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/shadow-runtime-ui-smoke.XXXXXX")"
  RUNTIME_APP_COMPOSITOR_TMPDIR="$tmpdir"
  runtime_dir="$tmpdir/runtime"
  mkdir -p "$runtime_dir"
  chmod 700 "$runtime_dir"
  compositor_log="$tmpdir/compositor.log"
  compositor_pid=""

  cleanup() {
    if [[ -n "${compositor_pid:-}" ]]; then
      kill "$compositor_pid" 2>/dev/null || true
      wait "$compositor_pid" 2>/dev/null || true
    fi
    if [[ -n "${RUNTIME_APP_COMPOSITOR_TMPDIR:-}" ]]; then
      rm -rf "$RUNTIME_APP_COMPOSITOR_TMPDIR"
    fi
  }
  trap cleanup EXIT

  (
    cd "$REPO_ROOT"
    export SHADOW_APP_CLIENT="$REPO_ROOT/scripts/runtime_app_wayland_client.sh"
    export SHADOW_BLITZ_DEMO_MODE=runtime
    export SHADOW_BLITZ_RENDERER=gpu
    export SHADOW_BLITZ_RUNTIME_AUTO_CLICK_TARGET=counter
    export SHADOW_BLITZ_RUNTIME_EXIT_DELAY_MS="${SHADOW_BLITZ_RUNTIME_EXIT_DELAY_MS:-900}"
    export SHADOW_COMPOSITOR_AUTO_LAUNCH=1
    export SHADOW_COMPOSITOR_HEADLESS=1
    export SHADOW_RUNTIME_APP_BUNDLE_PATH="$RUNTIME_APP_BUNDLE_PATH"
    export SHADOW_RUNTIME_HOST_BINARY_PATH="$RUNTIME_HOST_BINARY_PATH"
    export XDG_RUNTIME_DIR="$runtime_dir"
    export RUST_LOG="${RUST_LOG:-shadow_compositor=info,smithay=warn}"
    cargo run --manifest-path ui/Cargo.toml -p shadow-compositor
  ) >"$compositor_log" 2>&1 &
  compositor_pid=$!

  start="$(date +%s)"
  while true; do
    if required_markers_seen "$compositor_log"; then
      printf 'Runtime app compositor smoke passed. Logs: %s\n' "$tmpdir"
      return 0
    fi

    if ! kill -0 "$compositor_pid" 2>/dev/null; then
      dump_logs "$tmpdir"
      echo "shadow-compositor exited before runtime GPU smoke markers appeared" >&2
      return 1
    fi

    now="$(date +%s)"
    if (( now - start > RUNTIME_APP_COMPOSITOR_TIMEOUT_SECS )); then
      dump_logs "$tmpdir"
      echo "timed out waiting for runtime GPU compositor smoke markers" >&2
      return 1
    fi

    sleep 0.5
  done
}

run_remote_smoke() {
  local dir command status
  dir="$(remote_dir)"
  sync_remote_tree
  command="cd $(printf '%q' "$dir") && SHADOW_UI_SMOKE_REMOTE=1 SHADOW_UI_SMOKE_NAMESPACE=$(printf '%q' "$RUNTIME_APP_COMPOSITOR_NAMESPACE") nix develop --accept-flake-config .#ui -c bash scripts/runtime_app_compositor_smoke.sh"
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
