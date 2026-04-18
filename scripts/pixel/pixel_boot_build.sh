#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./bootimg_common.sh
source "$SCRIPT_DIR/lib/bootimg_common.sh"
ensure_bootimg_shell "$@"

INPUT_IMAGE="${PIXEL_BOOT_INPUT_IMAGE:-}"
WRAPPER_BINARY="${PIXEL_INIT_WRAPPER_BIN:-$(pixel_boot_init_wrapper_bin)}"
KEY_PATH="${AVB_TEST_KEY_PATH:-}"
OUTPUT_IMAGE="${PIXEL_BOOT_OUTPUT_IMAGE:-}"
BUILD_MODE="wrapper"
KEEP_WORK_DIR=0
WORK_DIR=""
declare -a ADD_SPECS=()
declare -a REPLACE_SPECS=()

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_build.sh [--input PATH] [--wrapper PATH] [--key PATH] [--output PATH]
                                         [--add ENTRY=HOST_PATH] [--replace ENTRY=HOST_PATH]
                                         [--stock-init]
                                         [--keep-work-dir]

Rebuild a sunfish boot.img with the default /init wrapper path or a stock-init overlay-only path.
EOF
}

default_output_image() {
  if [[ "$BUILD_MODE" == "stock-init" ]]; then
    printf '%s/shadow-boot-stock-init.img\n' "$(pixel_boot_dir)"
    return 0
  fi

  pixel_boot_custom_boot_img
}

cleanup() {
  if [[ "$KEEP_WORK_DIR" == "1" ]]; then
    return 0
  fi
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      INPUT_IMAGE="${2:?missing value for --input}"
      shift 2
      ;;
    --wrapper)
      WRAPPER_BINARY="${2:?missing value for --wrapper}"
      shift 2
      ;;
    --key)
      KEY_PATH="${2:?missing value for --key}"
      shift 2
      ;;
    --output)
      OUTPUT_IMAGE="${2:?missing value for --output}"
      shift 2
      ;;
    --stock-init)
      BUILD_MODE="stock-init"
      shift
      ;;
    --add)
      ADD_SPECS+=("${2:?missing value for --add}")
      shift 2
      ;;
    --replace)
      REPLACE_SPECS+=("${2:?missing value for --replace}")
      shift 2
      ;;
    --keep-work-dir)
      KEEP_WORK_DIR=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "pixel_boot_build: unknown argument: $1" >&2
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
pixel_boot_build: input image not found: $INPUT_IMAGE

Run 'sc root-prep' first to cache the stock sunfish boot.img.
EOF
  exit 1
}

pixel_prepare_dirs
if [[ -z "$OUTPUT_IMAGE" ]]; then
  OUTPUT_IMAGE="$(default_output_image)"
fi

if [[ "$BUILD_MODE" == "wrapper" ]]; then
  if [[ ! -f "$WRAPPER_BINARY" ]]; then
    "$SCRIPT_DIR/pixel/pixel_build_init_wrapper.sh"
  fi

  if [[ ! -f "$WRAPPER_BINARY" ]]; then
    echo "pixel_boot_build: wrapper binary not found: $WRAPPER_BINARY" >&2
    exit 1
  fi
fi

if [[ -z "$KEY_PATH" ]]; then
  KEY_PATH="$(ensure_cached_avb_testkey)"
fi

mkdir -p "$(dirname "$OUTPUT_IMAGE")"
WORK_DIR="$(bootimg_prepare_work_dir shadow-pixel-boot-build)"
cp "$INPUT_IMAGE" "$WORK_DIR/boot.img"
if [[ "$BUILD_MODE" == "wrapper" ]]; then
  cp "$WRAPPER_BINARY" "$WORK_DIR/init-wrapper"
fi

bootimg_unpack_to_dir "$WORK_DIR/boot.img" "$WORK_DIR/unpacked"
ramdisk_compression="$(
  bootimg_decompress_ramdisk "$WORK_DIR/unpacked/out/ramdisk" "$WORK_DIR/ramdisk.cpio"
)"

cpio_args=(
  --input "$WORK_DIR/ramdisk.cpio"
  --output "$WORK_DIR/ramdisk.modified.cpio"
)

if [[ "$BUILD_MODE" == "wrapper" ]]; then
  cpio_args+=(
    --rename init=init.stock
    --add init="$WORK_DIR/init-wrapper"
  )
fi

for spec in "${ADD_SPECS[@]}"; do
  cpio_args+=(--add "$spec")
done

for spec in "${REPLACE_SPECS[@]}"; do
  cpio_args+=(--replace "$spec")
done

python3 "$SCRIPT_DIR/lib/cpio_edit.py" "${cpio_args[@]}"

bootimg_compress_ramdisk \
  "$ramdisk_compression" \
  "$WORK_DIR/ramdisk.modified.cpio" \
  "$WORK_DIR/ramdisk.modified"

(
  cd "$WORK_DIR/unpacked"
  bootimg_repack_from_args_file "mkbootimg_args.txt" "$WORK_DIR/ramdisk.modified" "$WORK_DIR/boot.modified.img"
)
bootimg_reapply_avb_footer "$WORK_DIR/boot.img" "$WORK_DIR/boot.modified.img" "$KEY_PATH" boot
cp "$WORK_DIR/boot.modified.img" "$OUTPUT_IMAGE"
printf '%s\n' "$(file "$OUTPUT_IMAGE")"

printf 'Wrote boot image: %s\n' "$OUTPUT_IMAGE"
printf 'Build mode: %s\n' "$BUILD_MODE"
printf 'Ramdisk compression: %s\n' "$ramdisk_compression"
if ((${#ADD_SPECS[@]})); then
  printf 'Extra added entries: %s\n' "${#ADD_SPECS[@]}"
fi
if ((${#REPLACE_SPECS[@]})); then
  printf 'Extra replaced entries: %s\n' "${#REPLACE_SPECS[@]}"
fi
if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  printf 'Kept workdir: %s\n' "$WORK_DIR"
fi

cat <<EOF
Next steps:
  inspect: scripts/pixel/pixel_boot_unpack.sh --input "$OUTPUT_IMAGE"
  safe stage on the other slot:
           PIXEL_SERIAL=<serial> scripts/pixel/pixel_boot_flash.sh --experimental --slot inactive --image "$OUTPUT_IMAGE"
  dry-run the risky path first:
           PIXEL_SERIAL=<serial> scripts/pixel/pixel_boot_flash.sh --experimental --activate-target --dry-run --image "$OUTPUT_IMAGE"
  restore an explicit slot later:
           PIXEL_SERIAL=<serial> scripts/pixel/pixel_boot_restore.sh --slot current
           PIXEL_SERIAL=<serial> scripts/pixel/pixel_boot_restore.sh --slot inactive
EOF
