#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_PATH="${INIT_WRAPPER_OUT:-$(pixel_boot_dir)/init-wrapper-c-minimal}"
PACKAGE_REF="path:$(repo_root)#init-wrapper-c-device"
file_output=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_build_init_wrapper_c.sh [--output PATH]

Build the private minimal arm64 C init-wrapper used by sunfish boot handoff experiments.
EOF
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
      echo "pixel_build_init_wrapper_c: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$OUTPUT_PATH" in
  "$(pixel_boot_init_wrapper_bin)"|"$(pixel_boot_init_wrapper_bin_for_mode minimal)")
    cat <<EOF >&2
pixel_build_init_wrapper_c: output path must stay separate from the Rust wrapper cache: $OUTPUT_PATH

Use the dedicated C-wrapper cache path instead:
  $(pixel_boot_dir)/init-wrapper-c-minimal
EOF
    exit 1
    ;;
esac

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
  echo "pixel_build_init_wrapper_c: expected an arm64 binary, got: $file_output" >&2
  exit 1
fi
if [[ "$file_output" == *"dynamically linked"* ]]; then
  echo "pixel_build_init_wrapper_c: expected a static binary, got a dynamic one: $file_output" >&2
  exit 1
fi

pixel_assert_wrapper_binary_mode "$OUTPUT_PATH" minimal
if ! grep -aFq -- 'shadow-init-wrapper-impl:tinyc-direct' "$OUTPUT_PATH"; then
  echo "pixel_build_init_wrapper_c: wrapper binary is missing the tinyc implementation sentinel" >&2
  exit 1
fi

printf 'Built init-wrapper-c (minimal) -> %s\n' "$OUTPUT_PATH"
