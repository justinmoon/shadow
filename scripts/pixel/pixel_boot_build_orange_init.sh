#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./bootimg_common.sh
source "$SCRIPT_DIR/lib/bootimg_common.sh"
ensure_bootimg_shell "$@"

INPUT_IMAGE="${PIXEL_BOOT_INPUT_IMAGE:-}"
HELLO_INIT_BINARY="${PIXEL_HELLO_INIT_BIN:-}"
ORANGE_INIT_BINARY="${PIXEL_ORANGE_INIT_BIN:-}"
KEY_PATH="${AVB_TEST_KEY_PATH:-}"
OUTPUT_IMAGE="${PIXEL_BOOT_ORANGE_INIT_IMAGE:-}"
HOLD_SECS="${PIXEL_HELLO_INIT_HOLD_SECS:-3}"
REBOOT_TARGET="${PIXEL_HELLO_INIT_REBOOT_TARGET:-bootloader}"
KEEP_WORK_DIR=0
WORK_DIR=""
CONFIG_ENTRY="shadow-init.cfg"
PAYLOAD_ENTRY="orange-init"

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_build_orange_init.sh [--input PATH] [--init PATH]
                                                     [--orange-init PATH] [--key PATH]
                                                     [--output PATH] [--hold-secs N]
                                                     [--reboot-target TARGET]
                                                     [--keep-work-dir]

Build a private stock-kernel sunfish boot.img whose real first-stage userspace is
hello-init PID 1 at system/bin/init and whose ramdisk contains /orange-init.
EOF
}

default_output_image() {
  printf '%s/shadow-boot-orange-init.img\n' "$(pixel_boot_dir)"
}

default_hello_init_binary() {
  printf '%s\n' "${PIXEL_HELLO_INIT_DEFAULT_BIN:-$(pixel_boot_dir)/hello-init}"
}

default_orange_init_binary() {
  printf '%s\n' "${PIXEL_ORANGE_INIT_DEFAULT_BIN:-$(pixel_boot_dir)/orange-init}"
}

assert_input_matches_stock_boot() {
  local stock_image
  stock_image="$(pixel_resolve_stock_boot_img)"

  if ! cmp -s "$INPUT_IMAGE" "$stock_image"; then
    cat <<EOF >&2
pixel_boot_build_orange_init: input image must match the cached stock boot image exactly

Input image: $INPUT_IMAGE
Stock image: $stock_image
EOF
    exit 1
  fi
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
        "pixel_boot_build_orange_init: missing root init entry in ramdisk"
    )
if not stat.S_ISLNK(init_entry.mode):
    raise SystemExit(
        "pixel_boot_build_orange_init: expected stock root /init symlink to "
        "/system/bin/init, found non-symlink entry"
    )

target = init_entry.data.decode("utf-8", errors="surrogateescape")
if target != "/system/bin/init":
    raise SystemExit(
        "pixel_boot_build_orange_init: expected stock root /init symlink target "
        f"/system/bin/init, found {target!r}"
    )

system_init_entry = entries.get("system/bin/init")
if system_init_entry is None:
    raise SystemExit(
        "pixel_boot_build_orange_init: missing system/bin/init entry in ramdisk"
    )
if stat.S_ISLNK(system_init_entry.mode):
    raise SystemExit(
        "pixel_boot_build_orange_init: expected stock system/bin/init to be a "
        "regular file, found a symlink"
    )
PY
}

assert_binary_sentinel() {
  local binary_path sentinel message
  binary_path="${1:?assert_binary_sentinel requires a binary path}"
  sentinel="${2:?assert_binary_sentinel requires a sentinel}"
  message="${3:?assert_binary_sentinel requires a message}"

  if ! grep -aFq -- "$sentinel" "$binary_path"; then
    echo "pixel_boot_build_orange_init: $message" >&2
    exit 1
  fi
}

assert_hello_variant() {
  local binary_path file_output
  binary_path="${1:?assert_hello_variant requires a binary path}"

  file_output="$(file "$binary_path")"
  if [[ "$file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_boot_build_orange_init: expected an arm64 hello-init binary, got: $file_output" >&2
    exit 1
  fi
  if [[ "$file_output" == *"dynamically linked"* ]]; then
    echo "pixel_boot_build_orange_init: expected a static hello-init binary, got a dynamic one: $file_output" >&2
    exit 1
  fi

  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-role:hello-init' \
    "binary is missing the hello-init role sentinel"
  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-impl:c-static' \
    "binary is missing the static hello-init implementation sentinel"
  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-config:/shadow-init.cfg' \
    "binary is missing the expected config-path sentinel"
}

assert_orange_variant() {
  local binary_path file_output
  binary_path="${1:?assert_orange_variant requires a binary path}"

  file_output="$(file "$binary_path")"
  if [[ "$file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_boot_build_orange_init: expected an arm64 orange-init binary, got: $file_output" >&2
    exit 1
  fi
  if [[ "$file_output" == *"dynamically linked"* ]]; then
    echo "pixel_boot_build_orange_init: expected a static orange-init binary, got a dynamic one: $file_output" >&2
    exit 1
  fi

  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-role:orange-init' \
    "binary is missing the orange-init role sentinel"
  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-impl:drm-rect-device' \
    "binary is missing the drm-rect-device implementation sentinel"
  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-path:/orange-init' \
    "binary is missing the orange-init payload-path sentinel"
}

assert_safe_word() {
  local label value max_length
  label="${1:?assert_safe_word requires a label}"
  value="${2:?assert_safe_word requires a value}"
  max_length="${3:?assert_safe_word requires a max length}"

  if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "pixel_boot_build_orange_init: unsupported $label value: $value" >&2
    exit 1
  fi
  if ((${#value} > max_length)); then
    echo "pixel_boot_build_orange_init: $label value exceeds max length $max_length: $value" >&2
    exit 1
  fi
}

render_config() {
  local output_path
  output_path="${1:?render_config requires an output path}"

  cat >"$output_path" <<EOF
# Generated by pixel_boot_build_orange_init.sh
payload=orange-init
hold_seconds=$HOLD_SECS
reboot_target=$REBOOT_TARGET
EOF
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
    --init)
      HELLO_INIT_BINARY="${2:?missing value for --init}"
      shift 2
      ;;
    --orange-init)
      ORANGE_INIT_BINARY="${2:?missing value for --orange-init}"
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
    --hold-secs)
      HOLD_SECS="${2:?missing value for --hold-secs}"
      shift 2
      ;;
    --reboot-target)
      REBOOT_TARGET="${2:?missing value for --reboot-target}"
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
      echo "pixel_boot_build_orange_init: unknown argument: $1" >&2
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
pixel_boot_build_orange_init: input image not found: $INPUT_IMAGE

Run 'sc root-prep' first to cache the stock sunfish boot.img.
EOF
  exit 1
}

if [[ ! "$HOLD_SECS" =~ ^[0-9]+$ ]]; then
  echo "pixel_boot_build_orange_init: hold seconds must be an integer: $HOLD_SECS" >&2
  exit 1
fi
if (( HOLD_SECS > 3600 )); then
  echo "pixel_boot_build_orange_init: hold seconds must be <= 3600: $HOLD_SECS" >&2
  exit 1
fi
assert_safe_word reboot-target "$REBOOT_TARGET" 31

if [[ -z "$KEY_PATH" ]]; then
  KEY_PATH="$(ensure_cached_avb_testkey)"
fi

pixel_prepare_dirs
if [[ -z "$OUTPUT_IMAGE" ]]; then
  OUTPUT_IMAGE="$(default_output_image)"
fi
mkdir -p "$(dirname "$OUTPUT_IMAGE")"
WORK_DIR="$(bootimg_prepare_work_dir shadow-pixel-boot-orange-init)"
assert_input_matches_stock_boot
assert_stock_root_init_shape

if [[ -z "$HELLO_INIT_BINARY" ]]; then
  HELLO_INIT_BINARY="$(default_hello_init_binary)"
  "$SCRIPT_DIR/pixel/pixel_build_hello_init.sh" --output "$HELLO_INIT_BINARY"
fi

[[ -f "$HELLO_INIT_BINARY" ]] || {
  echo "pixel_boot_build_orange_init: hello-init binary not found: $HELLO_INIT_BINARY" >&2
  exit 1
}

if [[ -z "$ORANGE_INIT_BINARY" ]]; then
  ORANGE_INIT_BINARY="$(default_orange_init_binary)"
  "$SCRIPT_DIR/pixel/pixel_build_orange_init.sh" --output "$ORANGE_INIT_BINARY"
fi

[[ -f "$ORANGE_INIT_BINARY" ]] || {
  echo "pixel_boot_build_orange_init: orange-init binary not found: $ORANGE_INIT_BINARY" >&2
  exit 1
}

assert_hello_variant "$HELLO_INIT_BINARY"
assert_orange_variant "$ORANGE_INIT_BINARY"

CONFIG_PATH="$WORK_DIR/$CONFIG_ENTRY"
render_config "$CONFIG_PATH"

build_args=(
  --stock-init
  --input "$INPUT_IMAGE"
  --key "$KEY_PATH"
  --output "$OUTPUT_IMAGE"
  --replace "system/bin/init=$HELLO_INIT_BINARY"
  --add "$CONFIG_ENTRY=$CONFIG_PATH"
  --add "$PAYLOAD_ENTRY=$ORANGE_INIT_BINARY"
)

if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  build_args+=(--keep-work-dir)
fi

"$SCRIPT_DIR/pixel/pixel_boot_build.sh" "${build_args[@]}"

printf 'Owned userspace mode: orange-init\n'
printf 'Root init path: preserve stock /init -> /system/bin/init symlink\n'
printf 'System init mutation: replace system/bin/init with hello-init PID 1\n'
printf 'Payload contract: hello-init executes /orange-init when payload=orange-init\n'
printf 'Payload path: /%s\n' "$PAYLOAD_ENTRY"
printf 'Config path: /%s\n' "$CONFIG_ENTRY"
printf 'Hold seconds: %s\n' "$HOLD_SECS"
printf 'Reboot target: %s\n' "$REBOOT_TARGET"
if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  printf 'Kept orange-init workdir: %s\n' "$WORK_DIR"
fi
