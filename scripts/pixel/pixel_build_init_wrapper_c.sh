#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_PATH="${INIT_WRAPPER_OUT:-}"
STOCK_INIT_PATH="${PIXEL_INIT_WRAPPER_STOCK_PATH:-/init.stock}"
ENTRY_PATH=""
PACKAGE_REF=""
file_output=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_build_init_wrapper_c.sh [--output PATH]
                                                  [--stock-path /init.stock|/system/bin/init.stock]

Build the private minimal arm64 C init-wrapper used by sunfish boot handoff experiments.
EOF
}

resolve_entry_path() {
  local stock_init_path
  stock_init_path="${1:?resolve_entry_path requires a stock-init path}"

  case "$stock_init_path" in
    /init.stock)
      printf '/init\n'
      ;;
    /system/bin/init.stock)
      printf '/system/bin/init\n'
      ;;
    *)
      echo "pixel_build_init_wrapper_c: unsupported --stock-path: $stock_init_path" >&2
      exit 1
      ;;
  esac
}

default_output_path() {
  case "$STOCK_INIT_PATH" in
    /init.stock)
      printf '%s/init-wrapper-c-minimal\n' "$(pixel_boot_dir)"
      ;;
    /system/bin/init.stock)
      printf '%s/init-wrapper-c-system-init-minimal\n' "$(pixel_boot_dir)"
      ;;
    *)
      echo "pixel_build_init_wrapper_c: unsupported --stock-path: $STOCK_INIT_PATH" >&2
      exit 1
      ;;
  esac
}

resolve_package_ref() {
  case "$STOCK_INIT_PATH" in
    /init.stock)
      printf 'path:%s#init-wrapper-c-device\n' "$(repo_root)"
      ;;
    /system/bin/init.stock)
      printf 'path:%s#init-wrapper-c-device-system-init\n' "$(repo_root)"
      ;;
    *)
      echo "pixel_build_init_wrapper_c: unsupported --stock-path: $STOCK_INIT_PATH" >&2
      exit 1
      ;;
  esac
}

assert_wrapper_sentinel() {
  local wrapper_path sentinel message
  wrapper_path="${1:?assert_wrapper_sentinel requires a wrapper path}"
  sentinel="${2:?assert_wrapper_sentinel requires a sentinel}"
  message="${3:?assert_wrapper_sentinel requires a message}"

  if ! grep -aFq -- "$sentinel" "$wrapper_path"; then
    echo "pixel_build_init_wrapper_c: $message" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_PATH="${2:?missing value for --output}"
      shift 2
      ;;
    --stock-path)
      STOCK_INIT_PATH="${2:?missing value for --stock-path}"
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

ENTRY_PATH="$(resolve_entry_path "$STOCK_INIT_PATH")"
PACKAGE_REF="$(resolve_package_ref)"
if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$(default_output_path)"
fi

case "$OUTPUT_PATH" in
  "$(pixel_boot_init_wrapper_bin)"|"$(pixel_boot_init_wrapper_bin_for_mode minimal)")
    cat <<EOF >&2
pixel_build_init_wrapper_c: output path must stay separate from the Rust wrapper cache: $OUTPUT_PATH

Use the dedicated C-wrapper cache path instead:
  $(default_output_path)
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
assert_wrapper_sentinel \
  "$OUTPUT_PATH" \
  'shadow-init-wrapper-impl:tinyc-direct' \
  "wrapper binary is missing the tinyc implementation sentinel"
assert_wrapper_sentinel \
  "$OUTPUT_PATH" \
  "shadow-init-wrapper-path:$ENTRY_PATH" \
  "wrapper binary is missing the expected entry-path sentinel: shadow-init-wrapper-path:$ENTRY_PATH"
assert_wrapper_sentinel \
  "$OUTPUT_PATH" \
  "shadow-init-wrapper-target:$STOCK_INIT_PATH" \
  "wrapper binary is missing the expected handoff-path sentinel: shadow-init-wrapper-target:$STOCK_INIT_PATH"

printf 'Built init-wrapper-c (minimal) -> %s\n' "$OUTPUT_PATH"
printf 'Wrapper entry path: %s\n' "$ENTRY_PATH"
printf 'Wrapper handoff target: %s\n' "$STOCK_INIT_PATH"
