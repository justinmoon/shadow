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
OUTPUT_IMAGE="${PIXEL_BOOT_RC_PROBE_IMAGE:-}"
TRIGGER="${PIXEL_BOOT_RC_PROBE_TRIGGER:-post-fs-data}"
PROPERTY_ASSIGNMENT="${PIXEL_BOOT_RC_PROBE_PROPERTY:-shadow.boot.rc_probe=ready}"
PATCH_TARGET_OVERRIDE="${PIXEL_BOOT_RC_PROBE_PATCH_TARGET:-}"
KEEP_WORK_DIR=0
WORK_DIR=""
PATCH_TARGET=""
PROPERTY_KEY=""
PROPERTY_VALUE=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_build_rc_probe.sh [--input PATH] [--key PATH] [--output PATH]
                                                  [--trigger EXPR] [--property KEY=VALUE]
                                                  [--patch-target ENTRY]
                                                  [--stock-init]
                                                  [--keep-work-dir]

Build a private stock-init sunfish boot.img that imports /init.shadow.rc and only sets one property.
EOF
}

default_output_image() {
  printf '%s/shadow-boot-rc-probe-stock-init.img\n' "$(pixel_boot_dir)"
}

validate_literal_trigger() {
  [[ "$TRIGGER" =~ ^[A-Za-z0-9._:+=/@-]+$ ]] || {
    echo "pixel_boot_build_rc_probe: --trigger only accepts a single literal init trigger token" >&2
    exit 1
  }
}

parse_property_assignment() {
  [[ "$PROPERTY_ASSIGNMENT" == *=* ]] || {
    echo "pixel_boot_build_rc_probe: --property must use KEY=VALUE" >&2
    exit 1
  }

  PROPERTY_KEY="${PROPERTY_ASSIGNMENT%%=*}"
  PROPERTY_VALUE="${PROPERTY_ASSIGNMENT#*=}"

  [[ -n "$PROPERTY_KEY" && -n "$PROPERTY_VALUE" ]] || {
    echo "pixel_boot_build_rc_probe: --property requires a non-empty key and value" >&2
    exit 1
  }
}

validate_property_assignment() {
  parse_property_assignment

  [[ "$PROPERTY_KEY" =~ ^[A-Za-z0-9_.-]+$ ]] || {
    echo "pixel_boot_build_rc_probe: --property key contains unsupported characters" >&2
    exit 1
  }

  [[ "$PROPERTY_VALUE" =~ ^[A-Za-z0-9._:/+=,@-]+$ ]] || {
    echo "pixel_boot_build_rc_probe: --property value contains unsupported characters" >&2
    exit 1
  }
}

validate_patch_target_override() {
  [[ -z "$PATCH_TARGET_OVERRIDE" ]] && return 0
  [[ "$PATCH_TARGET_OVERRIDE" =~ ^[A-Za-z0-9._/-]+$ ]] || {
    echo "pixel_boot_build_rc_probe: --patch-target contains unsupported characters" >&2
    exit 1
  }
}

detect_patch_target() {
  local ramdisk_cpio explicit_target
  ramdisk_cpio="${1:?detect_patch_target requires a ramdisk path}"
  explicit_target="${2:-}"

  python3 - "$ramdisk_cpio" "$explicit_target" "$SCRIPT_DIR/lib" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, sys.argv[3])
from cpio_edit import read_cpio

archive = read_cpio(Path(sys.argv[1]))
entries = {entry.name for entry in archive.without_trailer()}
explicit_target = sys.argv[2]

if explicit_target:
    if explicit_target not in entries:
        print(
            f"pixel_boot_build_rc_probe: requested --patch-target entry not present in ramdisk: {explicit_target}",
            file=sys.stderr,
        )
        sys.exit(1)
    print(explicit_target)
    sys.exit(0)

hardware_recovery_targets = sorted(
    name
    for name in entries
    if name.startswith("init.recovery.") and name.endswith(".rc") and name != "init.recovery.rc"
)
if len(hardware_recovery_targets) == 1:
    print(hardware_recovery_targets[0])
    sys.exit(0)
if len(hardware_recovery_targets) > 1:
    print(
        "pixel_boot_build_rc_probe: multiple root recovery rc anchors found; pass --patch-target explicitly",
        file=sys.stderr,
    )
    for target in hardware_recovery_targets:
        print(f"  {target}", file=sys.stderr)
    sys.exit(1)

if "init.recovery.rc" in entries:
    print("init.recovery.rc")
    sys.exit(0)

fallback_target = "system/etc/init/hw/init.rc"
if fallback_target in entries:
    print(fallback_target)
    sys.exit(0)

print(
    "pixel_boot_build_rc_probe: no supported rc import anchor found in ramdisk",
    file=sys.stderr,
)
sys.exit(1)
PY
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
    --patch-target)
      PATCH_TARGET_OVERRIDE="${2:?missing value for --patch-target}"
      shift 2
      ;;
    --stock-init)
      shift
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
      echo "pixel_boot_build_rc_probe: unknown argument: $1" >&2
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
pixel_boot_build_rc_probe: input image not found: $INPUT_IMAGE

Run 'sc root-prep' first to cache the stock sunfish boot.img.
EOF
  exit 1
}

validate_literal_trigger
validate_property_assignment
validate_patch_target_override

pixel_prepare_dirs
if [[ -z "$OUTPUT_IMAGE" ]]; then
  OUTPUT_IMAGE="$(default_output_image)"
fi
mkdir -p "$(dirname "$OUTPUT_IMAGE")"
WORK_DIR="$(bootimg_prepare_work_dir shadow-pixel-boot-rc-probe)"

bootimg_unpack_to_dir "$INPUT_IMAGE" "$WORK_DIR/unpacked"
bootimg_decompress_ramdisk "$WORK_DIR/unpacked/out/ramdisk" "$WORK_DIR/ramdisk.cpio" >/dev/null
PATCH_TARGET="$(detect_patch_target "$WORK_DIR/ramdisk.cpio" "$PATCH_TARGET_OVERRIDE")"

python3 "$SCRIPT_DIR/lib/cpio_edit.py" \
  --input "$WORK_DIR/ramdisk.cpio" \
  --extract "$PATCH_TARGET=$WORK_DIR/patch-target.stock"

if grep -Fxq 'import /init.shadow.rc' "$WORK_DIR/patch-target.stock"; then
  cp "$WORK_DIR/patch-target.stock" "$WORK_DIR/patch-target.patched"
else
  {
    printf 'import /init.shadow.rc\n\n'
    cat "$WORK_DIR/patch-target.stock"
  } >"$WORK_DIR/patch-target.patched"
fi
chmod 0644 "$WORK_DIR/patch-target.patched"

cat >"$WORK_DIR/init.shadow.rc" <<EOF
on ${TRIGGER}
    setprop ${PROPERTY_KEY} ${PROPERTY_VALUE}
EOF
chmod 0644 "$WORK_DIR/init.shadow.rc"

if [[ -z "$KEY_PATH" ]]; then
  KEY_PATH="$(ensure_cached_avb_testkey)"
fi

"$SCRIPT_DIR/pixel/pixel_boot_build.sh" \
  --stock-init \
  --input "$INPUT_IMAGE" \
  --key "$KEY_PATH" \
  --output "$OUTPUT_IMAGE" \
  --add "init.shadow.rc=$WORK_DIR/init.shadow.rc" \
  --replace "$PATCH_TARGET=$WORK_DIR/patch-target.patched"

printf 'Patch target: %s\n' "$PATCH_TARGET"
printf 'Trigger: %s\n' "$TRIGGER"
printf 'Property: %s=%s\n' "$PROPERTY_KEY" "$PROPERTY_VALUE"
if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  printf 'Kept workdir: %s\n' "$WORK_DIR"
fi
