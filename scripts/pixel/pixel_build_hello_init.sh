#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_PATH="${PIXEL_HELLO_INIT_OUT:-}"
PACKAGE_REF="path:$(repo_root)#hello-init-device"
file_output=""

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

store_path="$(
  pixel_retry_nix_build_print_out_paths nix build --no-link --print-out-paths "$PACKAGE_REF"
)"

cp "$store_path/bin/hello-init" "$OUTPUT_PATH"
chmod 0755 "$OUTPUT_PATH"
file_output="$(file "$OUTPUT_PATH")"
printf '%s\n' "$file_output"

if [[ "$file_output" != *"ARM aarch64"* ]]; then
  echo "pixel_build_hello_init: expected an arm64 binary, got: $file_output" >&2
  exit 1
fi
if [[ "$file_output" == *"dynamically linked"* ]]; then
  echo "pixel_build_hello_init: expected a static binary, got a dynamic one: $file_output" >&2
  exit 1
fi

assert_hello_sentinel \
  "$OUTPUT_PATH" \
  'shadow-owned-init-role:hello-init' \
  "binary is missing the hello-init role sentinel"
assert_hello_sentinel \
  "$OUTPUT_PATH" \
  'shadow-owned-init-impl:c-static' \
  "binary is missing the static implementation sentinel"
assert_hello_sentinel \
  "$OUTPUT_PATH" \
  'shadow-owned-init-config:/shadow-init.cfg' \
  "binary is missing the expected config-path sentinel"

printf 'Built hello-init -> %s\n' "$OUTPUT_PATH"
