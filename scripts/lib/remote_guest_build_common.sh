#!/usr/bin/env bash

REMOTE_GUEST_BUILD_DIR_CACHE="${REMOTE_GUEST_BUILD_DIR_CACHE:-${REMOTE_GUEST_UI_DIR_CACHE:-}}"
GUEST_BUILD_NAMESPACE="${SHADOW_GUEST_BUILD_NAMESPACE:-${SHADOW_GUEST_UI_NAMESPACE:-$(worktree_basename)-$$}}"

remote_guest_build_dir() {
  if [[ -n "${REMOTE_GUEST_BUILD_DIR_CACHE:-}" ]]; then
    printf '%s\n' "$REMOTE_GUEST_BUILD_DIR_CACHE"
    return
  fi

  REMOTE_GUEST_BUILD_DIR_CACHE="$(remote_home)/.cache/shadow-guest-build-${GUEST_BUILD_NAMESPACE}"
  printf '%s\n' "$REMOTE_GUEST_BUILD_DIR_CACHE"
}

sync_remote_guest_build_tree() {
  local remote_dir root
  remote_dir="$(remote_guest_build_dir)"
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
    | ssh_retry "$REMOTE_HOST" \
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
