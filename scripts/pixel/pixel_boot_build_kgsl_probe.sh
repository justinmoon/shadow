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
OUTPUT_IMAGE="${PIXEL_BOOT_KGSL_PROBE_IMAGE:-}"
TRIGGER="${PIXEL_BOOT_KGSL_PROBE_TRIGGER:-post-fs-data}"
DEVICE_LOG_ROOT="$(pixel_boot_device_log_root)"
PATCH_TARGET_OVERRIDE="${PIXEL_BOOT_KGSL_PROBE_PATCH_TARGET:-}"
IMPORT_PROOF_PROP="${PIXEL_BOOT_KGSL_PROBE_IMPORT_PROOF_PROP:-debug.shadow.boot.kgsl.import=triggered}"
LAUNCH_PROOF_PROP="${PIXEL_BOOT_KGSL_PROBE_LAUNCH_PROOF_PROP:-debug.shadow.boot.kgsl.launch=started}"
RESULT_PROP_KEY="${PIXEL_BOOT_KGSL_PROBE_RESULT_PROP_KEY:-debug.shadow.boot.kgsl.result}"
HELPER_STATUS_PROP_KEY="${PIXEL_BOOT_KGSL_PROBE_HELPER_STATUS_PROP_KEY:-debug.shadow.boot.kgsl.helper}"
TIMEOUT_SECS="${PIXEL_BOOT_KGSL_PROBE_TIMEOUT_SECS:-12}"
KEEP_WORK_DIR=0
WORK_DIR=""
PATCH_TARGET=""
IMPORT_PROOF_KEY=""
IMPORT_PROOF_VALUE=""
LAUNCH_PROOF_KEY=""
LAUNCH_PROOF_VALUE=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_build_kgsl_probe.sh [--input PATH] [--key PATH] [--output PATH]
                                                    [--trigger EXPR] [--device-log-root PATH]
                                                    [--patch-target ENTRY]
                                                    [--import-proof-prop KEY=VALUE]
                                                    [--launch-proof-prop KEY=VALUE]
                                                    [--result-prop-key KEY]
                                                    [--helper-status-prop-key KEY]
                                                    [--timeout SECONDS]
                                                    [--stock-init]
                                                    [--keep-work-dir]

Build a private stock-init sunfish boot.img that imports /init.shadow.rc and runs a
boot helper which attempts a supervised readonly open of /dev/kgsl-3d0 with durable
breadcrumbs under /data/local/tmp/shadow-boot.
EOF
}

default_output_image() {
  printf '%s/shadow-boot-kgsl-probe-stock-init.img\n' "$(pixel_boot_dir)"
}

validate_literal_trigger() {
  [[ "$TRIGGER" =~ ^[A-Za-z0-9._:+=/@-]+$ ]] || {
    echo "pixel_boot_build_kgsl_probe: --trigger only accepts a single literal init trigger token" >&2
    exit 1
  }
}

validate_device_log_root() {
  [[ "$DEVICE_LOG_ROOT" == /* ]] || {
    echo "pixel_boot_build_kgsl_probe: --device-log-root must be an absolute path" >&2
    exit 1
  }
  [[ "$DEVICE_LOG_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || {
    echo "pixel_boot_build_kgsl_probe: --device-log-root contains unsupported characters" >&2
    exit 1
  }
}

validate_patch_target_override() {
  [[ -z "$PATCH_TARGET_OVERRIDE" ]] && return 0
  [[ "$PATCH_TARGET_OVERRIDE" =~ ^[A-Za-z0-9._/-]+$ ]] || {
    echo "pixel_boot_build_kgsl_probe: --patch-target contains unsupported characters" >&2
    exit 1
  }
}

validate_property_key() {
  local property_key label
  property_key="${1:?validate_property_key requires a property key}"
  label="${2:?validate_property_key requires a label}"
  [[ "$property_key" =~ ^[A-Za-z0-9_.-]+$ ]] || {
    echo "pixel_boot_build_kgsl_probe: $label contains unsupported characters: $property_key" >&2
    exit 1
  }
}

validate_property_value() {
  local property_value label
  property_value="${1:?validate_property_value requires a property value}"
  label="${2:?validate_property_value requires a label}"
  [[ "$property_value" =~ ^[A-Za-z0-9._:/+=,@-]+$ ]] || {
    echo "pixel_boot_build_kgsl_probe: $label contains unsupported characters: $property_value" >&2
    exit 1
  }
}

parse_launch_proof_prop() {
  [[ "$LAUNCH_PROOF_PROP" == *=* ]] || {
    echo "pixel_boot_build_kgsl_probe: --launch-proof-prop must use KEY=VALUE" >&2
    exit 1
  }

  LAUNCH_PROOF_KEY="${LAUNCH_PROOF_PROP%%=*}"
  LAUNCH_PROOF_VALUE="${LAUNCH_PROOF_PROP#*=}"
  [[ -n "$LAUNCH_PROOF_KEY" && -n "$LAUNCH_PROOF_VALUE" ]] || {
    echo "pixel_boot_build_kgsl_probe: --launch-proof-prop requires a non-empty key and value" >&2
    exit 1
  }

  validate_property_key "$LAUNCH_PROOF_KEY" "launch proof property key"
  validate_property_value "$LAUNCH_PROOF_VALUE" "launch proof property value"
}

parse_import_proof_prop() {
  [[ "$IMPORT_PROOF_PROP" == *=* ]] || {
    echo "pixel_boot_build_kgsl_probe: --import-proof-prop must use KEY=VALUE" >&2
    exit 1
  }

  IMPORT_PROOF_KEY="${IMPORT_PROOF_PROP%%=*}"
  IMPORT_PROOF_VALUE="${IMPORT_PROOF_PROP#*=}"
  [[ -n "$IMPORT_PROOF_KEY" && -n "$IMPORT_PROOF_VALUE" ]] || {
    echo "pixel_boot_build_kgsl_probe: --import-proof-prop requires a non-empty key and value" >&2
    exit 1
  }

  validate_property_key "$IMPORT_PROOF_KEY" "import proof property key"
  validate_property_value "$IMPORT_PROOF_VALUE" "import proof property value"
}

validate_timeout_secs() {
  [[ "$TIMEOUT_SECS" =~ ^[1-9][0-9]*$ ]] || {
    echo "pixel_boot_build_kgsl_probe: --timeout must be a positive integer" >&2
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
            f"pixel_boot_build_kgsl_probe: requested --patch-target entry not present in ramdisk: {explicit_target}",
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
        "pixel_boot_build_kgsl_probe: multiple root recovery rc anchors found; pass --patch-target explicitly",
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
    "pixel_boot_build_kgsl_probe: no supported rc import anchor found in ramdisk",
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
    --device-log-root)
      DEVICE_LOG_ROOT="${2:?missing value for --device-log-root}"
      shift 2
      ;;
    --patch-target)
      PATCH_TARGET_OVERRIDE="${2:?missing value for --patch-target}"
      shift 2
      ;;
    --import-proof-prop)
      IMPORT_PROOF_PROP="${2:?missing value for --import-proof-prop}"
      shift 2
      ;;
    --launch-proof-prop)
      LAUNCH_PROOF_PROP="${2:?missing value for --launch-proof-prop}"
      shift 2
      ;;
    --result-prop-key)
      RESULT_PROP_KEY="${2:?missing value for --result-prop-key}"
      shift 2
      ;;
    --helper-status-prop-key)
      HELPER_STATUS_PROP_KEY="${2:?missing value for --helper-status-prop-key}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECS="${2:?missing value for --timeout}"
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
      echo "pixel_boot_build_kgsl_probe: unknown argument: $1" >&2
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
pixel_boot_build_kgsl_probe: input image not found: $INPUT_IMAGE

Run 'sc root-prep' first to cache the stock sunfish boot.img.
EOF
  exit 1
}

validate_literal_trigger
validate_device_log_root
validate_patch_target_override
parse_import_proof_prop
parse_launch_proof_prop
validate_property_key "$RESULT_PROP_KEY" "result property key"
validate_property_key "$HELPER_STATUS_PROP_KEY" "helper status property key"
validate_timeout_secs

pixel_prepare_dirs
if [[ -z "$OUTPUT_IMAGE" ]]; then
  OUTPUT_IMAGE="$(default_output_image)"
fi
mkdir -p "$(dirname "$OUTPUT_IMAGE")"
WORK_DIR="$(bootimg_prepare_work_dir shadow-pixel-boot-kgsl-probe)"

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
    setprop ${IMPORT_PROOF_KEY} ${IMPORT_PROOF_VALUE}
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
helper_status_prop_key="${HELPER_STATUS_PROP_KEY}"
launch_proof_key="${LAUNCH_PROOF_KEY}"
launch_proof_value="${LAUNCH_PROOF_VALUE}"
result_prop_key="${RESULT_PROP_KEY}"
trigger_value="${TRIGGER}"
timeout_secs="${TIMEOUT_SECS}"

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
  : >"\$output_path"
  chmod 0644 "\$output_path" 2>/dev/null || true
  return 1
}

capture_prop() {
  getprop "\$1" 2>/dev/null | tr -d '\r'
}

write_stage() {
  stage_value="\$1"
  printf '%s\n' "\$stage_value" >"\$log_root/kgsl-probe-stage.txt"
  chmod 0644 "\$log_root/kgsl-probe-stage.txt" 2>/dev/null || true
  log_line "kgsl probe stage=\$stage_value"
}

capture_proc_state() {
  probe_pid="\$1"
  if [ -z "\$probe_pid" ] || [ ! -d "/proc/\$probe_pid" ]; then
    return 0
  fi

  if [ -r "/proc/\$probe_pid/wchan" ]; then
    cat "/proc/\$probe_pid/wchan" >"\$log_root/kgsl-probe-wchan.txt" 2>/dev/null || true
    chmod 0644 "\$log_root/kgsl-probe-wchan.txt" 2>/dev/null || true
  fi
  if [ -r "/proc/\$probe_pid/stack" ]; then
    cat "/proc/\$probe_pid/stack" >"\$log_root/kgsl-probe-stack.txt" 2>/dev/null || true
    chmod 0644 "\$log_root/kgsl-probe-stack.txt" 2>/dev/null || true
  fi
  if [ -r "/proc/\$probe_pid/stat" ]; then
    cat "/proc/\$probe_pid/stat" >"\$log_root/kgsl-probe-stat.txt" 2>/dev/null || true
    chmod 0644 "\$log_root/kgsl-probe-stat.txt" 2>/dev/null || true
  fi
  if [ -r "/proc/\$probe_pid/status" ]; then
    cat "/proc/\$probe_pid/status" >"\$log_root/kgsl-probe-status.txt" 2>/dev/null || true
    chmod 0644 "\$log_root/kgsl-probe-status.txt" 2>/dev/null || true
  fi
}

write_summary() {
  result_value="\$1"
  probe_pid="\$2"
  kgsl_device_exists="\$3"
  {
    printf 'trigger=%s\n' "\$trigger_value"
    printf 'timeout_secs=%s\n' "\$timeout_secs"
    printf 'result=%s\n' "\$result_value"
    printf 'child_pid=%s\n' "\$probe_pid"
    printf 'kgsl_device_exists=%s\n' "\$kgsl_device_exists"
    printf 'boot_id=%s\n' "\$boot_id"
    printf 'slot_suffix=%s\n' "\$slot_suffix"
    printf 'surfaceflinger=%s\n' "\$(capture_prop init.svc.surfaceflinger)"
    printf 'bootanim=%s\n' "\$(capture_prop init.svc.bootanim)"
    printf 'pd_mapper=%s\n' "\$(capture_prop init.svc.pd_mapper)"
    printf 'qseecom_service=%s\n' "\$(capture_prop init.svc.qseecom-service)"
    printf 'gpu_service=%s\n' "\$(capture_prop init.svc.gpu)"
    printf 'sys_boot_completed=%s\n' "\$(capture_prop sys.boot_completed)"
    if [ -s "\$log_root/kgsl-probe-wchan.txt" ]; then
      printf 'wchan_present=true\n'
    else
      printf 'wchan_present=false\n'
    fi
    if [ -s "\$log_root/kgsl-probe-stack.txt" ]; then
      printf 'stack_present=true\n'
    else
      printf 'stack_present=false\n'
    fi
  } >"\$log_root/kgsl-probe-summary.txt"
  chmod 0644 "\$log_root/kgsl-probe-summary.txt" 2>/dev/null || true
}

rm -rf "\$log_root"
mkdir -p "\$log_root"
chown shell:shell "\$log_root" 2>/dev/null || true
chmod 0775 "\$log_root" 2>/dev/null || true
: >"\$log_file"
chmod 0644 "\$log_file" 2>/dev/null || true

printf 'starting\n' >"\$log_root/status.txt"
chmod 0644 "\$log_root/status.txt" 2>/dev/null || true
setprop "\$helper_status_prop_key" starting || true

boot_id="\$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
slot_suffix="\$(getprop ro.boot.slot_suffix | tr -d '\r')"
printf '%s\n' "\$boot_id" >"\$log_root/boot-id.txt"
chmod 0644 "\$log_root/boot-id.txt" 2>/dev/null || true
printf '%s\n' "\$slot_suffix" >"\$log_root/slot-suffix.txt"
chmod 0644 "\$log_root/slot-suffix.txt" 2>/dev/null || true

capture_output "\$log_root/getprop.txt" getprop || true
capture_output "\$log_root/ps.txt" ps -A -o USER,PID,PPID,NAME,ARGS || capture_output "\$log_root/ps.txt" ps -A || true

setprop "\$launch_proof_key" "\$launch_proof_value" || true
setprop "\$result_prop_key" starting || true
write_stage launch
log_line "kgsl probe helper launch trigger=\$trigger_value timeout=\$timeout_secs"

kgsl_device_exists=false
if [ -e /dev/kgsl-3d0 ]; then
  kgsl_device_exists=true
fi

if [ "\$kgsl_device_exists" != true ]; then
  printf 'missing-device\n' >"\$log_root/kgsl-probe-result.txt"
  chmod 0644 "\$log_root/kgsl-probe-result.txt" 2>/dev/null || true
  write_stage missing-device
  write_summary missing-device "" "\$kgsl_device_exists"
  setprop "\$result_prop_key" missing-device || true
  printf 'ready\n' >"\$log_root/status.txt"
  chmod 0644 "\$log_root/status.txt" 2>/dev/null || true
  setprop "\$helper_status_prop_key" ready || true
  log_line "kgsl probe missing /dev/kgsl-3d0"
  exit 0
fi

probe_result_file="\$log_root/kgsl-probe-result.txt"
(
  exec 3</dev/kgsl-3d0
  printf 'open-ok\n' >"\$probe_result_file"
  chmod 0644 "\$probe_result_file" 2>/dev/null || true
  setprop "\$result_prop_key" open-ok || true
) &
probe_pid="\$!"
printf '%s\n' "\$probe_pid" >"\$log_root/kgsl-probe-pid.txt"
chmod 0644 "\$log_root/kgsl-probe-pid.txt" 2>/dev/null || true

write_stage waiting
remaining="\$timeout_secs"
probe_result=""
while [ "\$remaining" -gt 0 ]; do
  if [ -f "\$probe_result_file" ]; then
    probe_result="\$(tr -d '\r\n' <"\$probe_result_file" 2>/dev/null || true)"
    break
  fi
  if ! kill -0 "\$probe_pid" 2>/dev/null; then
    probe_result="child-exited"
    break
  fi
  remaining=\$((remaining - 1))
  sleep 1
done

if [ -z "\$probe_result" ]; then
  probe_result="timeout"
  capture_proc_state "\$probe_pid"
  kill -KILL "\$probe_pid" >/dev/null 2>&1 || true
  printf '%s\n' "\$probe_result" >"\$probe_result_file"
  chmod 0644 "\$probe_result_file" 2>/dev/null || true
  setprop "\$result_prop_key" timeout || true
else
  if [ "\$probe_result" != "open-ok" ]; then
    setprop "\$result_prop_key" "\$probe_result" || true
  fi
fi

write_stage "\$probe_result"
write_summary "\$probe_result" "\$probe_pid" "\$kgsl_device_exists"
capture_output "\$log_root/logcat-kernel.txt" logcat -b kernel -d || true
log_line "kgsl probe result=\$probe_result"

printf 'ready\n' >"\$log_root/status.txt"
chmod 0644 "\$log_root/status.txt" 2>/dev/null || true
setprop "\$helper_status_prop_key" ready || true
EOF
chmod 0755 "$WORK_DIR/shadow-boot-helper"

if [[ -z "$KEY_PATH" ]]; then
  KEY_PATH="$(ensure_cached_avb_testkey)"
fi

"$SCRIPT_DIR/pixel/pixel_boot_build.sh" \
  --stock-init \
  --input "$INPUT_IMAGE" \
  --key "$KEY_PATH" \
  --output "$OUTPUT_IMAGE" \
  --add "init.shadow.rc=$WORK_DIR/init.shadow.rc" \
  --add "shadow-boot-helper=$WORK_DIR/shadow-boot-helper" \
  --replace "$PATCH_TARGET=$WORK_DIR/patch-target.patched"

printf 'Wrote kgsl-probe boot image: %s\n' "$OUTPUT_IMAGE"
printf 'Trigger: %s\n' "$TRIGGER"
printf 'Timeout: %ss\n' "$TIMEOUT_SECS"
printf 'Device log root: %s\n' "$DEVICE_LOG_ROOT"
printf 'Patch target: %s\n' "$PATCH_TARGET"
printf 'Launch proof prop: %s\n' "$LAUNCH_PROOF_PROP"
printf 'Result prop key: %s\n' "$RESULT_PROP_KEY"
if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  printf 'Kept payload workdir: %s\n' "$WORK_DIR"
fi
