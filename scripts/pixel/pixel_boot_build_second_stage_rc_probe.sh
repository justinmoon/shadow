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
OUTPUT_IMAGE="${PIXEL_BOOT_SECOND_STAGE_RC_PROBE_IMAGE:-}"
TRIGGER="${PIXEL_BOOT_SECOND_STAGE_RC_PROBE_TRIGGER:-property:sys.boot_completed=1}"
PROPERTY_ASSIGNMENT="${PIXEL_BOOT_SECOND_STAGE_RC_PROBE_PROPERTY:-debug.shadow.boot.second_stage_rc_probe=ready}"
KEEP_WORK_DIR=0
WORK_DIR=""
PROPERTY_KEY=""
PROPERTY_VALUE=""
PRIMARY_RC_PATH="/system/etc/init/hw/init.rc"
SECOND_STAGE_RC_PATH="/second_stage_resources/.rc"

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_build_second_stage_rc_probe.sh [--input PATH] [--key PATH] [--output PATH]
                                                              [--trigger EXPR] [--property KEY=VALUE]
                                                              [--keep-work-dir]

Build a private stock-init sunfish boot.img that leaves stock /init and system/bin/init
in place, but retargets the primary second-stage init rc path to
/second_stage_resources/.rc so a tiny trampoline file can prove second-stage control
before importing the stock /system/etc/init/hw/init.rc.
EOF
}

default_output_image() {
  printf '%s/shadow-boot-second-stage-rc-probe.img\n' "$(pixel_boot_dir)"
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

validate_literal_trigger() {
  [[ "$TRIGGER" =~ ^[A-Za-z0-9._:+=/@-]+$ ]] || {
    echo "pixel_boot_build_second_stage_rc_probe: --trigger only accepts a single literal init trigger token" >&2
    exit 1
  }
}

parse_property_assignment() {
  [[ "$PROPERTY_ASSIGNMENT" == *=* ]] || {
    echo "pixel_boot_build_second_stage_rc_probe: --property must use KEY=VALUE" >&2
    exit 1
  }

  PROPERTY_KEY="${PROPERTY_ASSIGNMENT%%=*}"
  PROPERTY_VALUE="${PROPERTY_ASSIGNMENT#*=}"

  [[ -n "$PROPERTY_KEY" && -n "$PROPERTY_VALUE" ]] || {
    echo "pixel_boot_build_second_stage_rc_probe: --property requires a non-empty key and value" >&2
    exit 1
  }
}

validate_property_assignment() {
  parse_property_assignment

  [[ "$PROPERTY_KEY" =~ ^[A-Za-z0-9_.-]+$ ]] || {
    echo "pixel_boot_build_second_stage_rc_probe: --property key contains unsupported characters" >&2
    exit 1
  }

  [[ "$PROPERTY_VALUE" =~ ^[A-Za-z0-9._:/+=,@-]+$ ]] || {
    echo "pixel_boot_build_second_stage_rc_probe: --property value contains unsupported characters" >&2
    exit 1
  }
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
        "pixel_boot_build_second_stage_rc_probe: missing root init entry in ramdisk"
    )
if not stat.S_ISLNK(init_entry.mode):
    raise SystemExit(
        "pixel_boot_build_second_stage_rc_probe: expected stock root /init "
        "symlink to /system/bin/init, found non-symlink entry"
    )

target = init_entry.data.decode("utf-8", errors="surrogateescape")
if target != "/system/bin/init":
    raise SystemExit(
        "pixel_boot_build_second_stage_rc_probe: expected stock root /init "
        f"symlink target /system/bin/init, found {target!r}"
    )

system_init_entry = entries.get("system/bin/init")
if system_init_entry is None:
    raise SystemExit(
        "pixel_boot_build_second_stage_rc_probe: missing system/bin/init entry in ramdisk"
    )
if stat.S_ISLNK(system_init_entry.mode):
    raise SystemExit(
        "pixel_boot_build_second_stage_rc_probe: expected stock system/bin/init "
        "to be a regular file, found a symlink"
    )
PY
}

patch_system_init_binary() {
  local input_binary output_binary
  input_binary="${1:?patch_system_init_binary requires an input path}"
  output_binary="${2:?patch_system_init_binary requires an output path}"

  python3 - "$input_binary" "$output_binary" "$PRIMARY_RC_PATH" "$SECOND_STAGE_RC_PATH" <<'PY'
from pathlib import Path
import sys

input_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
needle = sys.argv[3].encode("utf-8")
replacement = sys.argv[4].encode("utf-8")

if len(replacement) > len(needle):
    raise SystemExit(
        "pixel_boot_build_second_stage_rc_probe: replacement rc path is longer than the stock path"
    )

blob = input_path.read_bytes()
offsets = []
start = 0
while True:
    index = blob.find(needle, start)
    if index < 0:
        break
    offsets.append(index)
    start = index + 1

if not offsets:
    raise SystemExit(
        "pixel_boot_build_second_stage_rc_probe: stock system/bin/init did not contain the primary rc path"
    )
if len(offsets) != 1:
    raise SystemExit(
        "pixel_boot_build_second_stage_rc_probe: expected exactly one primary rc path in stock system/bin/init"
    )

patched = replacement + (b"\x00" * (len(needle) - len(replacement)))
offset = offsets[0]
blob = blob[:offset] + patched + blob[offset + len(needle) :]
output_path.write_bytes(blob)
PY
}

ramdisk_has_entry() {
  local ramdisk_cpio entry_name
  ramdisk_cpio="${1:?ramdisk_has_entry requires a cpio path}"
  entry_name="${2:?ramdisk_has_entry requires an entry name}"

  python3 - "$ramdisk_cpio" "$entry_name" "$SCRIPT_DIR/lib" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, sys.argv[3])
from cpio_edit import read_cpio

archive = read_cpio(Path(sys.argv[1]))
entry_name = sys.argv[2]

for entry in archive.without_trailer():
    if entry.name == entry_name:
        print("present")
        raise SystemExit(0)

raise SystemExit(1)
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
    --trigger)
      TRIGGER="${2:?missing value for --trigger}"
      shift 2
      ;;
    --property)
      PROPERTY_ASSIGNMENT="${2:?missing value for --property}"
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
      echo "pixel_boot_build_second_stage_rc_probe: unknown argument: $1" >&2
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
pixel_boot_build_second_stage_rc_probe: input image not found: $INPUT_IMAGE

Run 'sc root-prep' first to cache the stock sunfish boot.img.
EOF
  exit 1
}

validate_literal_trigger
validate_property_assignment

if [[ -z "$KEY_PATH" ]]; then
  KEY_PATH="$(ensure_cached_avb_testkey)"
fi

pixel_prepare_dirs
if [[ -z "$OUTPUT_IMAGE" ]]; then
  OUTPUT_IMAGE="$(default_output_image)"
fi
mkdir -p "$(dirname "$OUTPUT_IMAGE")"
WORK_DIR="$(bootimg_prepare_work_dir shadow-pixel-boot-second-stage-rc-probe)"
assert_stock_root_init_shape

python3 "$SCRIPT_DIR/lib/cpio_edit.py" \
  --input "$WORK_DIR/input-ramdisk.cpio" \
  --extract "system/bin/init=$WORK_DIR/system-bin-init.stock"

patch_system_init_binary "$WORK_DIR/system-bin-init.stock" "$WORK_DIR/system-bin-init.patched"
chmod 0755 "$WORK_DIR/system-bin-init.patched"

mkdir -p "$WORK_DIR/second_stage_resources"
cat >"$WORK_DIR/second_stage_resources/.rc" <<EOF
import ${PRIMARY_RC_PATH}

on ${TRIGGER}
    setprop ${PROPERTY_KEY} ${PROPERTY_VALUE}
EOF
chmod 0644 "$WORK_DIR/second_stage_resources/.rc"

build_args=(
  --stock-init
  --input "$INPUT_IMAGE"
  --key "$KEY_PATH"
  --output "$OUTPUT_IMAGE"
  --replace "system/bin/init=$WORK_DIR/system-bin-init.patched"
  --add "second_stage_resources/.rc=$WORK_DIR/second_stage_resources/.rc"
)

if ! ramdisk_has_entry "$WORK_DIR/input-ramdisk.cpio" "second_stage_resources" >/dev/null; then
  build_args+=(--add "second_stage_resources=$WORK_DIR/second_stage_resources")
fi

if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  build_args+=(--keep-work-dir)
fi

"$SCRIPT_DIR/pixel/pixel_boot_build.sh" "${build_args[@]}"

printf 'Probe mode: second-stage-rc\n'
printf 'Primary rc path mutation: %s -> %s\n' "$PRIMARY_RC_PATH" "$SECOND_STAGE_RC_PATH"
printf 'Trigger: %s\n' "$TRIGGER"
printf 'Property: %s=%s\n' "$PROPERTY_KEY" "$PROPERTY_VALUE"
if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  printf 'Kept probe workdir: %s\n' "$WORK_DIR"
fi
