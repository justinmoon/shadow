#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
# shellcheck source=./guest_ui_common.sh
source "$SCRIPT_DIR/guest_ui_common.sh"
ensure_bootimg_shell "$@"

build_one() {
  local attr binary out_link output_path file_output
  attr="$1"
  binary="$2"
  out_link="$(pixel_dir)/${binary}-result"
  output_path="$(pixel_artifact_path "$binary")"

  mkdir -p "$(dirname "$out_link")"
  rm -f "$out_link"
  nix build "$(repo_root)#${attr}" --out-link "$out_link"

  cp "$out_link/bin/$binary" "$output_path"
  chmod 0755 "$output_path"
  file_output="$(file "$output_path")"
  printf '%s\n' "$file_output"

  if [[ "$file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_build: expected an arm64 binary, got: $file_output" >&2
    exit 1
  fi
  if [[ "$file_output" == *"dynamically linked"* ]]; then
    echo "pixel_build: expected a static binary, got a dynamic one: $file_output" >&2
    exit 1
  fi

  printf 'Built %s -> %s\n' "$binary" "$output_path"
}

validate_device_binary() {
  local output_path file_output
  output_path="$1"
  file_output="$(file "$output_path")"
  printf '%s\n' "$file_output"
  if [[ "$file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_build: expected an arm64 binary, got: $file_output" >&2
    exit 1
  fi
  if [[ "$file_output" == *"dynamically linked"* ]]; then
    echo "pixel_build: expected a static binary, got a dynamic one: $file_output" >&2
    exit 1
  fi
}

copy_linux_package_binary() {
  local attr binary_name linux_system package_ref out_link output_path
  attr="$1"
  binary_name="$2"
  linux_system="${PIXEL_GUEST_BUILD_SYSTEM:-aarch64-linux}"
  package_ref="$(repo_root)#packages.${linux_system}.${attr}"
  out_link="$(pixel_dir)/${binary_name}-result"
  output_path="$(pixel_artifact_path "$binary_name")"

  mkdir -p "$(dirname "$out_link")"
  rm -f "$out_link"
  if ! nix build "$package_ref" --out-link "$out_link"; then
    return 1
  fi

  cp "$out_link/bin/$binary_name" "$output_path"
  chmod 0755 "$output_path"
  validate_device_binary "$output_path"
  printf 'Built %s via %s -> %s\n' "$binary_name" "$linux_system" "$output_path"
}

copy_remote_binary() {
  local remote_repo attr binary_name remote_bin output_path
  remote_repo="$1"
  attr="$2"
  binary_name="$3"
  output_path="$(pixel_artifact_path "$binary_name")"
  remote_bin="$(remote_store_bin "$remote_repo" "$attr" "$binary_name")"
  scp "${SSH_OPTS[@]}" -q "${REMOTE_HOST}:$remote_bin" "$output_path"
  chmod 0755 "$output_path"
  validate_device_binary "$output_path"
  printf 'Fetched %s -> %s\n' "$binary_name" "$output_path"
}

pixel_prepare_dirs
build_one shadow-session-device shadow-session

if [[ "$(uname -s)" == "Linux" ]]; then
  build_one shadow-compositor-guest-device shadow-compositor-guest
  build_one shadow-counter-guest-device shadow-counter-guest
else
  remote_repo=""
  cleanup_remote_repo() {
    [[ -n "$remote_repo" ]] || return 0
    remote_shell "rm -rf $(printf '%q' "$remote_repo")" >/dev/null 2>&1 || true
  }
  trap cleanup_remote_repo EXIT

  for attr in shadow-compositor-guest-device shadow-counter-guest-device; do
    binary_name="${attr%-device}"
    if copy_linux_package_binary "$attr" "$binary_name"; then
      continue
    fi

    echo "pixel_build: falling back to remote guest UI repo sync for $binary_name" >&2
    if [[ -z "$remote_repo" ]]; then
      remote_repo="$(sync_remote_guest_ui_tree)"
    fi
    copy_remote_binary "$remote_repo" "$attr" "$binary_name"
  done
fi
