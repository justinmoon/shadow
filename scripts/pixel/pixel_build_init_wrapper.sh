#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_PATH="${INIT_WRAPPER_OUT:-$(pixel_boot_init_wrapper_bin)}"
PACKAGE_REF="path:$(repo_root)#init-wrapper-device"
file_output=""

pixel_prepare_dirs
mkdir -p "$(dirname "$OUTPUT_PATH")"

store_path="$(
  pixel_retry_nix_build_print_out_paths nix build --no-link --print-out-paths "$PACKAGE_REF"
)"

cp "$store_path/bin/init-wrapper" "$OUTPUT_PATH"
chmod 0755 "$OUTPUT_PATH"
file_output="$(file "$OUTPUT_PATH")"
printf '%s\n' "$file_output"

if [[ "$file_output" != *"ARM aarch64"* ]]; then
  echo "pixel_build_init_wrapper: expected an arm64 binary, got: $file_output" >&2
  exit 1
fi
if [[ "$file_output" == *"dynamically linked"* ]]; then
  echo "pixel_build_init_wrapper: expected a static binary, got a dynamic one: $file_output" >&2
  exit 1
fi

printf 'Built init-wrapper -> %s\n' "$OUTPUT_PATH"
