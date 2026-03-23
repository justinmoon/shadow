#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_IMAGE="${INIT_BOOT_OUT:-$(build_dir)/init_boot.guest_ui.img}"
REMOTE_GUEST_UI_DIR_CACHE="${REMOTE_GUEST_UI_DIR_CACHE:-}"
GUEST_UI_NAMESPACE="${SHADOW_GUEST_UI_NAMESPACE:-$(worktree_basename)-$$}"

if [[ -z "${INIT_BOOT_OUT:-}" ]]; then
  OUTPUT_IMAGE="$(build_dir)/init_boot.guest_ui.${GUEST_UI_NAMESPACE}.img"
fi

usage() {
  cat <<'EOF'
Usage: scripts/init_boot_guest_ui.sh [--output PATH]

Rebuild init_boot.img with the Rust /init wrapper plus the guest compositor and client payloads.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_IMAGE="${2:?missing value for --output}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "init_boot_guest_ui: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

remote_guest_ui_dir() {
  if [[ -n "${REMOTE_GUEST_UI_DIR_CACHE:-}" ]]; then
    printf '%s\n' "$REMOTE_GUEST_UI_DIR_CACHE"
    return
  fi

  REMOTE_GUEST_UI_DIR_CACHE="$(remote_home)/.cache/shadow-guest-ui-${GUEST_UI_NAMESPACE}"
  printf '%s\n' "$REMOTE_GUEST_UI_DIR_CACHE"
}

sync_remote_guest_ui_tree() {
  local remote_dir root
  remote_dir="$(remote_guest_ui_dir)"
  root="$(repo_root)"

  if is_local_host; then
    printf '%s\n' "$root"
    return
  fi

  tar \
    --exclude=.git \
    --exclude=artifacts \
    --exclude=build \
    --exclude=out \
    --exclude=ui/target \
    --exclude=worktrees \
    -cf - \
    -C "$root" \
    flake.nix \
    flake.lock \
    justfile \
    rust \
    scripts \
    ui \
    | ssh "$REMOTE_HOST" \
        "rm -rf $(printf '%q' "$remote_dir") && mkdir -p $(printf '%q' "$remote_dir") && tar -xf - -C $(printf '%q' "$remote_dir")"

  printf '%s\n' "$remote_dir"
}

local_store_bin() {
  local attr binary_name store_path
  attr="$1"
  binary_name="$2"
  store_path="$(nix build "$(repo_root)#${attr}" --print-out-paths --no-link | tail -n 1)"
  printf '%s/bin/%s\n' "$store_path" "$binary_name"
}

remote_store_bin() {
  local repo_dir attr binary_name store_path
  repo_dir="$1"
  attr="$2"
  binary_name="$3"
  store_path="$(remote_shell "cd $(printf '%q' "$repo_dir") && nix build .#${attr} --print-out-paths --no-link | tail -n 1")"
  store_path="$(printf '%s' "$store_path" | tr -d '[:space:]')"
  printf '%s/bin/%s\n' "$store_path" "$binary_name"
}

main() {
  local compositor_bin counter_bin remote_dir

  if is_local_host; then
    if [[ "$(uname -s)" != "Linux" ]]; then
      echo "init_boot_guest_ui: local guest-ui build requires Linux; use a remote host such as hetzner" >&2
      exit 1
    fi

    compositor_bin="$(local_store_bin shadow-compositor-guest shadow-compositor-guest)"
    counter_bin="$(local_store_bin shadow-counter-guest shadow-counter-guest)"

    "$SCRIPT_DIR/init_boot_wrapper.sh" \
      --output "$OUTPUT_IMAGE" \
      --extra-bin /shadow-compositor-guest="$compositor_bin" \
      --extra-bin /shadow-counter-guest="$counter_bin"
    return
  fi

  remote_dir="$(sync_remote_guest_ui_tree)"
  cleanup_remote_guest_ui_dir() {
    remote_shell "rm -rf $(printf '%q' "$remote_dir")"
  }
  trap cleanup_remote_guest_ui_dir RETURN
  compositor_bin="$(remote_store_bin "$remote_dir" shadow-compositor-guest shadow-compositor-guest)"
  counter_bin="$(remote_store_bin "$remote_dir" shadow-counter-guest shadow-counter-guest)"

  "$SCRIPT_DIR/init_boot_wrapper.sh" \
    --output "$OUTPUT_IMAGE" \
    --extra-bin-remote /shadow-compositor-guest="$compositor_bin" \
    --extra-bin-remote /shadow-counter-guest="$counter_bin"
}

main "$@"
