#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

WRAPPER_MODE="${PIXEL_INIT_WRAPPER_MODE:-standard}"
OUTPUT_PATH="${INIT_WRAPPER_OUT:-}"
PACKAGE_REF=""
file_output=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_build_init_wrapper.sh [--mode standard|minimal]

Build the private arm64 init-wrapper flavor used by the boot-lab helpers.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      WRAPPER_MODE="${2:?missing value for --mode}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "pixel_build_init_wrapper: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$WRAPPER_MODE" in
  standard)
    PACKAGE_REF="path:$(repo_root)#init-wrapper-device"
    ;;
  minimal)
    PACKAGE_REF="path:$(repo_root)#init-wrapper-device-minimal"
    ;;
  *)
    echo "pixel_build_init_wrapper: unsupported wrapper mode: $WRAPPER_MODE" >&2
    exit 1
    ;;
esac

if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$(pixel_boot_init_wrapper_bin_for_mode "$WRAPPER_MODE")"
fi
pixel_assert_wrapper_cache_path_mode "$OUTPUT_PATH" "$WRAPPER_MODE"

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
pixel_assert_wrapper_binary_mode "$OUTPUT_PATH" "$WRAPPER_MODE"

printf 'Built init-wrapper (%s) -> %s\n' "$WRAPPER_MODE" "$OUTPUT_PATH"
