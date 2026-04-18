#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./bootimg_common.sh
source "$SCRIPT_DIR/lib/bootimg_common.sh"
ensure_bootimg_shell "$@"

INPUT_IMAGE="${PIXEL_BOOT_INPUT_IMAGE:-}"
OUTPUT_DIR=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_unpack.sh [--input PATH] [--output DIR]

Unpack a sunfish boot.img into a timestamped inspection directory.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      INPUT_IMAGE="${2:?missing value for --input}"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="${2:?missing value for --output}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "pixel_boot_unpack: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$INPUT_IMAGE" ]]; then
  INPUT_IMAGE="$(pixel_resolve_stock_boot_img || true)"
fi

[[ -f "$INPUT_IMAGE" ]] || {
  cat <<EOF >&2
pixel_boot_unpack: input image not found: $INPUT_IMAGE

Run 'sc root-prep' first to cache the stock sunfish boot.img.
EOF
  exit 1
}

pixel_prepare_dirs
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(pixel_prepare_named_run_dir "$(pixel_boot_unpacks_dir)")"
elif [[ -e "$OUTPUT_DIR" ]] && find "$OUTPUT_DIR" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
  echo "pixel_boot_unpack: output dir must be empty or absent: $OUTPUT_DIR" >&2
  exit 1
else
  mkdir -p "$OUTPUT_DIR"
fi

cp "$INPUT_IMAGE" "$OUTPUT_DIR/boot.img"
bootimg_unpack_to_dir "$INPUT_IMAGE" "$OUTPUT_DIR"
if [[ -f "$OUTPUT_DIR/out/ramdisk" ]]; then
  ramdisk_compression="$(bootimg_decompress_ramdisk "$OUTPUT_DIR/out/ramdisk" "$OUTPUT_DIR/ramdisk.cpio")"
  printf '%s\n' "$ramdisk_compression" >"$OUTPUT_DIR/ramdisk.compression"
fi

if ! avbtool info_image --image "$INPUT_IMAGE" >"$OUTPUT_DIR/avb.info" 2>&1; then
  printf 'No AVB footer information available for %s\n' "$INPUT_IMAGE" >"$OUTPUT_DIR/avb.info"
fi

printf 'Wrote unpacked boot image: %s\n' "$OUTPUT_DIR"
