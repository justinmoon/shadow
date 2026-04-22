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
OUTPUT_IMAGE="${PIXEL_BOOT_LOG_PROBE_IMAGE:-}"
TRIGGER="${PIXEL_BOOT_LOG_PROBE_TRIGGER:-post-fs-data}"
DEVICE_LOG_ROOT="$(pixel_boot_device_log_root)"
PATCH_TARGET_OVERRIDE="${PIXEL_BOOT_LOG_PROBE_PATCH_TARGET:-}"
PREFLIGHT_PROFILE="${PIXEL_BOOT_PREFLIGHT_PROFILE:-}"
HELPER_STATUS_PROP_KEY="${PIXEL_BOOT_HELPER_STATUS_PROP_KEY:-debug.shadow.boot.log_probe}"
PREFLIGHT_STATUS_PROP_KEY="${PIXEL_BOOT_PREFLIGHT_STATUS_PROP_KEY:-debug.shadow.boot.preflight.status}"
PREFLIGHT_LAUNCH_PROOF_PROP="${PIXEL_BOOT_PREFLIGHT_LAUNCH_PROOF_PROP:-debug.shadow.boot.preflight.launch=started}"
BUILD_MODE="wrapper"
KEEP_WORK_DIR=0
WORK_DIR=""
PATCH_TARGET=""
PREFLIGHT_LAUNCH_PROOF_KEY=""
PREFLIGHT_LAUNCH_PROOF_VALUE=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_build_log_probe.sh [--input PATH] [--wrapper PATH] [--key PATH]
                                                   [--output PATH] [--trigger EXPR]
                                                   [--device-log-root PATH] [--patch-target ENTRY]
                                                   [--preflight-profile phase1-shell]
                                                   [--stock-init]
                                                   [--keep-work-dir]

Build a private sunfish boot.img that imports /init.shadow.rc and runs a boot helper
that emits log markers and optional preflight reports.
EOF
}

default_output_image() {
  if [[ "$BUILD_MODE" == "stock-init" ]]; then
    printf '%s/shadow-boot-log-probe-stock-init.img\n' "$(pixel_boot_dir)"
    return 0
  fi

  pixel_boot_log_probe_img
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

validate_property_key() {
  local property_key label
  property_key="${1:?validate_property_key requires a property key}"
  label="${2:?validate_property_key requires a label}"
  [[ "$property_key" =~ ^[A-Za-z0-9_.-]+$ ]] || {
    echo "pixel_boot_build_log_probe: $label contains unsupported characters: $property_key" >&2
    exit 1
  }
}

validate_property_value() {
  local property_value label
  property_value="${1:?validate_property_value requires a property value}"
  label="${2:?validate_property_value requires a label}"
  [[ "$property_value" =~ ^[A-Za-z0-9._:/+=,@-]+$ ]] || {
    echo "pixel_boot_build_log_probe: $label contains unsupported characters: $property_value" >&2
    exit 1
  }
}

parse_preflight_launch_proof_prop() {
  [[ "$PREFLIGHT_LAUNCH_PROOF_PROP" == *=* ]] || {
    echo "pixel_boot_build_log_probe: PIXEL_BOOT_PREFLIGHT_LAUNCH_PROOF_PROP must use KEY=VALUE" >&2
    exit 1
  }
  PREFLIGHT_LAUNCH_PROOF_KEY="${PREFLIGHT_LAUNCH_PROOF_PROP%%=*}"
  PREFLIGHT_LAUNCH_PROOF_VALUE="${PREFLIGHT_LAUNCH_PROOF_PROP#*=}"
  [[ -n "$PREFLIGHT_LAUNCH_PROOF_KEY" && -n "$PREFLIGHT_LAUNCH_PROOF_VALUE" ]] || {
    echo "pixel_boot_build_log_probe: PIXEL_BOOT_PREFLIGHT_LAUNCH_PROOF_PROP requires a non-empty key and value" >&2
    exit 1
  }
}

validate_preflight_profile() {
  validate_property_key "$HELPER_STATUS_PROP_KEY" "helper status property key"
  [[ -z "$PREFLIGHT_PROFILE" ]] && return 0
  case "$PREFLIGHT_PROFILE" in
    phase1-shell)
      ;;
    *)
      echo "pixel_boot_build_log_probe: unsupported --preflight-profile $PREFLIGHT_PROFILE; expected phase1-shell" >&2
      exit 1
      ;;
  esac
  validate_property_key "$PREFLIGHT_STATUS_PROP_KEY" "preflight status property key"
  parse_preflight_launch_proof_prop
  validate_property_key "$PREFLIGHT_LAUNCH_PROOF_KEY" "preflight launch proof property key"
  validate_property_value "$PREFLIGHT_LAUNCH_PROOF_VALUE" "preflight launch proof property value"
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
    --stock-init)
      BUILD_MODE="stock-init"
      shift
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
    --preflight-profile)
      PREFLIGHT_PROFILE="${2:?missing value for --preflight-profile}"
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
validate_preflight_profile

pixel_prepare_dirs
if [[ -z "$OUTPUT_IMAGE" ]]; then
  OUTPUT_IMAGE="$(default_output_image)"
fi
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
helper_status_prop_key="${HELPER_STATUS_PROP_KEY}"
preflight_status_prop_key="${PREFLIGHT_STATUS_PROP_KEY}"
preflight_launch_proof_key="${PREFLIGHT_LAUNCH_PROOF_KEY}"
preflight_launch_proof_value="${PREFLIGHT_LAUNCH_PROOF_VALUE}"

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

bool_word() {
  if [[ "\$1" == "1" || "\$1" == "true" ]]; then
    printf 'true'
  else
    printf 'false'
  fi
}

capture_prop() {
  getprop "\$1" 2>/dev/null | tr -d '\r'
}

path_exists_for_kind() {
  path="\$1"
  kind="\$2"
  case "\$kind" in
    file)
      [ -f "\$path" ]
      ;;
    dir)
      [ -d "\$path" ]
      ;;
    any)
      [ -e "\$path" ]
      ;;
    *)
      return 1
      ;;
  esac
}

rm -rf "\$log_root"
mkdir -p "\$log_root"
chown shell:shell "\$log_root" 2>/dev/null || true
chmod 0775 "\$log_root" 2>/dev/null || true
: >"\$log_file"
chmod 0644 "\$log_file" 2>/dev/null || true

setprop "\$helper_status_prop_key" starting || true
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
  printf 'preflight_profile=%s\n' "${PREFLIGHT_PROFILE}"
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

EOF

if [[ "$PREFLIGHT_PROFILE" == "phase1-shell" ]]; then
  cat >>"$WORK_DIR/shadow-boot-helper" <<EOF
preflight_status="ready"
preflight_blocked_reason=""
preflight_summary="\$log_root/preflight-summary.txt"
preflight_checks="\$log_root/preflight-checks.tsv"
preflight_required_check_count=0
preflight_missing_required_count=0
preflight_required_missing_labels=""
preflight_data_mounted=false
preflight_data_writable=false
preflight_data_local_tmp_ready=false

setprop "\$preflight_launch_proof_key" "\$preflight_launch_proof_value" || true

mark_preflight_blocked() {
  reason="\$1"
  preflight_status="blocked"
  if [[ -z "\$preflight_blocked_reason" ]]; then
    preflight_blocked_reason="\$reason"
  fi
}

append_missing_label() {
  label="\$1"
  if [[ -z "\$preflight_required_missing_labels" ]]; then
    preflight_required_missing_labels="\$label"
  else
    preflight_required_missing_labels="\$preflight_required_missing_labels,\$label"
  fi
}

record_preflight_path() {
  label="\$1"
  required="\$2"
  kind="\$3"
  path="\$4"
  exists=false

  if path_exists_for_kind "\$path" "\$kind"; then
    exists=true
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "\$label" \
    "\$required" \
    "\$kind" \
    "\$(bool_word "\$exists")" \
    "\$path" >>"\$preflight_checks"

  if [[ "\$required" == "true" ]]; then
    preflight_required_check_count=\$((preflight_required_check_count + 1))
    if [[ "\$exists" != "true" ]]; then
      preflight_missing_required_count=\$((preflight_missing_required_count + 1))
      append_missing_label "\$label"
      mark_preflight_blocked "missing-required-paths"
    fi
  fi
}

if awk '\$2 == "/data" {found=1} END {exit(found ? 0 : 1)}' /proc/mounts 2>/dev/null; then
  preflight_data_mounted=true
else
  mark_preflight_blocked "data-not-mounted"
fi

if touch "\$log_root/.preflight-write-test" 2>/dev/null; then
  preflight_data_writable=true
  rm -f "\$log_root/.preflight-write-test" 2>/dev/null || true
else
  mark_preflight_blocked "data-not-writable"
fi

if [[ -d /data/local/tmp && -w /data/local/tmp ]]; then
  preflight_data_local_tmp_ready=true
else
  mark_preflight_blocked "data-local-tmp-not-ready"
fi

printf '# label\trequired\tkind\texists\tpath\n' >"\$preflight_checks"
record_preflight_path runtime-linux-dir true dir "$(pixel_runtime_linux_dir)"
record_preflight_path system-launcher true file "$(pixel_system_launcher_dst)"
record_preflight_path compositor-launcher true file "$(pixel_runtime_compositor_launcher_dst)"
record_preflight_path guest-client-launcher true file "$(pixel_guest_client_dst)"
record_preflight_path runtime-dir false dir "$(pixel_runtime_dir)"
record_preflight_path runtime-app-bundle false file "$(pixel_runtime_app_bundle_dst)"
record_preflight_path runtime-session-config false file "$(pixel_runtime_session_config_path)"
chmod 0644 "\$preflight_checks" 2>/dev/null || true

{
  printf 'profile=%s\n' "phase1-shell"
  printf 'status=%s\n' "\$preflight_status"
  printf 'blocked_reason=%s\n' "\$preflight_blocked_reason"
  printf 'data_mounted=%s\n' "\$(bool_word "\$preflight_data_mounted")"
  printf 'data_writable=%s\n' "\$(bool_word "\$preflight_data_writable")"
  printf 'data_local_tmp_ready=%s\n' "\$(bool_word "\$preflight_data_local_tmp_ready")"
  printf 'required_check_count=%s\n' "\$preflight_required_check_count"
  printf 'missing_required_count=%s\n' "\$preflight_missing_required_count"
  printf 'required_missing_labels=%s\n' "\$preflight_required_missing_labels"
  printf 'runtime_dir=%s\n' "$(pixel_runtime_dir)"
  printf 'runtime_linux_dir=%s\n' "$(pixel_runtime_linux_dir)"
  printf 'system_launcher=%s\n' "$(pixel_system_launcher_dst)"
  printf 'compositor_launcher=%s\n' "$(pixel_runtime_compositor_launcher_dst)"
  printf 'guest_client_launcher=%s\n' "$(pixel_guest_client_dst)"
  printf 'runtime_app_bundle=%s\n' "$(pixel_runtime_app_bundle_dst)"
  printf 'runtime_session_config=%s\n' "$(pixel_runtime_session_config_path)"
  printf 'surfaceflinger=%s\n' "\$(capture_prop init.svc.surfaceflinger)"
  printf 'bootanim=%s\n' "\$(capture_prop init.svc.bootanim)"
  printf 'pd_mapper=%s\n' "\$(capture_prop init.svc.pd_mapper)"
  printf 'qseecom_service=%s\n' "\$(capture_prop init.svc.qseecom-service)"
  printf 'gpu_service=%s\n' "\$(capture_prop init.svc.gpu)"
  printf 'sys_boot_completed=%s\n' "\$(capture_prop sys.boot_completed)"
} >"\$preflight_summary"
chmod 0644 "\$preflight_summary" 2>/dev/null || true

printf '%s\n' "\$preflight_status" >"\$log_root/status.txt"
chmod 0644 "\$log_root/status.txt" 2>/dev/null || true
setprop "\$preflight_status_prop_key" "\$preflight_status" || true
log_line "preflight phase1-shell status=\$preflight_status missing_required=\$preflight_missing_required_count reason=\${preflight_blocked_reason:-none}"
EOF
fi

cat >>"$WORK_DIR/shadow-boot-helper" <<EOF

if [[ ! -f "\$log_root/status.txt" ]]; then
printf 'ready\n' >"\$log_root/status.txt"
chmod 0644 "\$log_root/status.txt" 2>/dev/null || true
fi
log_line "helper finished"
setprop "\$helper_status_prop_key" ready || true
EOF
chmod 0755 "$WORK_DIR/shadow-boot-helper"

build_args=(
  --input "$INPUT_IMAGE"
  --output "$OUTPUT_IMAGE"
  --add "init.shadow.rc=$WORK_DIR/init.shadow.rc"
  --add "shadow-boot-helper=$WORK_DIR/shadow-boot-helper"
  --replace "$PATCH_TARGET=$WORK_DIR/patch-target.patched"
)

if [[ "$BUILD_MODE" == "stock-init" ]]; then
  build_args+=(--stock-init)
else
  build_args+=(--wrapper "$WRAPPER_BINARY")
fi

if [[ -n "$KEY_PATH" ]]; then
  build_args+=(--key "$KEY_PATH")
fi

"$SCRIPT_DIR/pixel/pixel_boot_build.sh" "${build_args[@]}"

printf 'Wrote log-probe boot image: %s\n' "$OUTPUT_IMAGE"
printf 'Build mode: %s\n' "$BUILD_MODE"
printf 'Trigger: %s\n' "$TRIGGER"
printf 'Device log root: %s\n' "$DEVICE_LOG_ROOT"
printf 'Patch target: %s\n' "$PATCH_TARGET"
if [[ -n "$PREFLIGHT_PROFILE" ]]; then
  printf 'Preflight profile: %s\n' "$PREFLIGHT_PROFILE"
fi
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
