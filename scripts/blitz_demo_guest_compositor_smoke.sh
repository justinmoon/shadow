#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REMOTE_HOST="${SHADOW_UI_REMOTE_HOST:-${CUTTLEFISH_REMOTE_HOST:-hetzner}}"
REMOTE_DIR_CACHE="${SHADOW_UI_REMOTE_DIR:-}"
GUEST_BLITZ_SMOKE_TMPDIR=""
GUEST_BLITZ_SMOKE_TIMEOUT_SECS="${SHADOW_UI_SMOKE_TIMEOUT:-300}"
GUEST_BLITZ_SMOKE_NAMESPACE="${SHADOW_UI_SMOKE_NAMESPACE:-$(basename "$REPO_ROOT")-$$}"
EXPECTED_BUFFER_TYPE="${SHADOW_GUEST_EXPECTED_BUFFER_TYPE:-dma}"
WGPU_BACKEND_OVERRIDE="${WGPU_BACKEND:-}"
WGPU_ADAPTER_NAME_OVERRIDE="${WGPU_ADAPTER_NAME:-}"
GUEST_BLITZ_SMOKE_SSH_RETRIES="${SHADOW_UI_SMOKE_SSH_RETRIES:-3}"
GUEST_BLITZ_SMOKE_SSH_RETRY_SLEEP="${SHADOW_UI_SMOKE_SSH_RETRY_SLEEP:-2}"
GUEST_BLITZ_SMOKE_SSH_OPTS=(
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
  for attempt in $(seq 1 "$GUEST_BLITZ_SMOKE_SSH_RETRIES"); do
    if ssh \
      "${GUEST_BLITZ_SMOKE_SSH_OPTS[@]}" \
      "$REMOTE_HOST" \
      /bin/bash -lc "$(printf '%q' "$script")"; then
      return 0
    fi
    status=$?
    if (( attempt == GUEST_BLITZ_SMOKE_SSH_RETRIES )); then
      return "$status"
    fi
    sleep "$GUEST_BLITZ_SMOKE_SSH_RETRY_SLEEP"
  done
  return "$status"
}

remote_dir() {
  if [[ -n "${REMOTE_DIR_CACHE:-}" ]]; then
    printf '%s\n' "$REMOTE_DIR_CACHE"
    return
  fi

  REMOTE_DIR_CACHE="$(remote_home)/.cache/shadow-guest-blitz-ui-smoke-${GUEST_BLITZ_SMOKE_NAMESPACE}"
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
  if [[ -f "$dir/guest-compositor.log" ]]; then
    printf '\n== guest-compositor.log ==\n'
    sed -n '1,360p' "$dir/guest-compositor.log"
  fi
}

required_markers_seen() {
  local log_path marker
  log_path="$1"
  for marker in \
    '[shadow-guest-compositor] launched-client=' \
    '[shadow-guest-compositor] mapped-window' \
    '[shadow-blitz-demo] static-document-ready' \
    '[shadow-guest-compositor] dmabuf-imported' \
    "[shadow-guest-compositor] buffer-observed type=${EXPECTED_BUFFER_TYPE}"
  do
    if ! grep -Fq "$marker" "$log_path"; then
      return 1
    fi
  done
  return 0
}

unexpected_buffer_type_seen() {
  local log_path
  log_path="$1"

  case "$EXPECTED_BUFFER_TYPE" in
    dma)
      grep -Fq '[shadow-guest-compositor] buffer-observed type=shm' "$log_path"
      ;;
    shm)
      grep -Fq '[shadow-guest-compositor] buffer-observed type=dma' "$log_path"
      ;;
    *)
      return 1
      ;;
  esac
}

run_local_linux_smoke() {
  local tmpdir runtime_dir compositor_log compositor_pid start now
  local -a guest_client_env

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/shadow-guest-blitz-ui-smoke.XXXXXX")"
  GUEST_BLITZ_SMOKE_TMPDIR="$tmpdir"
  runtime_dir="$tmpdir/runtime"
  mkdir -p "$runtime_dir"
  chmod 700 "$runtime_dir"
  compositor_log="$tmpdir/guest-compositor.log"
  compositor_pid=""

  cleanup() {
    if [[ -n "${compositor_pid:-}" ]]; then
      kill "$compositor_pid" 2>/dev/null || true
      wait "$compositor_pid" 2>/dev/null || true
    fi
    if [[ -n "${GUEST_BLITZ_SMOKE_TMPDIR:-}" ]]; then
      rm -rf "$GUEST_BLITZ_SMOKE_TMPDIR"
    fi
  }
  trap cleanup EXIT

  guest_client_env=(
    "SHADOW_BLITZ_DEMO_MODE=static"
    "SHADOW_BLITZ_RENDERER=gpu"
  )
  if [[ -n "$WGPU_BACKEND_OVERRIDE" ]]; then
    guest_client_env+=("WGPU_BACKEND=$WGPU_BACKEND_OVERRIDE")
  fi
  if [[ -n "$WGPU_ADAPTER_NAME_OVERRIDE" ]]; then
    guest_client_env+=("WGPU_ADAPTER_NAME=$WGPU_ADAPTER_NAME_OVERRIDE")
  fi

  (
    cd "$REPO_ROOT"
    export SHADOW_GUEST_CLIENT="$REPO_ROOT/scripts/runtime_app_wayland_client.sh"
    export SHADOW_GUEST_CLIENT_ENV="${guest_client_env[*]}"
    export SHADOW_GUEST_COMPOSITOR_TRANSPORT=direct
    export SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_DMA_BUFFER=1
    export XDG_RUNTIME_DIR="$runtime_dir"
    export RUST_LOG="${RUST_LOG:-shadow_compositor_guest=info,smithay=warn}"
    cargo run --manifest-path ui/Cargo.toml -p shadow-compositor-guest
  ) >"$compositor_log" 2>&1 &
  compositor_pid=$!

  start="$(date +%s)"
  while true; do
    if required_markers_seen "$compositor_log"; then
      printf 'Blitz demo guest compositor GPU smoke passed. Logs: %s\n' "$tmpdir"
      return 0
    fi

    if unexpected_buffer_type_seen "$compositor_log"; then
      dump_logs "$tmpdir"
      echo "guest compositor observed an unexpected buffer type before ${EXPECTED_BUFFER_TYPE} appeared" >&2
      return 1
    fi

    if ! kill -0 "$compositor_pid" 2>/dev/null; then
      if required_markers_seen "$compositor_log"; then
        printf 'Blitz demo guest compositor GPU smoke passed. Logs: %s\n' "$tmpdir"
        return 0
      fi
      dump_logs "$tmpdir"
      echo "shadow-compositor-guest exited before GPU dmabuf markers appeared" >&2
      return 1
    fi

    now="$(date +%s)"
    if (( now - start > GUEST_BLITZ_SMOKE_TIMEOUT_SECS )); then
      dump_logs "$tmpdir"
      echo "timed out waiting for guest compositor GPU dmabuf markers" >&2
      return 1
    fi

    sleep 0.5
  done
}

run_remote_smoke() {
  local dir command status
  local -a env_prefix
  dir="$(remote_dir)"
  sync_remote_tree
  env_prefix=(
    "SHADOW_UI_SMOKE_REMOTE=1"
    "SHADOW_UI_SMOKE_NAMESPACE=$(printf '%q' "$GUEST_BLITZ_SMOKE_NAMESPACE")"
    "SHADOW_UI_SMOKE_TIMEOUT=$(printf '%q' "$GUEST_BLITZ_SMOKE_TIMEOUT_SECS")"
    "SHADOW_GUEST_EXPECTED_BUFFER_TYPE=$(printf '%q' "$EXPECTED_BUFFER_TYPE")"
  )
  if [[ -n "$WGPU_BACKEND_OVERRIDE" ]]; then
    env_prefix+=("WGPU_BACKEND=$(printf '%q' "$WGPU_BACKEND_OVERRIDE")")
  fi
  if [[ -n "$WGPU_ADAPTER_NAME_OVERRIDE" ]]; then
    env_prefix+=("WGPU_ADAPTER_NAME=$(printf '%q' "$WGPU_ADAPTER_NAME_OVERRIDE")")
  fi
  command="cd $(printf '%q' "$dir") && ${env_prefix[*]} nix develop --accept-flake-config .#ui -c bash scripts/blitz_demo_guest_compositor_smoke.sh"
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
