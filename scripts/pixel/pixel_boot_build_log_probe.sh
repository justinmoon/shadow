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
OUTPUT_IMAGE="${PIXEL_BOOT_LOG_PROBE_IMAGE:-$(pixel_boot_log_probe_img)}"
TRIGGER="${PIXEL_BOOT_LOG_PROBE_TRIGGER:-post-fs-data}"
DEVICE_LOG_ROOT="$(pixel_boot_device_log_root)"
PATCH_TARGET_OVERRIDE="${PIXEL_BOOT_LOG_PROBE_PATCH_TARGET:-}"
KEEP_WORK_DIR=0
WORK_DIR=""
PATCH_TARGET=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_build_log_probe.sh [--input PATH] [--wrapper PATH] [--key PATH]
                                                   [--output PATH] [--trigger EXPR]
                                                   [--device-log-root PATH] [--patch-target ENTRY]
                                                   [--keep-work-dir]

Build a private sunfish boot.img that imports /init.shadow.rc and runs a boot helper that only emits log markers.
EOF
}

validate_literal_trigger() {
  [[ "$TRIGGER" =~ ^[A-Za-z0-9._:+=/@-]+$ ]] || {
    echo "pixel_boot_build_log_probe: --trigger only accepts a single literal init trigger token" >&2
    exit 1
  }
}

validate_device_log_root() {
  [[ "$DEVICE_LOG_ROOT" == /* ]] || {
    echo "pixel_boot_build_log_probe: --device-log-root must be an absolute path" >&2
    exit 1
  }
  [[ "$DEVICE_LOG_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || {
    echo "pixel_boot_build_log_probe: --device-log-root contains unsupported characters" >&2
    exit 1
  }
}

validate_patch_target_override() {
  [[ -z "$PATCH_TARGET_OVERRIDE" ]] && return 0
  [[ "$PATCH_TARGET_OVERRIDE" =~ ^[A-Za-z0-9._/-]+$ ]] || {
    echo "pixel_boot_build_log_probe: --patch-target contains unsupported characters" >&2
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
            f"pixel_boot_build_log_probe: requested --patch-target entry not present in ramdisk: {explicit_target}",
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
        "pixel_boot_build_log_probe: multiple root recovery rc anchors found; pass --patch-target explicitly",
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
    "pixel_boot_build_log_probe: no supported rc import anchor found in ramdisk",
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
    --trigger)
      TRIGGER="${2:?missing value for --trigger}"
      shift 2
      ;;
    --device-log-root)
      DEVICE_LOG_ROOT="${2:?missing value for --device-log-root}"
      shift 2
      ;;
    --patch-target)
      PATCH_TARGET_OVERRIDE="${2:?missing value for --patch-target}"
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
      echo "pixel_boot_build_log_probe: unknown argument: $1" >&2
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
pixel_boot_build_log_probe: input image not found: $INPUT_IMAGE

Run 'sc root-prep' first to cache the stock sunfish boot.img.
EOF
  exit 1
}

validate_literal_trigger
validate_device_log_root
validate_patch_target_override

pixel_prepare_dirs
mkdir -p "$(dirname "$OUTPUT_IMAGE")"
WORK_DIR="$(bootimg_prepare_work_dir shadow-pixel-boot-log-probe)"

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
    start shadow-boot-helper

service shadow-boot-helper /system/bin/sh /shadow-boot-helper
    class late_start
    user root
    group root system shell log
    seclabel u:r:init:s0
    disabled
    oneshot
EOF
chmod 0644 "$WORK_DIR/init.shadow.rc"

cat >"$WORK_DIR/shadow-boot-helper" <<EOF
#!/system/bin/sh
set -eu

log_root="${DEVICE_LOG_ROOT}"
log_file="\$log_root/helper.log"

timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown-time
}

log_line() {
  message="\$1"
  printf '%s [shadow-boot] %s\n' "\$(timestamp)" "\$message" >>"\$log_file"
  printf '<6>[shadow-boot] %s\n' "\$message" >/dev/kmsg 2>/dev/null || true
}

capture_output() {
  output_path="\$1"
  shift
  if "\$@" >"\$output_path" 2>/dev/null; then
    chmod 0644 "\$output_path" 2>/dev/null || true
    return 0
  fi
  return 1
}

rm -rf "\$log_root"
mkdir -p "\$log_root"
chown shell:shell "\$log_root" 2>/dev/null || true
chmod 0775 "\$log_root" 2>/dev/null || true
: >"\$log_file"
chmod 0644 "\$log_file" 2>/dev/null || true

setprop shadow.boot.log_probe starting || true
log_line "helper starting"

boot_id="\$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
slot_suffix="\$(getprop ro.boot.slot_suffix | tr -d '\r')"
printf '%s\n' "\$boot_id" >"\$log_root/boot-id.txt"
chmod 0644 "\$log_root/boot-id.txt" 2>/dev/null || true
printf '%s\n' "\$slot_suffix" >"\$log_root/slot-suffix.txt"
chmod 0644 "\$log_root/slot-suffix.txt" 2>/dev/null || true

capture_output "\$log_root/getprop.txt" getprop || true
capture_output "\$log_root/ps.txt" ps -A -o USER,PID,PPID,NAME,ARGS || capture_output "\$log_root/ps.txt" ps -A || true
capture_output "\$log_root/logcat-kernel.txt" logcat -b kernel -d || true
capture_output "\$log_root/logcat-shadow.txt" logcat -d -s shadow-init:I shadow-boot:I || true

{
  printf 'trigger=%s\n' "${TRIGGER}"
  printf 'device_log_root=%s\n' "${DEVICE_LOG_ROOT}"
  printf 'patch_target=%s\n' "${PATCH_TARGET}"
  printf 'boot_id=%s\n' "\$boot_id"
  printf 'slot_suffix=%s\n' "\$slot_suffix"
  printf 'bootmode=%s\n' "\$(getprop ro.bootmode | tr -d '\r')"
  printf 'verifiedbootstate=%s\n' "\$(getprop ro.boot.verifiedbootstate | tr -d '\r')"
  printf 'surfaceflinger=%s\n' "\$(getprop init.svc.surfaceflinger | tr -d '\r')"
  printf 'bootanim=%s\n' "\$(getprop init.svc.bootanim | tr -d '\r')"
  printf 'vendor_hwcomposer_2_4=%s\n' "\$(getprop init.svc.vendor.hwcomposer-2-4 | tr -d '\r')"
  printf 'display_allocator=%s\n' "\$(getprop init.svc.vendor.qti.hardware.display.allocator | tr -d '\r')"
} >"\$log_root/service-states.txt"
chmod 0644 "\$log_root/service-states.txt" 2>/dev/null || true

printf 'ready\n' >"\$log_root/status.txt"
chmod 0644 "\$log_root/status.txt" 2>/dev/null || true
log_line "helper finished"
setprop shadow.boot.log_probe ready || true
EOF
chmod 0755 "$WORK_DIR/shadow-boot-helper"

build_args=(
  --input "$INPUT_IMAGE"
  --wrapper "$WRAPPER_BINARY"
  --output "$OUTPUT_IMAGE"
  --add "init.shadow.rc=$WORK_DIR/init.shadow.rc"
  --add "shadow-boot-helper=$WORK_DIR/shadow-boot-helper"
  --replace "$PATCH_TARGET=$WORK_DIR/patch-target.patched"
)

if [[ -n "$KEY_PATH" ]]; then
  build_args+=(--key "$KEY_PATH")
fi

"$SCRIPT_DIR/pixel/pixel_boot_build.sh" "${build_args[@]}"

printf 'Wrote log-probe boot image: %s\n' "$OUTPUT_IMAGE"
printf 'Trigger: %s\n' "$TRIGGER"
printf 'Device log root: %s\n' "$DEVICE_LOG_ROOT"
printf 'Patch target: %s\n' "$PATCH_TARGET"
if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  printf 'Kept payload workdir: %s\n' "$WORK_DIR"
fi

cat <<EOF
Next steps:
  inspect: scripts/pixel/pixel_boot_unpack.sh --input "$OUTPUT_IMAGE"
  stage on the other slot without booting it:
           PIXEL_SERIAL=<serial> scripts/pixel/pixel_boot_flash.sh --experimental --slot inactive --image "$OUTPUT_IMAGE"
  intentionally boot the probe from the other slot:
           PIXEL_SERIAL=<serial> scripts/pixel/pixel_boot_flash.sh --experimental --slot inactive --activate-target --image "$OUTPUT_IMAGE"
  collect helper logs from that probe boot:
           PIXEL_SERIAL=<serial> scripts/pixel/pixel_boot_collect_logs.sh --wait-ready 120
  recover the known-good slot afterwards:
           PIXEL_SERIAL=<serial> scripts/pixel/pixel_boot_recover.sh
EOF
