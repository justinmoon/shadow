#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./bootimg_common.sh
source "$SCRIPT_DIR/lib/bootimg_common.sh"
ensure_bootimg_shell "$@"

INPUT_IMAGE="${PIXEL_BOOT_INPUT_IMAGE:-}"
KEY_PATH="${AVB_TEST_KEY_PATH:-}"
OUTPUT_IMAGE="${PIXEL_BOOT_RAMDISK_PROP_PROBE_IMAGE:-}"
KEEP_WORK_DIR=0
WORK_DIR=""
RAMDISK_PROP_ENTRY="system/etc/ramdisk/build.prop"
declare -a PROPERTY_ASSIGNMENTS=()

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_build_ramdisk_prop_probe.sh [--input PATH] [--key PATH]
                                                            [--output PATH] [--property KEY=VALUE]...
                                                            [--keep-work-dir]

Build a private stock-init sunfish boot.img that appends one or more properties to the
preserved boot-image ramdisk build.prop path (`/system/etc/ramdisk/build.prop`).
On Android 13+ this file is copied into `/second_stage_resources/system/etc/ramdisk/build.prop`
and loaded by second-stage property init.
EOF
}

default_output_image() {
  printf '%s/shadow-boot-ramdisk-prop-probe.img\n' "$(pixel_boot_dir)"
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

validate_property_assignment() {
  local assignment property_key property_value
  assignment="${1:?validate_property_assignment requires an assignment}"

  [[ "$assignment" == *=* ]] || {
    echo "pixel_boot_build_ramdisk_prop_probe: --property must use KEY=VALUE" >&2
    exit 1
  }

  property_key="${assignment%%=*}"
  property_value="${assignment#*=}"

  [[ -n "$property_key" && -n "$property_value" ]] || {
    echo "pixel_boot_build_ramdisk_prop_probe: --property requires a non-empty key and value" >&2
    exit 1
  }

  [[ "$property_key" =~ ^[A-Za-z0-9_.-]+$ ]] || {
    echo "pixel_boot_build_ramdisk_prop_probe: --property key contains unsupported characters" >&2
    exit 1
  }

  [[ "$property_value" =~ ^[A-Za-z0-9._:/+=,@-]+$ ]] || {
    echo "pixel_boot_build_ramdisk_prop_probe: --property value contains unsupported characters" >&2
    exit 1
  }
}

append_probe_properties() {
  local input_path output_path
  input_path="${1:?append_probe_properties requires an input path}"
  output_path="${2:?append_probe_properties requires an output path}"
  shift 2

  python3 - "$input_path" "$output_path" "$@" <<'PY'
from pathlib import Path
import sys

input_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
assignments = sys.argv[3:]

payload = input_path.read_text(encoding="utf-8")
if payload and not payload.endswith("\n"):
    payload += "\n"

for assignment in assignments:
    property_key, property_value = assignment.split("=", 1)
    payload += f"{property_key}={property_value}\n"

output_path.write_text(payload, encoding="utf-8")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      INPUT_IMAGE="${2:?missing value for --input}"
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
    --property)
      PROPERTY_ASSIGNMENTS+=("${2:?missing value for --property}")
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
      echo "pixel_boot_build_ramdisk_prop_probe: unknown argument: $1" >&2
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
pixel_boot_build_ramdisk_prop_probe: input image not found: $INPUT_IMAGE

Run 'sc root-prep' first to cache the stock sunfish boot.img.
EOF
  exit 1
}

if ((${#PROPERTY_ASSIGNMENTS[@]} == 0)); then
  PROPERTY_ASSIGNMENTS=("debug.shadow.boot.ramdisk_prop_probe=ready")
fi

for assignment in "${PROPERTY_ASSIGNMENTS[@]}"; do
  validate_property_assignment "$assignment"
done

if [[ -z "$KEY_PATH" ]]; then
  KEY_PATH="$(ensure_cached_avb_testkey)"
fi

pixel_prepare_dirs
if [[ -z "$OUTPUT_IMAGE" ]]; then
  OUTPUT_IMAGE="$(default_output_image)"
fi
mkdir -p "$(dirname "$OUTPUT_IMAGE")"
WORK_DIR="$(bootimg_prepare_work_dir shadow-pixel-boot-ramdisk-prop-probe)"

bootimg_unpack_to_dir "$INPUT_IMAGE" "$WORK_DIR/unpacked"
bootimg_decompress_ramdisk "$WORK_DIR/unpacked/out/ramdisk" "$WORK_DIR/ramdisk.cpio" >/dev/null

python3 "$SCRIPT_DIR/lib/cpio_edit.py" \
  --input "$WORK_DIR/ramdisk.cpio" \
  --extract "$RAMDISK_PROP_ENTRY=$WORK_DIR/build.prop.stock"

append_probe_properties \
  "$WORK_DIR/build.prop.stock" \
  "$WORK_DIR/build.prop.modified" \
  "${PROPERTY_ASSIGNMENTS[@]}"

build_args=(
  --stock-init
  --input "$INPUT_IMAGE"
  --key "$KEY_PATH"
  --output "$OUTPUT_IMAGE"
  --replace "$RAMDISK_PROP_ENTRY=$WORK_DIR/build.prop.modified"
)

if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  build_args+=(--keep-work-dir)
fi

"$SCRIPT_DIR/pixel/pixel_boot_build.sh" "${build_args[@]}"

printf 'Probe mode: ramdisk-build-prop\n'
printf 'Ramdisk property entry: %s\n' "$RAMDISK_PROP_ENTRY"
for assignment in "${PROPERTY_ASSIGNMENTS[@]}"; do
  printf 'Property: %s\n' "$assignment"
done
if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  printf 'Kept probe workdir: %s\n' "$WORK_DIR"
fi
