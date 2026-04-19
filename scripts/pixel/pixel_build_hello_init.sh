#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_PATH="${PIXEL_HELLO_INIT_OUT:-}"
PACKAGE_REF="path:$(repo_root)#hello-init-device"
BUILD_ID_PATH=""

hello_init_build_input_hash() {
  shasum -a 256 \
    "$(repo_root)/scripts/pixel/pixel_hello_init.c" \
    "$(repo_root)/flake.nix" \
    "$(repo_root)/flake.lock" \
    | shasum -a 256 \
    | awk '{print $1}'
}

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_build_hello_init.sh [--output PATH]

Build the private arm64 static hello-init PID 1 used by the owned-userspace boot seam.
EOF
}

assert_hello_sentinel() {
  local binary_path sentinel message
  binary_path="${1:?assert_hello_sentinel requires a binary path}"
  sentinel="${2:?assert_hello_sentinel requires a sentinel}"
  message="${3:?assert_hello_sentinel requires a message}"

  if ! grep -aFq -- "$sentinel" "$binary_path"; then
    echo "pixel_build_hello_init: $message" >&2
    exit 1
  fi
}

validate_hello_binary() {
  local binary_path file_output
  binary_path="${1:?validate_hello_binary requires a binary path}"

  [[ -f "$binary_path" ]] || {
    echo "pixel_build_hello_init: binary not found: $binary_path" >&2
    return 1
  }

  chmod 0755 "$binary_path" 2>/dev/null || true
  [[ -x "$binary_path" ]] || {
    echo "pixel_build_hello_init: binary is not executable: $binary_path" >&2
    return 1
  }

  file_output="$(file "$binary_path")"
  printf '%s\n' "$file_output"

  if [[ "$file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_build_hello_init: expected an arm64 binary, got: $file_output" >&2
    return 1
  fi
  if [[ "$file_output" == *"dynamically linked"* ]]; then
    echo "pixel_build_hello_init: expected a static binary, got a dynamic one: $file_output" >&2
    return 1
  fi

  if ! grep -aFq -- 'shadow-owned-init-role:hello-init' "$binary_path"; then
    echo "pixel_build_hello_init: binary is missing the hello-init role sentinel" >&2
    return 1
  fi
  if ! grep -aFq -- 'shadow-owned-init-impl:c-static' "$binary_path"; then
    echo "pixel_build_hello_init: binary is missing the static implementation sentinel" >&2
    return 1
  fi
  if ! grep -aFq -- 'shadow-owned-init-config:/shadow-init.cfg' "$binary_path"; then
    echo "pixel_build_hello_init: binary is missing the expected config-path sentinel" >&2
    return 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_PATH="${2:?missing value for --output}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "pixel_build_hello_init: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$(pixel_boot_dir)/hello-init"
fi

pixel_prepare_dirs
mkdir -p "$(dirname "$OUTPUT_PATH")"
BUILD_ID_PATH="${OUTPUT_PATH}.build-id"

expected_build_id="$(hello_init_build_input_hash)"
if [[ -f "$OUTPUT_PATH" && -f "$BUILD_ID_PATH" ]]; then
  cached_build_id="$(tr -d '[:space:]' <"$BUILD_ID_PATH")"
  if [[ "$cached_build_id" == "$expected_build_id" ]]; then
    if validate_hello_binary "$OUTPUT_PATH"; then
      printf 'Reusing cached hello-init -> %s\n' "$OUTPUT_PATH"
      exit 0
    fi

    echo "pixel_build_hello_init: cached hello-init is invalid; rebuilding: $OUTPUT_PATH" >&2
    rm -f "$OUTPUT_PATH" "$BUILD_ID_PATH"
  fi
fi

store_path="$(
  pixel_retry_nix_build_print_out_paths nix build --no-link --print-out-paths "$PACKAGE_REF"
)"

cp "$store_path/bin/hello-init" "$OUTPUT_PATH"
chmod 0755 "$OUTPUT_PATH"
validate_hello_binary "$OUTPUT_PATH"
printf '%s\n' "$expected_build_id" >"$BUILD_ID_PATH"

printf 'Built hello-init -> %s\n' "$OUTPUT_PATH"
