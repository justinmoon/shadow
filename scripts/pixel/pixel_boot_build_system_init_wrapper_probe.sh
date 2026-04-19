#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./bootimg_common.sh
source "$SCRIPT_DIR/lib/bootimg_common.sh"
ensure_bootimg_shell "$@"

INPUT_IMAGE="${PIXEL_BOOT_INPUT_IMAGE:-}"
WRAPPER_BINARY="${PIXEL_INIT_WRAPPER_BIN:-}"
KEY_PATH="${AVB_TEST_KEY_PATH:-}"
OUTPUT_IMAGE="${PIXEL_BOOT_SYSTEM_INIT_WRAPPER_PROBE_IMAGE:-}"
KEEP_WORK_DIR=0
WORK_DIR=""
WRAPPER_ENTRY_PATH="/system/bin/init"
WRAPPER_STOCK_PATH="/system/bin/init.stock"

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_build_system_init_wrapper_probe.sh [--input PATH] [--wrapper PATH]
                                                                   [--key PATH] [--output PATH]
                                                                   [--keep-work-dir]

Build a private stock-init sunfish boot.img that preserves /init -> /system/bin/init,
moves system/bin/init aside to system/bin/init.stock, and restores system/bin/init as
an exact-path static wrapper.
EOF
}

default_output_image() {
  printf '%s/shadow-boot-system-init-wrapper-probe.img\n' "$(pixel_boot_dir)"
}

assert_stock_root_init_shape() {
  local unpack_dir ramdisk_cpio
  unpack_dir="$WORK_DIR/input-unpacked"
  ramdisk_cpio="$WORK_DIR/input-ramdisk.cpio"

  bootimg_unpack_to_dir "$INPUT_IMAGE" "$unpack_dir"
  bootimg_decompress_ramdisk "$unpack_dir/out/ramdisk" "$ramdisk_cpio" >/dev/null

  PYTHONPATH="$SCRIPT_DIR/lib" python3 - "$ramdisk_cpio" <<'PY'
from pathlib import Path
import stat
import sys

from cpio_edit import read_cpio

ramdisk_cpio = Path(sys.argv[1])
entries = {entry.name: entry for entry in read_cpio(ramdisk_cpio).without_trailer()}

init_entry = entries.get("init")
if init_entry is None:
    raise SystemExit(
        "pixel_boot_build_system_init_wrapper_probe: missing root init entry in ramdisk"
    )
if not stat.S_ISLNK(init_entry.mode):
    raise SystemExit(
        "pixel_boot_build_system_init_wrapper_probe: expected stock root /init "
        "symlink to /system/bin/init, found non-symlink entry"
    )

target = init_entry.data.decode("utf-8", errors="surrogateescape")
if target != "/system/bin/init":
    raise SystemExit(
        "pixel_boot_build_system_init_wrapper_probe: expected stock root /init "
        f"symlink target /system/bin/init, found {target!r}"
    )

system_init_entry = entries.get("system/bin/init")
if system_init_entry is None:
    raise SystemExit(
        "pixel_boot_build_system_init_wrapper_probe: missing system/bin/init entry in ramdisk"
    )
if stat.S_ISLNK(system_init_entry.mode):
    raise SystemExit(
        "pixel_boot_build_system_init_wrapper_probe: expected stock system/bin/init "
        "to be a regular file, found a symlink"
    )
PY
}

assert_wrapper_sentinel() {
  local wrapper_path sentinel message
  wrapper_path="${1:?assert_wrapper_sentinel requires a wrapper path}"
  sentinel="${2:?assert_wrapper_sentinel requires a sentinel}"
  message="${3:?assert_wrapper_sentinel requires a message}"

  if ! grep -aFq -- "$sentinel" "$wrapper_path"; then
    echo "pixel_boot_build_system_init_wrapper_probe: $message" >&2
    exit 1
  fi
}

assert_wrapper_variant() {
  local wrapper_path file_output
  wrapper_path="${1:?assert_wrapper_variant requires a wrapper path}"

  file_output="$(file "$wrapper_path")"
  if [[ "$file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_boot_build_system_init_wrapper_probe: expected an arm64 wrapper binary, got: $file_output" >&2
    exit 1
  fi
  if [[ "$file_output" == *"dynamically linked"* ]]; then
    echo "pixel_boot_build_system_init_wrapper_probe: expected a static wrapper binary, got a dynamic one: $file_output" >&2
    exit 1
  fi

  pixel_assert_wrapper_binary_mode "$wrapper_path" minimal
  assert_wrapper_sentinel \
    "$wrapper_path" \
    'shadow-init-wrapper-impl:tinyc-direct' \
    "wrapper binary is missing the tinyc implementation sentinel"
  assert_wrapper_sentinel \
    "$wrapper_path" \
    "shadow-init-wrapper-path:$WRAPPER_ENTRY_PATH" \
    "wrapper binary is missing the expected entry-path sentinel: shadow-init-wrapper-path:$WRAPPER_ENTRY_PATH"
  assert_wrapper_sentinel \
    "$wrapper_path" \
    "shadow-init-wrapper-target:$WRAPPER_STOCK_PATH" \
    "wrapper binary is missing the expected handoff-path sentinel: shadow-init-wrapper-target:$WRAPPER_STOCK_PATH"
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
    --keep-work-dir)
      KEEP_WORK_DIR=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "pixel_boot_build_system_init_wrapper_probe: unknown argument: $1" >&2
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
pixel_boot_build_system_init_wrapper_probe: input image not found: $INPUT_IMAGE

Run 'sc root-prep' first to cache the stock sunfish boot.img.
EOF
  exit 1
}

if [[ -z "$KEY_PATH" ]]; then
  KEY_PATH="$(ensure_cached_avb_testkey)"
fi

pixel_prepare_dirs
if [[ -z "$OUTPUT_IMAGE" ]]; then
  OUTPUT_IMAGE="$(default_output_image)"
fi
mkdir -p "$(dirname "$OUTPUT_IMAGE")"
WORK_DIR="$(bootimg_prepare_work_dir shadow-pixel-boot-system-init-wrapper-probe)"
assert_stock_root_init_shape

if [[ -z "$WRAPPER_BINARY" ]]; then
  WRAPPER_BINARY="$WORK_DIR/system-init-wrapper"
  "$SCRIPT_DIR/pixel/pixel_build_init_wrapper_c.sh" \
    --output "$WRAPPER_BINARY" \
    --stock-path "$WRAPPER_STOCK_PATH"
fi

[[ -f "$WRAPPER_BINARY" ]] || {
  echo "pixel_boot_build_system_init_wrapper_probe: wrapper binary not found: $WRAPPER_BINARY" >&2
  exit 1
}

assert_wrapper_variant "$WRAPPER_BINARY"

build_args=(
  --stock-init
  --input "$INPUT_IMAGE"
  --key "$KEY_PATH"
  --output "$OUTPUT_IMAGE"
  --rename "system/bin/init=system/bin/init.stock"
  --add "system/bin/init=$WRAPPER_BINARY"
)

if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  build_args+=(--keep-work-dir)
fi

"$SCRIPT_DIR/pixel/pixel_boot_build.sh" "${build_args[@]}"

printf 'Probe mode: system-init-wrapper\n'
printf 'Root init path: preserve stock /init -> /system/bin/init symlink\n'
printf 'System init mutation: rename system/bin/init=system/bin/init.stock and replace system/bin/init with an exact-path wrapper\n'
printf 'Wrapper entry path: %s\n' "$WRAPPER_ENTRY_PATH"
printf 'Wrapper handoff target: %s\n' "$WRAPPER_STOCK_PATH"
if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  printf 'Kept probe workdir: %s\n' "$WORK_DIR"
fi
