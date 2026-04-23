#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-pixel-boot-tooling.XXXXXX")"
MOCK_BIN="$TMP_DIR/bin"
COMMON_ROOT="$TMP_DIR/common-root"
LOCAL_BOOT="$TMP_DIR/local-boot.img"
SHARED_BOOT="$TMP_DIR/shared-boot.img"
PROBE_IMAGE="$TMP_DIR/probe.img"
PROBE_RUN_TOKEN="tooling-run-token-42"
STOCK_BOOT_IMAGE="$TMP_DIR/stock-boot.img"
ONESHOT_OUTPUT="$TMP_DIR/oneshot-output"
FLASH_RUN_OUTPUT="$TMP_DIR/flash-run-output"
ONESHOT_ADB_LOGCAT_PROOF_OUTPUT="$TMP_DIR/oneshot-adb-logcat-proof-output"
ONESHOT_ADB_DEVICE_PATH_PROOF_OUTPUT="$TMP_DIR/oneshot-adb-device-path-proof-output"
ONESHOT_ADB_PS_PROOF_OUTPUT="$TMP_DIR/oneshot-adb-ps-proof-output"
ONESHOT_ADB_RETURN_OUTPUT="$TMP_DIR/oneshot-adb-return-output"
ONESHOT_ADB_RETURN_STALE_HISTORY_OUTPUT="$TMP_DIR/oneshot-adb-return-stale-history-output"
ONESHOT_ADB_RETURN_NOWAIT_OUTPUT="$TMP_DIR/oneshot-adb-return-nowait-output"
ONESHOT_ADB_LATE_RECOVER_OUTPUT="$TMP_DIR/oneshot-adb-late-recover-output"
ONESHOT_ADB_LATE_RECOVER_FAIL_OUTPUT="$TMP_DIR/oneshot-adb-late-recover-fail-output"
ONESHOT_ADB_LATE_FASTBOOT_AUTO_REBOOT_OUTPUT="$TMP_DIR/oneshot-adb-late-fastboot-auto-reboot-output"
ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT="$TMP_DIR/oneshot-adb-fastboot-auto-reboot-output"
ONESHOT_FASTBOOT_RETURN_OUTPUT="$TMP_DIR/oneshot-fastboot-return-output"
ONESHOT_FASTBOOT_RETURN_FAIL_OUTPUT="$TMP_DIR/oneshot-fastboot-return-fail-output"
FLASH_RUN_FASTBOOT_RETURN_OUTPUT="$TMP_DIR/flash-run-fastboot-return-output"
MOCK_DEVICE_STATE_DIR="$TMP_DIR/mock-device-state"
BOOT_BUILD_INPUT="$TMP_DIR/build-input.img"
BOOT_BUILD_RAMDISK="$TMP_DIR/build-ramdisk.cpio"
BOOT_BUILD_RAMDISK_WITH_RECOVERY="$TMP_DIR/build-ramdisk-with-recovery.cpio"
BOOT_BUILD_RAMDISK_RECOVERY_STYLE="$TMP_DIR/build-ramdisk-recovery-style.cpio"
BOOT_BUILD_SYSTEM_INIT_RAMDISK="$TMP_DIR/build-system-init-ramdisk.cpio"
BOOT_BUILD_SYSTEM_INIT_NONSTOCK_ROOT_RAMDISK="$TMP_DIR/build-system-init-nonstock-root-ramdisk.cpio"
BOOT_BUILD_SECOND_STAGE_RC_RAMDISK="$TMP_DIR/build-second-stage-rc-ramdisk.cpio"
BOOT_BUILD_RAMDISK_PROP_RAMDISK="$TMP_DIR/build-ramdisk-prop-ramdisk.cpio"
WRAPPER_STANDARD_BIN="$TMP_DIR/init-wrapper-standard"
WRAPPER_MINIMAL_BIN="$TMP_DIR/init-wrapper-minimal"
AVB_KEY_PATH="$TMP_DIR/avb-testkey.pem"
ADDED_RC="$TMP_DIR/init.extra.rc"
PATCHED_INIT_RC="$TMP_DIR/init.rc.patched"
WRAPPER_OUTPUT_IMAGE="$TMP_DIR/wrapper-output.img"
MINIMAL_WRAPPER_OUTPUT_IMAGE="$TMP_DIR/wrapper-minimal-output.img"
C_WRAPPER_OUTPUT_IMAGE="$TMP_DIR/wrapper-c-minimal-output.img"
WRAPPER_BUILD_OUTPUT="$TMP_DIR/built-init-wrapper-standard"
MINIMAL_BUILD_OUTPUT="$TMP_DIR/built-init-wrapper-minimal"
C_WRAPPER_BUILD_OUTPUT="$TMP_DIR/built-init-wrapper-c-minimal"
C_WRAPPER_SYSTEM_BUILD_OUTPUT="$TMP_DIR/built-init-wrapper-c-system-init-minimal"
BAD_C_WRAPPER_SYSTEM_BUILD_OUTPUT="$TMP_DIR/bad-init-wrapper-c-system-init-minimal"
WRONG_TARGET_C_WRAPPER_SYSTEM_BUILD_OUTPUT="$TMP_DIR/wrong-target-init-wrapper-c-system-init-minimal"
STOCK_INIT_OUTPUT_IMAGE="$TMP_DIR/stock-init-output.img"
CMDLINE_PROBE_OUTPUT_IMAGE="$TMP_DIR/cmdline-probe-stock-init.img"
INIT_SYMLINK_OUTPUT_IMAGE="$TMP_DIR/init-symlink-output.img"
SYSTEM_INIT_SYMLINK_OUTPUT_IMAGE="$TMP_DIR/system-init-symlink-output.img"
SYSTEM_INIT_WRAPPER_OUTPUT_IMAGE="$TMP_DIR/system-init-wrapper-output.img"
LOG_PROBE_OUTPUT_IMAGE="$TMP_DIR/log-probe-stock-init.img"
LOG_PREFLIGHT_OUTPUT_IMAGE="$TMP_DIR/log-probe-preflight-stock-init.img"
KGSL_PROBE_OUTPUT_IMAGE="$TMP_DIR/kgsl-probe-stock-init.img"
RC_PROBE_OUTPUT_IMAGE="$TMP_DIR/rc-probe-stock-init.img"
RC_PROBE_INLINE_OUTPUT_IMAGE="$TMP_DIR/rc-probe-inline-stock-init.img"
RAMDISK_PROP_PROBE_OUTPUT_IMAGE="$TMP_DIR/ramdisk-prop-probe-stock-init.img"
SECOND_STAGE_RC_PROBE_OUTPUT_IMAGE="$TMP_DIR/second-stage-rc-probe-stock-init.img"
PREFLIGHT_OUTPUT="$TMP_DIR/boot-preflight-output"
PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT="$TMP_DIR/boot-preflight-second-stage-blocked-output"
PREFLIGHT_CONFLICT_OUTPUT="$TMP_DIR/boot-preflight-conflict-output"
PREFLIGHT_LEASE_COMMON_ROOT="$TMP_DIR/preflight-lease-common-root"
RC_TRIGGER_LADDER_OUTPUT="$TMP_DIR/rc-trigger-ladder-output"
KGSL_PROBE_OUTPUT="$TMP_DIR/boot-kgsl-probe-output"
KGSL_TRIGGER_LADDER_OUTPUT="$TMP_DIR/boot-kgsl-trigger-ladder-output"
KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT="$TMP_DIR/boot-kgsl-trigger-ladder-negative-output"
KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT="$TMP_DIR/boot-kgsl-trigger-ladder-imported-rc-only-output"
KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT="$TMP_DIR/boot-kgsl-trigger-ladder-control-point-only-output"
KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT="$TMP_DIR/boot-kgsl-trigger-ladder-init-script-selection-only-output"
KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT="$TMP_DIR/boot-kgsl-trigger-ladder-second-stage-only-output"
PREFLIGHT_BUILD_MOCK="$TMP_DIR/mock-preflight-build.sh"
PREFLIGHT_ONESHOT_MOCK="$TMP_DIR/mock-preflight-oneshot.sh"
KGSL_PROBE_BUILD_MOCK="$TMP_DIR/mock-kgsl-probe-build.sh"
KGSL_PROBE_ONESHOT_MOCK="$TMP_DIR/mock-kgsl-probe-oneshot.sh"
LOCKF_LOG="$TMP_DIR/mock-lockf.log"
RC_TRIGGER_LADDER_BUILD_MOCK="$TMP_DIR/mock-rc-trigger-build.sh"
RC_TRIGGER_LADDER_ONESHOT_MOCK="$TMP_DIR/mock-rc-trigger-oneshot.sh"
MOCK_STORE_STANDARD="$TMP_DIR/store-standard"
MOCK_STORE_MINIMAL="$TMP_DIR/store-minimal"
MOCK_STORE_C="$TMP_DIR/store-c"
MOCK_STORE_C_SYSTEM="$TMP_DIR/store-c-system"
MOCK_GPU_SMOKE_STORE="$TMP_DIR/store-shadow-gpu-smoke"
TMPFS_DEV_GPU_OUTPUT="$TMP_DIR/tmpfs-dev-gpu-output"
TMPFS_DEVICE_STATE_ROOT="$TMP_DIR/tmpfs-device-root"
TMPFS_DEVICE_DIR="/data/local/tmp/shadow-gpu-smoke-devtmpfs-smoke"
TMPFS_FAKE_TURNIP_LIB="$TMP_DIR/fake-turnip-lib.so"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

rewrite_dynamic_bash_shebangs() {
  local root="${1:-$TMP_DIR}" path first_line
  while IFS= read -r -d '' path; do
    IFS= read -r first_line <"$path" || continue
    if [[ "$first_line" == "#!/usr/bin/env bash" ]]; then
      sed -i "1s|^#!/usr/bin/env bash$|#!$BASH|" "$path"
    fi
  done < <(find "$root" -type f -print0 2>/dev/null)
}

mkdir -p "$MOCK_BIN"
printf 'local boot image\n' >"$LOCAL_BOOT"
printf 'shared boot image\n' >"$SHARED_BOOT"
printf 'probe image\n' >"$PROBE_IMAGE"
cat >"$PROBE_IMAGE.hello-init.json" <<EOF
{
  "kind": "hello_init_build",
  "run_token": "$PROBE_RUN_TOKEN",
  "log_kmsg": true,
  "log_pmsg": true
}
EOF
printf 'stock boot image\n' >"$STOCK_BOOT_IMAGE"
printf 'boot build input\n' >"$BOOT_BUILD_INPUT"
printf 'fake turnip\n' >"$TMPFS_FAKE_TURNIP_LIB"
mkdir -p \
  "$MOCK_STORE_STANDARD/bin" \
  "$MOCK_STORE_MINIMAL/bin" \
  "$MOCK_STORE_C/bin" \
  "$MOCK_STORE_C_SYSTEM/bin" \
  "$MOCK_GPU_SMOKE_STORE/bin" \
  "$MOCK_GPU_SMOKE_STORE/lib"
printf 'mock gpu smoke binary\n' >"$MOCK_GPU_SMOKE_STORE/bin/shadow-gpu-smoke"
printf 'mock loader\n' >"$MOCK_GPU_SMOKE_STORE/lib/ld-linux-aarch64.so.1"
printf 'mock libc\n' >"$MOCK_GPU_SMOKE_STORE/lib/libc.so.6"
printf 'mock vulkan loader\n' >"$MOCK_GPU_SMOKE_STORE/lib/libvulkan.so.1"
chmod 0755 "$MOCK_GPU_SMOKE_STORE/bin/shadow-gpu-smoke" "$MOCK_GPU_SMOKE_STORE/lib/ld-linux-aarch64.so.1"

cat >"$WRAPPER_STANDARD_BIN" <<'EOF'
#!/system/bin/sh
# shadow-init-wrapper-mode:standard
echo wrapper-standard
EOF
cat >"$WRAPPER_MINIMAL_BIN" <<'EOF'
#!/system/bin/sh
# shadow-init-wrapper-mode:minimal
echo wrapper-minimal
EOF
cat >"$C_WRAPPER_BUILD_OUTPUT" <<'EOF'
#!/system/bin/sh
# shadow-init-wrapper-mode:minimal
# shadow-init-wrapper-impl:tinyc-direct
# shadow-init-wrapper-path:/init
# shadow-init-wrapper-target:/init.stock
echo wrapper-c-minimal
EOF
cat >"$C_WRAPPER_SYSTEM_BUILD_OUTPUT" <<'EOF'
#!/system/bin/sh
# shadow-init-wrapper-mode:minimal
# shadow-init-wrapper-impl:tinyc-direct
# shadow-init-wrapper-path:/system/bin/init
# shadow-init-wrapper-target:/system/bin/init.stock
echo wrapper-c-system-init-minimal
EOF
cat >"$BAD_C_WRAPPER_SYSTEM_BUILD_OUTPUT" <<'EOF'
#!/system/bin/sh
# shadow-init-wrapper-mode:minimal
# shadow-init-wrapper-impl:tinyc-direct
# shadow-init-wrapper-path:/system/bin/init
# shadow-init-wrapper-target:/system/bin/init.stock
echo bad-wrapper-c-system-init-minimal
EOF
cat >"$WRONG_TARGET_C_WRAPPER_SYSTEM_BUILD_OUTPUT" <<'EOF'
#!/system/bin/sh
# shadow-init-wrapper-mode:minimal
# shadow-init-wrapper-impl:tinyc-direct
# shadow-init-wrapper-path:/system/bin/init
# shadow-init-wrapper-target:/init.stock
echo wrong-target-wrapper-c-system-init-minimal
EOF
chmod 0755 "$WRAPPER_STANDARD_BIN" "$WRAPPER_MINIMAL_BIN" "$C_WRAPPER_BUILD_OUTPUT" "$C_WRAPPER_SYSTEM_BUILD_OUTPUT"
cp "$WRAPPER_STANDARD_BIN" "$MOCK_STORE_STANDARD/bin/init-wrapper"
cp "$WRAPPER_MINIMAL_BIN" "$MOCK_STORE_MINIMAL/bin/init-wrapper"
cp "$C_WRAPPER_BUILD_OUTPUT" "$MOCK_STORE_C/bin/init-wrapper"
cp "$C_WRAPPER_SYSTEM_BUILD_OUTPUT" "$MOCK_STORE_C_SYSTEM/bin/init-wrapper"
printf 'mock avb key\n' >"$AVB_KEY_PATH"
printf 'import /init.extra.rc\n' >"$ADDED_RC"
cat >"$PATCHED_INIT_RC" <<'EOF'
import /init.shadow.rc

on boot
    setprop debug.shadow.boot.rc_probe ready
EOF

cat >"$RC_TRIGGER_LADDER_BUILD_MOCK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
trigger=""
property=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    --trigger)
      trigger="$2"
      shift 2
      ;;
    --property)
      property="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$(dirname "$output")"
printf 'mock rc probe image\n' >"$output"
printf 'Trigger: %s\n' "$trigger"
printf 'Property: %s\n' "$property"
EOF
chmod 0755 "$RC_TRIGGER_LADDER_BUILD_MOCK"

cat >"$PREFLIGHT_BUILD_MOCK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
profile=""
trigger=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    --preflight-profile)
      profile="$2"
      shift 2
      ;;
    --trigger)
      trigger="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$(dirname "$output")"
printf 'mock preflight image\n' >"$output"
printf 'Profile: %s\n' "$profile"
printf 'Trigger: %s\n' "$trigger"
EOF
chmod 0755 "$PREFLIGHT_BUILD_MOCK"

cat >"$PREFLIGHT_ONESHOT_MOCK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

image=""
output=""
proof_prop=""
observed_prop=""
mode="${MOCK_PREFLIGHT_ONESHOT_MODE:-helper-blocked}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      image="$2"
      shift 2
      ;;
    --output)
      output="$2"
      shift 2
      ;;
    --proof-prop)
      proof_prop="$2"
      shift 2
      ;;
    --observed-prop)
      observed_prop="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$output/collect"
cat >"$output/collect/getprop.txt" <<'GPROPS'
[debug.shadow.boot.preflight.second_stage]: [ready]
GPROPS
python3 - "$output/status.json" "$output/collect/status.json" "$image" "${PIXEL_SERIAL:-TESTSERIAL}" "$proof_prop" "$observed_prop" "$mode" <<'PY'
import json
import sys

status_path, collect_status_path, image_path, serial, proof_prop, observed_prop, mode = sys.argv[1:8]

device_status = {
    "ok": mode != "second-stage-only",
    "serial": serial,
    "collect_succeeded": mode != "second-stage-only",
    "collection_succeeded": mode != "second-stage-only",
    "collect_output_dir": str(collect_status_path.rsplit("/", 1)[0]),
    "failure_stage": "collect" if mode == "second-stage-only" else "",
    "proof_prop": proof_prop,
    "observed_prop": observed_prop,
}
if mode == "second-stage-only":
    collect_status = {
        "collection_succeeded": False,
        "observed_property_matched": False,
        "preflight_summary_present": False,
        "preflight_checks_present": False,
        "preflight_profile": "",
        "preflight_status": "",
        "preflight_ready": False,
        "preflight_blocked_reason": "",
        "preflight_required_missing_labels": "",
    }
else:
    collect_status = {
        "collection_succeeded": True,
        "observed_property_matched": bool(observed_prop),
        "preflight_summary_present": True,
        "preflight_checks_present": True,
        "preflight_profile": "phase1-shell",
        "preflight_status": "blocked",
        "preflight_ready": False,
        "preflight_blocked_reason": "missing-required-paths",
        "preflight_required_missing_labels": "system-launcher,guest-client-launcher",
    }
with open(status_path, "w", encoding="utf-8") as fh:
    json.dump(device_status, fh, indent=2, sort_keys=True)
    fh.write("\n")
with open(collect_status_path, "w", encoding="utf-8") as fh:
    json.dump(collect_status, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
printf 'mock preflight oneshot for %s\n' "$image"
if [[ "$mode" == "second-stage-only" ]]; then
  exit 1
fi
EOF
chmod 0755 "$PREFLIGHT_ONESHOT_MOCK"

cat >"$KGSL_PROBE_BUILD_MOCK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
trigger=""
timeout_secs=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    --trigger)
      trigger="$2"
      shift 2
      ;;
    --timeout)
      timeout_secs="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$(dirname "$output")"
printf 'mock kgsl probe image\n' >"$output"
printf 'Trigger: %s\n' "$trigger"
printf 'Timeout: %s\n' "$timeout_secs"
EOF
chmod 0755 "$KGSL_PROBE_BUILD_MOCK"

cat >"$KGSL_PROBE_ONESHOT_MOCK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

image=""
output=""
proof_prop=""
observed_prop=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      image="$2"
      shift 2
      ;;
    --output)
      output="$2"
      shift 2
      ;;
    --proof-prop)
      proof_prop="$2"
      shift 2
      ;;
    --observed-prop)
      observed_prop="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

helper_dir="$output/collect/device/shadow-boot"
mkdir -p "$helper_dir"
printf 'ready\n' >"$helper_dir/status.txt"
printf 'mock-boot-id\n' >"$helper_dir/boot-id.txt"
printf '_a\n' >"$helper_dir/slot-suffix.txt"
printf 'timeout\n' >"$helper_dir/kgsl-probe-stage.txt"
printf 'request_firmware\n' >"$helper_dir/kgsl-probe-wchan.txt"
cat >"$helper_dir/kgsl-probe-summary.txt" <<'INNER'
trigger=post-fs-data
timeout_secs=12
result=timeout
child_pid=4321
kgsl_device_exists=true
wchan_present=true
stack_present=true
INNER
printf 'stack\n' >"$helper_dir/kgsl-probe-stack.txt"

mkdir -p "$output/collect"
python3 - \
  "$output/status.json" \
  "$output/collect/status.json" \
    "$output/collect/getprop.txt" \
    "$image" \
    "${PIXEL_SERIAL:-TESTSERIAL}" \
    "$proof_prop" \
    "$observed_prop" \
    "${PIXEL_BOOT_KGSL_PROBE_SECOND_STAGE_PROOF_PROP:-debug.shadow.boot.kgsl.second_stage=ready}" \
    "${PIXEL_BOOT_KGSL_PROBE_INIT_SCRIPT_SELECTION_PROOF_PROP:-init.svc.servicemanager=running}" \
    "${PIXEL_BOOT_KGSL_PROBE_IMPORTED_RC_PROOF_PROP:-init.svc.adbd=running}" \
    "${PIXEL_BOOT_KGSL_PROBE_CONTROL_POINT_PROOF_PROP:-init.svc.llkd-0=running}" \
    "${MOCK_KGSL_SECOND_STAGE_PROOF_MATCHED:-1}" \
    "${MOCK_KGSL_INIT_SCRIPT_SELECTION_PROOF_MATCHED:-1}" \
    "${MOCK_KGSL_IMPORTED_RC_PROOF_MATCHED:-1}" \
    "${MOCK_KGSL_CONTROL_POINT_PROOF_MATCHED:-1}" \
    "${MOCK_KGSL_IMPORT_PROOF_MATCHED:-1}" \
    "${MOCK_KGSL_HELPER_LAUNCH_MATCHED:-1}" <<'PY'
import json
import sys

(
    status_path,
    collect_status_path,
    getprop_path,
    image_path,
    serial,
    proof_prop,
    observed_prop,
    second_stage_proof_prop,
    init_script_selection_proof_prop,
    imported_rc_proof_prop,
    control_point_proof_prop,
    second_stage_proof_matched,
    init_script_selection_proof_matched,
    imported_rc_proof_matched,
    control_point_proof_matched,
    import_proof_matched,
    helper_launch_matched,
) = sys.argv[1:18]


def parse_prop_spec(spec: str):
    if "=" not in spec:
        return "", ""
    return spec.split("=", 1)


proof_key, proof_expected = parse_prop_spec(proof_prop)
observed_key, observed_expected = parse_prop_spec(observed_prop)
second_stage_key, second_stage_expected = parse_prop_spec(second_stage_proof_prop)
init_script_selection_key, init_script_selection_expected = parse_prop_spec(init_script_selection_proof_prop)
imported_rc_key, imported_rc_expected = parse_prop_spec(imported_rc_proof_prop)
control_point_key, control_point_expected = parse_prop_spec(control_point_proof_prop)
second_stage_matched = second_stage_proof_matched == "1"
init_script_selection_matched = init_script_selection_proof_matched == "1"
imported_rc_matched = imported_rc_proof_matched == "1"
control_point_matched = control_point_proof_matched == "1"
import_matched = import_proof_matched == "1"
helper_matched = helper_launch_matched == "1"

device_status = {
    "ok": True,
    "serial": serial,
    "collection_succeeded": True,
    "collect_output_dir": str(collect_status_path.rsplit("/", 1)[0]),
    "adb_ready": True,
    "boot_completed": False,
    "transport_last_state": "adb",
    "transport_first_adb_elapsed_secs": 17,
    "transport_first_fastboot_elapsed_secs": 0,
    "failure_stage": "bootreason",
    "bootreason_sys_boot_reason": "bootloader",
    "fastboot_auto_reboot_attempted": True,
    "fastboot_auto_reboot_succeeded": True,
    "recover_traces_succeeded": True,
    "recover_traces_proof_ok": False,
    "recover_traces_matched_any_shadow_tags": False,
}
collect_status = {
    "collection_succeeded": import_matched,
    "proof_property_key": proof_key,
    "proof_property_expected": proof_expected,
    "proof_property_actual": proof_expected if import_matched else "",
    "proof_property_matched": import_matched,
    "observed_property_key": observed_key,
    "observed_property_expected": observed_expected,
    "observed_property_actual": observed_expected if helper_matched else "",
    "observed_property_matched": helper_matched,
    "helper_dir_present": helper_matched,
    "helper_dir_pulled": helper_matched,
    "helper_status_present": helper_matched,
    "matched_current_boot": helper_matched,
    "matched_current_slot": helper_matched,
    "matched_expected_slot": True,
    "live_matches_expected_slot": True,
}
with open(status_path, "w", encoding="utf-8") as fh:
    json.dump(device_status, fh, indent=2, sort_keys=True)
    fh.write("\n")
with open(collect_status_path, "w", encoding="utf-8") as fh:
    json.dump(collect_status, fh, indent=2, sort_keys=True)
    fh.write("\n")
with open(getprop_path, "w", encoding="utf-8") as fh:
    if second_stage_key:
        actual_second_stage = second_stage_expected if second_stage_matched else ""
        fh.write(f"[{second_stage_key}]: [{actual_second_stage}]\n")
    if init_script_selection_key:
        actual_init_script_selection = init_script_selection_expected if init_script_selection_matched else ""
        fh.write(f"[{init_script_selection_key}]: [{actual_init_script_selection}]\n")
    if imported_rc_key:
        actual_imported_rc = imported_rc_expected if imported_rc_matched else ""
        fh.write(f"[{imported_rc_key}]: [{actual_imported_rc}]\n")
    if control_point_key:
        actual_control_point = control_point_expected if control_point_matched else ""
        fh.write(f"[{control_point_key}]: [{actual_control_point}]\n")
PY
printf 'mock kgsl probe oneshot for %s\n' "$image"
EOF
chmod 0755 "$KGSL_PROBE_ONESHOT_MOCK"

cat >"$MOCK_BIN/lockf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_path="${MOCK_LOCKF_LOG:-}"

if [[ "${1:-}" == "-st" ]]; then
  if [[ -n "$log_path" ]]; then
    printf 'probe %s %s %s\n' "${2:-}" "${3:-}" "${4:-}" >>"$log_path"
  fi
  exit 0
fi

lock_path="${1:-}"
script_path="${2:-}"
shift 2
if [[ -n "$log_path" ]]; then
  printf 'exec %s %s\n' "$lock_path" "$script_path" >>"$log_path"
fi
exec "$script_path" "$@"
EOF

cat >"$RC_TRIGGER_LADDER_ONESHOT_MOCK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

image=""
output=""
proof_prop=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      image="$2"
      shift 2
      ;;
    --output)
      output="$2"
      shift 2
      ;;
    --proof-prop)
      proof_prop="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

proof_key="${proof_prop%%=*}"
proof_value="${proof_prop#*=}"
mkdir -p "$output/collect"
python3 - "$output/status.json" "$output/collect/status.json" "$image" "$output" "${PIXEL_SERIAL:-TESTSERIAL}" "$proof_prop" "$proof_value" "$proof_key" <<'PY'
import json
import sys

status_path, collect_path, image, output_dir, serial, proof_prop, proof_value, proof_key = sys.argv[1:9]

status_payload = {
    "kind": "boot_oneshot",
    "ok": True,
    "serial": serial,
    "image": image,
    "output_dir": output_dir,
    "proof_prop": proof_prop,
    "shadow_probe_prop": proof_value,
    "adb_ready": True,
    "boot_completed": True,
    "failure_stage": "",
}
collect_payload = {
    "kind": "boot_log_collect",
    "ok": True,
    "collection_succeeded": True,
    "proof_property_key": proof_key,
    "proof_property_expected": proof_value,
    "proof_property_actual": proof_value,
    "proof_property_matched": True,
}

with open(status_path, "w", encoding="utf-8") as fh:
    json.dump(status_payload, fh, indent=2, sort_keys=True)
    fh.write("\n")

with open(collect_path, "w", encoding="utf-8") as fh:
    json.dump(collect_payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

printf 'mock oneshot for %s\n' "$proof_prop"
EOF
chmod 0755 "$RC_TRIGGER_LADDER_ONESHOT_MOCK"

PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$BOOT_BUILD_RAMDISK" <<'PY'
from pathlib import Path
import sys

from cpio_edit import CpioArchive, CpioEntry, build_entry_from_path, write_cpio

ramdisk_path = Path(sys.argv[1])
tmp_dir = ramdisk_path.parent

init_path = tmp_dir / "stock-init"
init_path.write_text("stock-init\n", encoding="utf-8")
init_path.chmod(0o755)

init_rc_path = tmp_dir / "stock-init.rc"
init_rc_path.write_text(
    "on boot\n    setprop shadow.boot.base 1\n",
    encoding="utf-8",
)
init_rc_path.chmod(0o644)

ramdisk_build_prop_path = tmp_dir / "stock-ramdisk-build.prop"
ramdisk_build_prop_path.write_text(
    "ro.build.version.release=13\n",
    encoding="utf-8",
)
ramdisk_build_prop_path.chmod(0o644)

entries = [
    build_entry_from_path("init", init_path, 1),
    build_entry_from_path("system/etc/init/hw/init.rc", init_rc_path, 2),
    build_entry_from_path("system/etc/ramdisk/build.prop", ramdisk_build_prop_path, 3),
]
trailer = CpioEntry(
    name="TRAILER!!!",
    ino=0,
    mode=0,
    uid=0,
    gid=0,
    nlink=1,
    mtime=0,
    filesize=0,
    devmajor=0,
    devminor=0,
    rdevmajor=0,
    rdevminor=0,
    check=0,
    data=b"",
)
write_cpio(CpioArchive(entries + [trailer], b""), ramdisk_path)
PY

PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$BOOT_BUILD_RAMDISK_WITH_RECOVERY" <<'PY'
from pathlib import Path
import sys

from cpio_edit import CpioArchive, CpioEntry, build_entry_from_path, write_cpio

ramdisk_path = Path(sys.argv[1])
tmp_dir = ramdisk_path.parent

init_path = tmp_dir / "stock-init-with-recovery"
init_path.write_text("stock-init\n", encoding="utf-8")
init_path.chmod(0o755)

normal_init_rc_path = tmp_dir / "stock-init-with-recovery-normal.rc"
normal_init_rc_path.write_text(
    "on boot\n    setprop shadow.boot.base 1\n",
    encoding="utf-8",
)
normal_init_rc_path.chmod(0o644)

recovery_init_rc_path = tmp_dir / "stock-init-with-recovery-recovery.rc"
recovery_init_rc_path.write_text(
    "on fs\n    setprop shadow.boot.recovery 1\n",
    encoding="utf-8",
)
recovery_init_rc_path.chmod(0o644)

entries = [
    build_entry_from_path("init", init_path, 1),
    build_entry_from_path("system/etc/init/hw/init.rc", normal_init_rc_path, 2),
    build_entry_from_path("init.recovery.sunfish.rc", recovery_init_rc_path, 3),
]
trailer = CpioEntry(
    name="TRAILER!!!",
    ino=0,
    mode=0,
    uid=0,
    gid=0,
    nlink=1,
    mtime=0,
    filesize=0,
    devmajor=0,
    devminor=0,
    rdevmajor=0,
    rdevminor=0,
    check=0,
    data=b"",
)
write_cpio(CpioArchive(entries + [trailer], b""), ramdisk_path)
PY

PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$BOOT_BUILD_RAMDISK_RECOVERY_STYLE" <<'PY'
from pathlib import Path
import sys

from cpio_edit import CpioArchive, CpioEntry, build_entry_from_path, write_cpio

ramdisk_path = Path(sys.argv[1])
tmp_dir = ramdisk_path.parent

init_path = tmp_dir / "stock-init-recovery-style"
init_path.write_text("stock-init\n", encoding="utf-8")
init_path.chmod(0o755)

recovery_style_init_rc_path = tmp_dir / "stock-init-recovery-style.rc"
recovery_style_init_rc_path.write_text(
    "import /init.recovery.${ro.hardware}.rc\n\n"
    "service recovery /system/bin/recovery\n"
    "    disabled\n\n"
    "service fastbootd /system/bin/fastbootd\n"
    "    disabled\n",
    encoding="utf-8",
)
recovery_style_init_rc_path.chmod(0o644)

entries = [
    build_entry_from_path("init", init_path, 1),
    build_entry_from_path("system/etc/init/hw/init.rc", recovery_style_init_rc_path, 2),
]
trailer = CpioEntry(
    name="TRAILER!!!",
    ino=0,
    mode=0,
    uid=0,
    gid=0,
    nlink=1,
    mtime=0,
    filesize=0,
    devmajor=0,
    devminor=0,
    rdevmajor=0,
    rdevminor=0,
    check=0,
    data=b"",
)
write_cpio(CpioArchive(entries + [trailer], b""), ramdisk_path)
PY

PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$BOOT_BUILD_SYSTEM_INIT_RAMDISK" <<'PY'
from pathlib import Path
import os
import sys

from cpio_edit import CpioArchive, CpioEntry, build_entry_from_path, write_cpio

ramdisk_path = Path(sys.argv[1])
tmp_dir = ramdisk_path.parent

root_init_path = tmp_dir / "root-init"
try:
    root_init_path.unlink()
except FileNotFoundError:
    pass
os.symlink("/system/bin/init", root_init_path)

system_init_path = tmp_dir / "system-bin-init"
system_init_path.write_text("stock-system-init\n", encoding="utf-8")
system_init_path.chmod(0o755)

init_rc_path = tmp_dir / "stock-system-init.rc"
init_rc_path.write_text(
    "on boot\n    setprop shadow.boot.base 1\n",
    encoding="utf-8",
)
init_rc_path.chmod(0o644)

entries = [
    build_entry_from_path("init", root_init_path, 1),
    build_entry_from_path("system/bin/init", system_init_path, 2),
    build_entry_from_path("system/etc/init/hw/init.rc", init_rc_path, 3),
]
trailer = CpioEntry(
    name="TRAILER!!!",
    ino=0,
    mode=0,
    uid=0,
    gid=0,
    nlink=1,
    mtime=0,
    filesize=0,
    devmajor=0,
    devminor=0,
    rdevmajor=0,
    rdevminor=0,
    check=0,
    data=b"",
)
write_cpio(CpioArchive(entries + [trailer], b""), ramdisk_path)
PY

PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$BOOT_BUILD_SYSTEM_INIT_NONSTOCK_ROOT_RAMDISK" <<'PY'
from pathlib import Path
import sys

from cpio_edit import CpioArchive, CpioEntry, build_entry_from_path, write_cpio

ramdisk_path = Path(sys.argv[1])
tmp_dir = ramdisk_path.parent

root_init_path = tmp_dir / "nonstock-root-init"
root_init_path.write_text("nonstock-root-init\n", encoding="utf-8")
root_init_path.chmod(0o755)

system_init_path = tmp_dir / "nonstock-system-bin-init"
system_init_path.write_text("stock-system-init\n", encoding="utf-8")
system_init_path.chmod(0o755)

init_rc_path = tmp_dir / "nonstock-system-init.rc"
init_rc_path.write_text(
    "on boot\n    setprop shadow.boot.base 1\n",
    encoding="utf-8",
)
init_rc_path.chmod(0o644)

entries = [
    build_entry_from_path("init", root_init_path, 1),
    build_entry_from_path("system/bin/init", system_init_path, 2),
    build_entry_from_path("system/etc/init/hw/init.rc", init_rc_path, 3),
]
trailer = CpioEntry(
    name="TRAILER!!!",
    ino=0,
    mode=0,
    uid=0,
    gid=0,
    nlink=1,
    mtime=0,
    filesize=0,
    devmajor=0,
    devminor=0,
    rdevmajor=0,
    rdevminor=0,
    check=0,
    data=b"",
)
write_cpio(CpioArchive(entries + [trailer], b""), ramdisk_path)
PY

PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$BOOT_BUILD_SECOND_STAGE_RC_RAMDISK" <<'PY'
from pathlib import Path
import os
import sys

from cpio_edit import CpioArchive, CpioEntry, build_entry_from_path, write_cpio

ramdisk_path = Path(sys.argv[1])
tmp_dir = ramdisk_path.parent

root_init_path = tmp_dir / "second-stage-root-init"
try:
    root_init_path.unlink()
except FileNotFoundError:
    pass
os.symlink("/system/bin/init", root_init_path)

system_init_path = tmp_dir / "second-stage-system-bin-init"
system_init_path.write_bytes(
    b"prefix:/system/etc/init/hw/init.rc:suffix\n"
)
system_init_path.chmod(0o755)

init_rc_path = tmp_dir / "second-stage-stock-init.rc"
init_rc_path.write_text(
    "on boot\n    setprop shadow.boot.base 1\n",
    encoding="utf-8",
)
init_rc_path.chmod(0o644)

entries = [
    build_entry_from_path("init", root_init_path, 1),
    build_entry_from_path("system/bin/init", system_init_path, 2),
    build_entry_from_path("system/etc/init/hw/init.rc", init_rc_path, 3),
]
trailer = CpioEntry(
    name="TRAILER!!!",
    ino=0,
    mode=0,
    uid=0,
    gid=0,
    nlink=1,
    mtime=0,
    filesize=0,
    devmajor=0,
    devminor=0,
    rdevmajor=0,
    rdevminor=0,
    check=0,
    data=b"",
)
write_cpio(CpioArchive(entries + [trailer], b""), ramdisk_path)
PY

PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$BOOT_BUILD_RAMDISK_PROP_RAMDISK" <<'PY'
from pathlib import Path
import sys

from cpio_edit import CpioArchive, CpioEntry, build_entry_from_path, write_cpio

ramdisk_path = Path(sys.argv[1])
tmp_dir = ramdisk_path.parent

init_path = tmp_dir / "ramdisk-prop-stock-init"
init_path.write_text("stock-init\n", encoding="utf-8")
init_path.chmod(0o755)

build_prop_path = tmp_dir / "ramdisk-build.prop"
build_prop_path.write_text(
    "ro.build.version.release=13\n"
    "ro.build.version.sdk=33\n",
    encoding="utf-8",
)
build_prop_path.chmod(0o644)

entries = [
    build_entry_from_path("init", init_path, 1),
    build_entry_from_path("system/etc/ramdisk/build.prop", build_prop_path, 2),
]
trailer = CpioEntry(
    name="TRAILER!!!",
    ino=0,
    mode=0,
    uid=0,
    gid=0,
    nlink=1,
    mtime=0,
    filesize=0,
    devmajor=0,
    devminor=0,
    rdevmajor=0,
    rdevminor=0,
    check=0,
    data=b"",
)
write_cpio(CpioArchive(entries + [trailer], b""), ramdisk_path)
PY

cat >"$MOCK_BIN/adb" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$MOCK_BIN/just" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$MOCK_BIN/payload-dumper-go" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$MOCK_BIN/unpack_bootimg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

while [[ $# -gt 0 ]]; do
  case "$1" in
    --boot_img)
      shift 2
      ;;
    --format=mkbootimg)
      shift
      ;;
    *)
      echo "mock unpack_bootimg: unexpected args: $*" >&2
      exit 1
      ;;
  esac
done

mkdir -p out
cp "$MOCK_BOOT_RAMDISK" out/ramdisk
printf '%s\n' '--header_version 2 --pagesize 4096 --ramdisk /tmp/original-ramdisk --output /tmp/output.img'
EOF

cat >"$MOCK_BIN/mkbootimg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ramdisk=""
output=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ramdisk)
      ramdisk="${2:-}"
      shift 2
      ;;
    --output)
      output="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[[ -n "$ramdisk" && -n "$output" ]] || {
  echo "mock mkbootimg: missing --ramdisk or --output" >&2
  exit 1
}

cp "$ramdisk" "$output"
EOF

cat >"$MOCK_BIN/avbtool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  info_image)
    cat <<INFO
Algorithm: SHA256_RSA4096
Rollback Index: 0
Rollback Index Location: 0
Flags: 0
  Hash Algorithm: sha256
  Salt: 00
INFO
    ;;
  add_hash_footer)
    ;;
  *)
    echo "mock avbtool: unexpected args: $*" >&2
    exit 1
    ;;
esac
EOF

cat >"$MOCK_BIN/file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  *bad-init-wrapper-c-system-init-minimal*)
    printf '%s: POSIX shell script, ASCII text executable\n' "$1"
    ;;
  *shadow-gpu-smoke*|*ld-linux-aarch64.so.1|*libc.so.6|*libvulkan.so.1)
    printf '%s: ELF 64-bit LSB executable, ARM aarch64, dynamically linked\n' "$1"
    ;;
  *)
    printf '%s: ELF 64-bit LSB executable, ARM aarch64, statically linked\n' "$1"
    ;;
esac
EOF

cat >"$MOCK_BIN/llvm-readelf" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "-lW" ]]; then
  cat <<'OUT'

      [Requesting program interpreter: $MOCK_GPU_SMOKE_STORE/lib/ld-linux-aarch64.so.1]
OUT
  exit 0
fi

if [[ "\${1:-}" == "-dW" ]]; then
  case "\${2:-}" in
    *shadow-gpu-smoke)
      cat <<'OUT'
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
OUT
      ;;
  esac
  exit 0
fi

echo "mock llvm-readelf: unexpected args: \$*" >&2
exit 1
EOF

cat >"$MOCK_BIN/aarch64-unknown-linux-gnu-gcc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[[ -n "$output" ]] || {
  echo "mock gcc: missing -o output" >&2
  exit 1
}

mkdir -p "$(dirname "$output")"
printf 'mock openlog preload\n' >"$output"
chmod 0755 "$output"
EOF

cat >"$MOCK_BIN/nix" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == shell ]]; then
  shift
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      -c)
        shift
        exec "\$@"
        ;;
      *)
        shift
        ;;
    esac
  done
  exit 0
fi

if [[ "\${1:-}" != build ]]; then
  echo "mock nix: unexpected args: \$*" >&2
  exit 1
fi

out_link=""
print_out_paths=0
package_ref=""
shift
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --accept-flake-config|--no-link)
      shift
      ;;
    --print-out-paths)
      print_out_paths=1
      shift
      ;;
    --out-link)
      out_link="\${2:-}"
      shift 2
      ;;
    *)
      package_ref="\$1"
      shift
      ;;
  esac
done

case "\$package_ref" in
  *shadow-gpu-smoke-aarch64-linux-gnu*)
    if [[ "\$print_out_paths" == 1 ]]; then
      printf '%s\n' "$MOCK_GPU_SMOKE_STORE"
      exit 0
    fi
    if [[ -n "\$out_link" ]]; then
      mkdir -p "\$(dirname "\$out_link")"
      rm -rf "\$out_link"
      ln -s "$MOCK_GPU_SMOKE_STORE" "\$out_link"
      exit 0
    fi
    ;;
  *shadow-pinned-turnip-mesa-aarch64-linux*)
    printf '%s\n' "$MOCK_GPU_SMOKE_STORE"
    exit 0
    ;;
esac

case "\$package_ref" in
  *init-wrapper-c-device-system-init*)
    printf '%s\n' "$MOCK_STORE_C_SYSTEM"
    ;;
  *init-wrapper-c-device*)
    printf '%s\n' "$MOCK_STORE_C"
    ;;
  *init-wrapper-device-minimal*)
    printf '%s\n' "$MOCK_STORE_MINIMAL"
    ;;
  *init-wrapper-device*)
    printf '%s\n' "$MOCK_STORE_STANDARD"
    ;;
  *)
    echo "mock nix: unexpected package ref: build \$package_ref" >&2
    exit 1
    ;;
esac
EOF

cat >"$MOCK_BIN/nix-store" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" != "-qR" ]]; then
  echo "mock nix-store: unexpected args: \$*" >&2
  exit 1
fi

case "\${2:-}" in
  "$MOCK_GPU_SMOKE_STORE"|*shadow-gpu-smoke-aarch64-linux-gnu-result)
    printf '%s\n' "$MOCK_GPU_SMOKE_STORE"
    ;;
  *)
    printf '%s\n' "\${2:-}"
    ;;
esac
EOF

chmod 0755 \
  "$MOCK_BIN/adb" \
  "$MOCK_BIN/aarch64-unknown-linux-gnu-gcc" \
  "$MOCK_BIN/file" \
  "$MOCK_BIN/just" \
  "$MOCK_BIN/lockf" \
  "$MOCK_BIN/nix" \
  "$MOCK_BIN/nix-store" \
  "$MOCK_BIN/llvm-readelf" \
  "$MOCK_BIN/payload-dumper-go" \
  "$MOCK_BIN/unpack_bootimg" \
  "$MOCK_BIN/mkbootimg" \
  "$MOCK_BIN/avbtool"
rewrite_dynamic_bash_shebangs

assert_eq() {
  local actual expected message
  actual="$1"
  expected="$2"
  message="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "pixel_boot_tooling_smoke: $message" >&2
    echo "  actual:   $actual" >&2
    echo "  expected: $expected" >&2
    exit 1
  fi
}

assert_ne() {
  local left right message
  left="$1"
  right="$2"
  message="$3"
  if [[ "$left" == "$right" ]]; then
    echo "pixel_boot_tooling_smoke: $message" >&2
    echo "  left:  $left" >&2
    echo "  right: $right" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack needle
  haystack="$1"
  needle="$2"
  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    echo "pixel_boot_tooling_smoke: expected output to contain: $needle" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

assert_json_field() {
  local json_path key_path expected
  json_path="$1"
  key_path="$2"
  expected="$3"

  python3 - "$json_path" "$key_path" "$expected" <<'PY'
import json
import sys

json_path, key_path, expected_raw = sys.argv[1:4]
with open(json_path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

actual = payload
for part in key_path.split("/"):
    if isinstance(actual, list):
        actual = actual[int(part)]
    else:
        actual = actual[part]

if expected_raw == "true":
    expected = True
elif expected_raw == "false":
    expected = False
else:
    try:
        expected = int(expected_raw)
    except ValueError:
        expected = expected_raw

if actual != expected:
    raise SystemExit(
        f"unexpected json field {key_path!r}: actual={actual!r} expected={expected!r}"
    )
PY
}

assert_json_field_one_of() {
  local json_path key_path
  json_path="$1"
  key_path="$2"
  shift 2

  python3 - "$json_path" "$key_path" "$@" <<'PY'
import json
import sys

json_path = sys.argv[1]
key_path = sys.argv[2]
expected_raw_values = sys.argv[3:]

with open(json_path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

actual = payload
for part in key_path.split("/"):
    if isinstance(actual, list):
        actual = actual[int(part)]
    else:
        actual = actual[part]

def parse(raw: str):
    if raw == "true":
        return True
    if raw == "false":
        return False
    try:
        return int(raw)
    except ValueError:
        return raw

expected_values = [parse(raw) for raw in expected_raw_values]
if actual not in expected_values:
    raise SystemExit(
        f"unexpected json field {key_path!r}: actual={actual!r} expected one of={expected_values!r}"
    )
PY
}

assert_contains_one_of() {
  local haystack
  haystack="$1"
  shift

  for needle in "$@"; do
    if [[ "$haystack" == *"$needle"* ]]; then
      return 0
    fi
  done

  echo "pixel_boot_tooling_smoke: expected output to contain one of:" >&2
  printf '  %s\n' "$@" >&2
  echo "$haystack" >&2
  exit 1
}

prepare_cached_tmpfs_gpu_bundle() {
  local bundle_dir launcher_artifact manifest_path package_ref fingerprint
  bundle_dir="$REPO_ROOT/build/pixel/artifacts/shadow-gpu-smoke-gnu"
  launcher_artifact="$REPO_ROOT/build/pixel/artifacts/run-shadow-gpu-smoke"
  manifest_path="$bundle_dir/.bundle-manifest.json"
  package_ref="$REPO_ROOT#packages.aarch64-linux.shadow-gpu-smoke-aarch64-linux-gnu"

  fingerprint="$(
    REPO_ROOT="$REPO_ROOT" \
      TMPFS_DEVICE_DIR="$TMPFS_DEVICE_DIR" \
      TURNIP_LIB="$TMPFS_FAKE_TURNIP_LIB" \
      bash <<'EOF'
set -euo pipefail
source "$REPO_ROOT/scripts/lib/pixel_common.sh"
source "$REPO_ROOT/scripts/lib/pixel_runtime_linux_bundle_common.sh"

runtime_bundle_source_fingerprint \
  "$REPO_ROOT#packages.aarch64-linux.shadow-gpu-smoke-aarch64-linux-gnu" \
  "__bundle_device_dir_${TMPFS_DEVICE_DIR}__" \
  "$REPO_ROOT/flake.nix" \
  "$REPO_ROOT/ui/Cargo.toml" \
  "$REPO_ROOT/ui/Cargo.lock" \
  "$REPO_ROOT/ui/crates/shadow-gpu-smoke" \
  "$REPO_ROOT/ui/third_party/wgpu_context" \
  "$REPO_ROOT/scripts/pixel/pixel_prepare_gpu_smoke_bundle.sh" \
  "$REPO_ROOT/scripts/lib/pixel_runtime_linux_bundle_common.sh" \
  "$TURNIP_LIB"
EOF
  )"

  mkdir -p "$bundle_dir/lib" "$bundle_dir/share/vulkan/icd.d"
  chmod -R u+w "$bundle_dir" 2>/dev/null || true
  printf 'mock gpu smoke binary\n' >"$bundle_dir/shadow-gpu-smoke"
  chmod 0755 "$bundle_dir/shadow-gpu-smoke"
  printf 'mock vulkan loader\n' >"$bundle_dir/lib/libvulkan.so.1"
  printf 'mock freedreno\n' >"$bundle_dir/lib/libvulkan_freedreno.so"
  cat >"$bundle_dir/share/vulkan/icd.d/freedreno_icd.aarch64.json" <<EOF
{
  "ICD": {
    "api_version": "1.4.335",
    "library_arch": "64",
    "library_path": "${TMPFS_DEVICE_DIR}/lib/libvulkan_freedreno.so"
  },
  "file_format_version": "1.0.1"
}
EOF
  cat >"$launcher_artifact" <<'EOF'
#!/system/bin/sh
exit 0
EOF
  chmod 0755 "$launcher_artifact"

  python3 - "$manifest_path" "$fingerprint" "$package_ref" "$TMPFS_FAKE_TURNIP_LIB" <<'PY'
import json
import sys
from datetime import datetime, timezone

manifest_path, fingerprint, package_ref, turnip_lib = sys.argv[1:5]
payload = {
    "fingerprint": fingerprint,
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "packageRef": package_ref,
    "vendorMesaTarball": None,
    "vendorTurnipTarball": None,
    "vendorTurnipLibPath": turnip_lib,
}
with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY
}

install_tmpfs_gpu_smoke_mocks() {
  cat >"$MOCK_BIN/adb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_root="${MOCK_TMPFS_DEVICE_ROOT:?}"
device_dir="${MOCK_TMPFS_DEVICE_DIR:?}"
serial="TESTSERIAL"

map_path() {
  printf '%s%s\n' "$state_root" "$1"
}

if [[ "${1:-}" == "devices" ]]; then
  printf 'List of devices attached\n%s\tdevice\n' "$serial"
  exit 0
fi

if [[ "${1:-}" == "-s" ]]; then
  [[ "${2:-}" == "$serial" ]] || {
    echo "mock adb: unexpected serial ${2:-}" >&2
    exit 1
  }
  shift 2
fi

handle_non_root_shell() {
  local cmd="$1"
  case "$cmd" in
    *"mkdir -p '$device_dir'"*)
      mkdir -p "$(map_path "$device_dir")"
      ;;
    "[ -f '$device_dir/summary.json' ]")
      test -f "$(map_path "$device_dir/summary.json")"
      ;;
    "[ -f '$device_dir/dev-profile.tsv' ]")
      test -f "$(map_path "$device_dir/dev-profile.tsv")"
      ;;
    *)
      echo "mock adb: unsupported shell args: $cmd" >&2
      return 1
      ;;
  esac
}

handle_root_shell() {
  local cmd="$1"
  case "$cmd" in
    *"rm -rf '$device_dir'"*)
      rm -rf "$(map_path "$device_dir")"
      ;;
    *"chmod 0644 '$device_dir/summary.json'"*|*"chmod 0644 '$device_dir/dev-profile.tsv'"*)
      true
      ;;
    *"namespace-launch=1"*)
      mkdir -p "$(map_path "$device_dir")"
      cat >"$(map_path "$device_dir/dev-profile.tsv")" <<'PROFILE'
dir|755|0|0|-|-|/dev
dir|755|0|0|-|-|/dev/dri
char|666|0|0|1|3|/dev/null
char|666|0|0|1fc|0|/dev/kgsl-3d0
char|660|0|0|e2|0|/dev/dri/card0
char|660|0|0|e2|80|/dev/dri/renderD128
PROFILE
      printf '[tmpfs-dev] namespace-entered=1\n'
      printf '[tmpfs-dev] tmpfs-mounted=1\n'
      printf '[shadow-openlog] open path=/dev/kgsl-3d0 flags=O_RDONLY\n'
      printf '[shadow-openlog] open path=/dev/dri/renderD128 flags=O_RDONLY\n'
      printf 'vkEnumeratePhysicalDevices-count-query\n'
      printf 'vkEnumeratePhysicalDevices-count-query-ok count=1\n'
      printf '[tmpfs-dev] run-status=0\n'
      ;;
    *"shadow-kgsl-holder-scan-v1"*)
      printf 'format\tshadow-kgsl-holder-scan-v1\n'
      printf 'device_path\t/dev/kgsl-3d0\n'
      printf 'limits\t8192\t64\n'
      printf 'holder\t432\t7\tsurfaceflinger\t/system/bin/surfaceflinger\n'
      printf 'summary\t18\t103\t1\tfalse\n'
      ;;
    *)
      echo "mock adb: unsupported root shell args: $cmd" >&2
      return 1
      ;;
  esac
}

case "${1:-}" in
  get-state)
    printf 'device\n'
    ;;
  push)
    src="${2:?}"
    dest="${3:?}"
    mapped_dest="$(map_path "$dest")"
    if [[ -d "$src" ]]; then
      mkdir -p "$mapped_dest"
      cp -R "$src"/. "$mapped_dest"/
    else
      mkdir -p "$(dirname "$mapped_dest")"
      cp "$src" "$mapped_dest"
    fi
    ;;
  pull)
    src="${2:?}"
    dest="${3:?}"
    mapped_src="$(map_path "$src")"
    mkdir -p "$(dirname "$dest")"
    cp "$mapped_src" "$dest"
    ;;
  shell)
    shift
    if [[ "$#" -eq 1 && ( "$1" == "/debug_ramdisk/su 0 sh -c id" || "$1" == "su 0 sh -c id" ) ]]; then
      printf 'uid=0(root) gid=0(root) groups=0(root)\n'
      exit 0
    fi
    if [[ "$#" -eq 3 && ( "$1" == "/debug_ramdisk/su" || "$1" == "su" ) && "$2" == "0" && "$3" == "sh" ]]; then
      handle_root_shell "$(cat)"
      exit $?
    fi
    handle_non_root_shell "$*"
    ;;
  *)
    echo "mock adb: unsupported args: $*" >&2
    exit 1
    ;;
esac
EOF
  chmod 0755 "$MOCK_BIN/adb"
  rewrite_dynamic_bash_shebangs
}

install_fastboot_cycle_mocks() {
  cat >"$MOCK_BIN/adb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${MOCK_DEVICE_STATE_DIR:?}"
trace_mode="${MOCK_TRACE_MODE:-clean}"
trace_run_token="${MOCK_TRACE_RUN_TOKEN:-}"
trace_root_mode="${MOCK_TRACE_ROOT_MODE:-available}"
serial="${PIXEL_SERIAL:-TESTSERIAL}"
if [[ "${1:-}" == "-s" ]]; then
  serial="$2"
  shift 2
fi

advance_pending_transport() {
  local pending_transport pending_polls
  if [[ ! -f "$state_dir/pending_transport" ]]; then
    return 0
  fi

  pending_transport="$(<"$state_dir/pending_transport")"
  pending_polls="$(<"$state_dir/pending_polls")"
  pending_polls=$((pending_polls - 1))
  if (( pending_polls <= 0 )); then
    printf '%s\n' "$pending_transport" >"$state_dir/transport"
    rm -f "$state_dir/pending_transport" "$state_dir/pending_polls"
  else
    printf '%s\n' "$pending_polls" >"$state_dir/pending_polls"
  fi
}

slot_suffix() {
  printf '_%s\n' "$(<"$state_dir/active_slot")"
}

android_boot_completed() {
  if [[ -f "$state_dir/transport" ]] && [[ "$(<"$state_dir/transport")" == "adb" ]]; then
    printf '%s\n' "${MOCK_SYS_BOOT_COMPLETED:-1}"
  else
    printf '0\n'
  fi
}

prop_value() {
  case "$1" in
    ro.boot.slot_suffix)
      slot_suffix
      ;;
    ro.build.fingerprint)
      printf '%s\n' "${MOCK_BUILD_FINGERPRINT:-google/sunfish/sunfish:13/TQ3A.230805.001.S2/12655424:user/release-keys}"
      ;;
    sys.boot_completed|dev.bootcomplete)
      android_boot_completed
      ;;
    ro.boot.shadow_probe)
      printf '%s\n' "${MOCK_SHADOW_PROBE_PROP:-}"
      ;;
    ro.boot.bootreason)
      printf '%s\n' "${MOCK_RO_BOOT_BOOTREASON:-kernel_panic}"
      ;;
    sys.boot.reason)
      printf '%s\n' "${MOCK_SYS_BOOT_REASON:-kernel_panic}"
      ;;
    sys.boot.reason.last)
      printf '%s\n' "${MOCK_SYS_BOOT_REASON_LAST:-}"
      ;;
    persist.sys.boot.reason.history)
      printf '%s\n' "${MOCK_PERSIST_SYS_BOOT_REASON_HISTORY:-}"
      ;;
    ro.boot.bootreason_history)
      printf '%s\n' "${MOCK_RO_BOOT_BOOTREASON_HISTORY:-}"
      ;;
    ro.boot.bootreason_last)
      printf '%s\n' "${MOCK_RO_BOOT_BOOTREASON_LAST:-}"
      ;;
    *)
      printf '\n'
      ;;
  esac
}

print_bootreason_props() {
  local key
  for key in \
    ro.boot.bootreason \
    sys.boot.reason \
    sys.boot.reason.last \
    persist.sys.boot.reason.history \
    ro.boot.bootreason_history \
    ro.boot.bootreason_last; do
    printf '%s=%s\n' "$key" "$(prop_value "$key" | tr -d '\r\n')"
  done
}

device_path_exists() {
  local device_path existing_path
  device_path="$1"
  for existing_path in ${MOCK_EXISTING_DEVICE_PATHS:-}; do
    if [[ "$existing_path" == "$device_path" ]]; then
      return 0
    fi
  done
  return 1
}

case "${1:-}" in
  devices)
    advance_pending_transport
    printf 'List of devices attached\n'
    if [[ -f "$state_dir/transport" ]] && [[ "$(<"$state_dir/transport")" == "adb" ]]; then
      printf '%s\tdevice\n' "$serial"
    fi
    ;;
  reboot)
    if [[ "${2:-}" == "bootloader" ]]; then
      printf 'fastboot\n' >"$state_dir/transport"
      rm -f "$state_dir/pending_transport" "$state_dir/pending_polls"
      exit 0
    fi
    echo "mock adb: unsupported reboot args: $*" >&2
    exit 1
    ;;
  shell)
    shift
    if [[ "$#" -eq 1 && ( "$1" == "/debug_ramdisk/su 0 sh -c id" || "$1" == "su 0 sh -c id" ) ]]; then
      if [[ "$trace_root_mode" == "available" ]]; then
        printf 'uid=0(root) gid=0(root) groups=0(root)\n'
        exit 0
      fi
      exit 1
    fi
    if [[ "$#" -eq 3 && ( "$1" == "/debug_ramdisk/su" || "$1" == "su" ) && "$2" == "0" && "$3" == "sh" ]]; then
      if [[ "$trace_root_mode" != "available" ]]; then
        exit 1
      fi
      cmd="$(cat)"
    else
      cmd="$*"
    fi
    case "$cmd" in
      "cat /proc/sys/kernel/random/boot_id 2>/dev/null")
        printf '%s\n' "${MOCK_BOOT_ID:-11111111-2222-3333-4444-555555555555}"
        ;;
      "rm -rf '/metadata/shadow-hello-init/by-token/"*)
        token="$(printf '%s\n' "$cmd" | sed -n "s|.*'/metadata/shadow-hello-init/by-token/\\([^']*\\)'.*|\\1|p")"
        printf '%s\n' "$token" >"$state_dir/precleared_run_token"
        rm -f "$state_dir/metadata-token-$token"
        ;;
      "[ ! -e '/metadata/shadow-hello-init/by-token/"*)
        token="$(printf '%s\n' "$cmd" | sed -n "s|.*'/metadata/shadow-hello-init/by-token/\\([^']*\\)'.*|\\1|p")"
        printf '%s\n' "$token" >"$state_dir/preclear_verified_run_token"
        if [[ -e "$state_dir/metadata-token-$token" ]]; then
          exit 1
        fi
        ;;
      "getprop")
        printf '[ro.boot.slot_suffix]: [%s]\n' "$(slot_suffix | tr -d '\r\n')"
        printf '[ro.boot.bootreason]: [%s]\n' "$(prop_value ro.boot.bootreason | tr -d '\r\n')"
        printf '[sys.boot.reason]: [%s]\n' "$(prop_value sys.boot.reason | tr -d '\r\n')"
        if [[ -n "${MOCK_SHADOW_PROBE_PROP:-}" ]]; then
          printf '[ro.boot.shadow_probe]: [%s]\n' "$(prop_value ro.boot.shadow_probe | tr -d '\r\n')"
        fi
        if [[ "$trace_mode" == "matched" ]]; then
          printf '[shadow.boot.marker]: [shadow-hello-init]\n'
          printf '[shadow.boot.run_token]: [%s]\n' "$trace_run_token"
        fi
        ;;
      "getprop "*)
        prop_value "${cmd#getprop }"
        ;;
      "[ -e '/data/vendor/wifidump' ]")
        device_path_exists "/data/vendor/wifidump"
        ;;
      *'live_boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null'*)
        exit 1
        ;;
      "ls -ld '/.shadow-init-wrapper' 2>/dev/null || true")
        ;;
      "cat '/.shadow-init-wrapper/boot-id.txt' 2>/dev/null || true"|"cat '/.shadow-init-wrapper/events.log' 2>/dev/null || true"|"cat '/.shadow-init-wrapper/pid.txt' 2>/dev/null || true"|"cat '/.shadow-init-wrapper/status.txt' 2>/dev/null || true")
        ;;
      "logcat -L -d -v threadtime")
        if [[ "$trace_mode" == "matched" ]]; then
          printf '04-19 10:00:00.000 root root I shadow-hello-init: previous boot breadcrumb run_token=%s\n' "$trace_run_token"
        else
          printf '04-19 10:00:00.000 root root I bootstat: cold boot\n'
        fi
        ;;
      "dumpsys dropbox --print SYSTEM_BOOT")
        if [[ "$trace_mode" == "matched" ]]; then
          printf 'SYSTEM_BOOT\n[shadow-drm] restored previous boot trace run_token=%s\n' "$trace_run_token"
        else
          printf 'SYSTEM_BOOT\nBoot completed normally\n'
        fi
        ;;
      "dumpsys dropbox --print SYSTEM_LAST_KMSG")
        if [[ "$trace_mode" == "matched" ]]; then
          printf 'SYSTEM_LAST_KMSG\n<6>[shadow-hello-init] previous kernel breadcrumb\n'
        else
          printf 'SYSTEM_LAST_KMSG\nkernel boot without shadow tags\n'
        fi
        ;;
      "cat /dev/pmsg0")
        if [[ "$trace_mode" == "matched" ]]; then
          printf 'shadow-owned-init-run-token:%s\nshadow-owned-init-role:hello-init\nshadow-owned-init-impl:c-static\n' "$trace_run_token"
        else
          printf 'audit: pmsg readable but empty of shadow tags\n'
        fi
        ;;
      *"/sys/fs/pstore"*)
        if [[ "$trace_mode" == "matched" ]]; then
          printf '== /sys/fs/pstore/console-ramoops-0 ==\n<6>[shadow-hello-init] pstore breadcrumb run_token=%s\nshadow-owned-init-role:hello-init\n' "$trace_run_token"
        else
          printf 'no pstore entries\n'
        fi
        ;;
      *"ro.boot.bootreason"*)
        print_bootreason_props
        ;;
      "logcat -d -v threadtime"|"logcat -d 2>/dev/null || true")
        if [[ -n "${MOCK_LOGCAT_D_OUTPUT:-}" ]]; then
          printf '%s\n' "$MOCK_LOGCAT_D_OUTPUT"
        elif [[ "$trace_mode" == "matched" ]]; then
          printf '04-19 10:05:00.000 root root I shadow-drm: current boot kernel handoff summary run_token=%s\n' "$trace_run_token"
        else
          printf '04-19 10:05:00.000 root root I ActivityManager: idle\n'
        fi
        ;;
      "logcat -d -s shadow-init:I shadow-boot:I 2>/dev/null || true")
        if [[ "$trace_mode" == "matched" ]]; then
          printf '04-19 10:05:00.000 root root I shadow-drm: current boot kernel handoff summary run_token=%s\n' "$trace_run_token"
        else
          printf '04-19 10:05:00.000 root root I ActivityManager: idle\n'
        fi
        ;;
      "dmesg 2>/dev/null")
        if [[ "$trace_mode" == "matched" ]]; then
          printf '<6>[shadow-drm] current kernel snapshot run_token=%s\n' "$trace_run_token"
        else
          printf '<6>[kernel] boot complete\n'
        fi
        ;;
      "logcat -b kernel -d -v threadtime"|"logcat -b kernel -d 2>/dev/null || true")
        if [[ "$trace_mode" == "matched" ]]; then
          printf '<6>[shadow-drm] current kernel snapshot run_token=%s\n' "$trace_run_token"
        else
          printf '<6>[kernel] boot complete\n'
        fi
        ;;
      "ps -A -o USER,PID,PPID,NAME,ARGS 2>/dev/null || ps -A || true")
        printf 'USER PID PPID NAME ARGS\n'
        if [[ -n "${MOCK_PS_OUTPUT:-}" ]]; then
          printf '%s\n' "$MOCK_PS_OUTPUT"
        fi
        ;;
      *"shadow-kgsl-holder-scan-v1"*)
        printf 'format\tshadow-kgsl-holder-scan-v1\n'
        printf 'device_path\t/dev/kgsl-3d0\n'
        printf 'limits\t8192\t64\n'
        if [[ "$trace_mode" == "matched" ]]; then
          printf 'holder\t432\t7\tsurfaceflinger\t/system/bin/surfaceflinger\n'
          printf 'summary\t18\t103\t1\tfalse\n'
        else
          printf 'summary\t17\t88\t0\tfalse\n'
        fi
        ;;
      *)
        echo "mock adb: unsupported shell args: $cmd" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "mock adb: unsupported args: $*" >&2
    exit 1
    ;;
esac
EOF

  cat >"$MOCK_BIN/fastboot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_dir="${MOCK_DEVICE_STATE_DIR:?}"
probe_image="${MOCK_PROBE_IMAGE_PATH:?}"
stock_image="${MOCK_STOCK_IMAGE_PATH:?}"
serial="${PIXEL_SERIAL:-TESTSERIAL}"
if [[ "${1:-}" == "-s" ]]; then
  serial="$2"
  shift 2
fi

advance_pending_transport() {
  local pending_transport pending_polls
  if [[ ! -f "$state_dir/pending_transport" ]]; then
    return 0
  fi

  pending_transport="$(<"$state_dir/pending_transport")"
  pending_polls="$(<"$state_dir/pending_polls")"
  pending_polls=$((pending_polls - 1))
  if (( pending_polls <= 0 )); then
    printf '%s\n' "$pending_transport" >"$state_dir/transport"
    rm -f "$state_dir/pending_transport" "$state_dir/pending_polls"
  else
    printf '%s\n' "$pending_polls" >"$state_dir/pending_polls"
  fi
}

set_pending_transport() {
  local transport polls
  transport="$1"
  polls="$2"
  printf 'none\n' >"$state_dir/transport"
  printf '%s\n' "$transport" >"$state_dir/pending_transport"
  printf '%s\n' "$polls" >"$state_dir/pending_polls"
}

slot_image_type() {
  local slot
  slot="$1"
  cat "$state_dir/boot_${slot}_image"
}

case "${1:-}" in
  devices)
    advance_pending_transport
    if [[ -f "$state_dir/transport" ]] && [[ "$(<"$state_dir/transport")" == "fastboot" ]]; then
      printf '%s\tfastboot\n' "$serial"
    fi
    ;;
  getvar)
    if [[ "${2:-}" != "current-slot" ]]; then
      echo "mock fastboot: unsupported getvar args: $*" >&2
      exit 1
    fi
    printf 'current-slot: %s\n' "$(<"$state_dir/active_slot")" >&2
    ;;
  flash)
    partition="${2:-}"
    image_path="${3:-}"
    case "$partition" in
      boot_a|boot_b)
        slot="${partition#boot_}"
        ;;
      *)
        echo "mock fastboot: unsupported flash partition: $partition" >&2
        exit 1
        ;;
    esac
    if [[ "$image_path" == "$probe_image" ]]; then
      printf 'probe\n' >"$state_dir/boot_${slot}_image"
    elif [[ "$image_path" == "$stock_image" ]]; then
      printf 'stock\n' >"$state_dir/boot_${slot}_image"
    else
      printf 'other\n' >"$state_dir/boot_${slot}_image"
    fi
    ;;
  set_active)
    printf '%s\n' "${2:-}" >"$state_dir/active_slot"
    ;;
  reboot)
    active_slot="$(<"$state_dir/active_slot")"
    if [[ "$(slot_image_type "$active_slot")" == "probe" ]]; then
      if [[ "${MOCK_FASTBOOT_RETURN_MODE:-return}" == "never" ]]; then
        printf 'none\n' >"$state_dir/transport"
        rm -f "$state_dir/pending_transport" "$state_dir/pending_polls"
      else
        set_pending_transport fastboot "${MOCK_FASTBOOT_RETURN_POLLS:-2}"
      fi
    else
      set_pending_transport adb "${MOCK_ADB_RETURN_POLLS:-1}"
    fi
    ;;
  boot)
    image_path="${2:-}"
    oneshot_return_mode="${MOCK_FASTBOOT_BOOT_RETURN_MODE:-}"
    if [[ "$image_path" != "$probe_image" ]]; then
      echo "mock fastboot: expected probe image for fastboot boot: $image_path" >&2
      exit 1
    fi
    if [[ -z "$oneshot_return_mode" ]]; then
      if [[ "${MOCK_FASTBOOT_RETURN_MODE:-return}" == "never" ]]; then
        oneshot_return_mode=never
      else
        oneshot_return_mode=fastboot
      fi
    fi
    case "$oneshot_return_mode" in
      fastboot)
        set_pending_transport fastboot "${MOCK_FASTBOOT_RETURN_POLLS:-2}"
        ;;
      fastboot-cycle)
        printf 'none\n' >"$state_dir/transport"
        set_pending_transport fastboot "${MOCK_FASTBOOT_RETURN_POLLS:-2}"
        ;;
      adb)
        set_pending_transport adb "${MOCK_ADB_RETURN_POLLS:-1}"
        ;;
      never)
        printf 'none\n' >"$state_dir/transport"
        rm -f "$state_dir/pending_transport" "$state_dir/pending_polls"
        ;;
      *)
        echo "mock fastboot: unsupported oneshot return mode: $oneshot_return_mode" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "mock fastboot: unsupported args: $*" >&2
    exit 1
    ;;
esac
EOF

  chmod 0755 "$MOCK_BIN/adb" "$MOCK_BIN/fastboot"
  rewrite_dynamic_bash_shebangs
}

reset_fastboot_cycle_state() {
  mkdir -p "$MOCK_DEVICE_STATE_DIR"
  printf 'adb\n' >"$MOCK_DEVICE_STATE_DIR/transport"
  printf 'a\n' >"$MOCK_DEVICE_STATE_DIR/active_slot"
  printf 'stock\n' >"$MOCK_DEVICE_STATE_DIR/boot_a_image"
  printf 'stock\n' >"$MOCK_DEVICE_STATE_DIR/boot_b_image"
  rm -f \
    "$MOCK_DEVICE_STATE_DIR/pending_transport" \
    "$MOCK_DEVICE_STATE_DIR/pending_polls" \
    "$MOCK_DEVICE_STATE_DIR/precleared_run_token" \
    "$MOCK_DEVICE_STATE_DIR/preclear_verified_run_token"
}

assert_cpio_entry_equals() {
  local archive_path entry_name expected_data
  archive_path="$1"
  entry_name="$2"
  expected_data="$3"

  PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$archive_path" "$entry_name" "$expected_data" <<'PY'
from pathlib import Path
import sys

from cpio_edit import read_cpio

archive_path, entry_name, expected_data = sys.argv[1:4]
entries = {
    entry.name: entry.data
    for entry in read_cpio(Path(archive_path)).without_trailer()
}

if entry_name not in entries:
    raise SystemExit(f"missing cpio entry: {entry_name}")
if entries[entry_name] != expected_data.encode("utf-8"):
    raise SystemExit(
        f"unexpected cpio entry contents for {entry_name}: {entries[entry_name]!r}"
    )
PY
}

assert_cpio_entry_missing() {
  local archive_path entry_name
  archive_path="$1"
  entry_name="$2"

  PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$archive_path" "$entry_name" <<'PY'
from pathlib import Path
import sys

from cpio_edit import read_cpio

archive_path, entry_name = sys.argv[1:3]
entries = {entry.name for entry in read_cpio(Path(archive_path)).without_trailer()}

if entry_name in entries:
    raise SystemExit(f"unexpected cpio entry present: {entry_name}")
PY
}

assert_cpio_entry_startswith() {
  local archive_path entry_name prefix
  archive_path="$1"
  entry_name="$2"
  prefix="$3"

  PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$archive_path" "$entry_name" "$prefix" <<'PY'
from pathlib import Path
import sys

from cpio_edit import read_cpio

archive_path, entry_name, prefix = sys.argv[1:4]
entries = {
    entry.name: entry.data
    for entry in read_cpio(Path(archive_path)).without_trailer()
}

if entry_name not in entries:
    raise SystemExit(f"missing cpio entry: {entry_name}")
if not entries[entry_name].startswith(prefix.encode("utf-8")):
    raise SystemExit(
        f"cpio entry {entry_name} did not start with expected prefix: {entries[entry_name]!r}"
    )
PY
}

assert_cpio_entry_contains() {
  local archive_path entry_name needle
  archive_path="$1"
  entry_name="$2"
  needle="$3"

  PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$archive_path" "$entry_name" "$needle" <<'PY'
from pathlib import Path
import sys

from cpio_edit import read_cpio

archive_path, entry_name, needle = sys.argv[1:4]
entries = {
    entry.name: entry.data
    for entry in read_cpio(Path(archive_path)).without_trailer()
}

if entry_name not in entries:
    raise SystemExit(f"missing cpio entry: {entry_name}")
if needle.encode("utf-8") not in entries[entry_name]:
    raise SystemExit(
        f"cpio entry {entry_name} did not contain expected bytes: {entries[entry_name]!r}"
    )
PY
}

assert_cpio_entry_symlink_target() {
  local archive_path entry_name expected_target
  archive_path="$1"
  entry_name="$2"
  expected_target="$3"

  PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$archive_path" "$entry_name" "$expected_target" <<'PY'
from pathlib import Path
import stat
import sys

from cpio_edit import read_cpio

archive_path, entry_name, expected_target = sys.argv[1:4]
entries = {
    entry.name: entry
    for entry in read_cpio(Path(archive_path)).without_trailer()
}

if entry_name not in entries:
    raise SystemExit(f"missing cpio entry: {entry_name}")

entry = entries[entry_name]
if not stat.S_ISLNK(entry.mode):
    raise SystemExit(f"cpio entry is not a symlink: {entry_name} mode={entry.mode:o}")

actual_target = entry.data.decode("utf-8")
if actual_target != expected_target:
    raise SystemExit(
        f"unexpected symlink target for {entry_name}: {actual_target!r} != {expected_target!r}"
    )
PY
}

shared_path="$(
  env SHADOW_REPO_COMMON_ROOT="$COMMON_ROOT" \
    bash -lc 'cd "$0" && source scripts/lib/pixel_common.sh && pixel_shared_stock_boot_img' "$REPO_ROOT"
)"
assert_eq \
  "$shared_path" \
  "$COMMON_ROOT/build/shared/pixel/root/boot.img" \
  "shared stock boot path should be rooted at git common-dir"

worktree_metadata_path="$(
  env SHADOW_REPO_COMMON_ROOT="$COMMON_ROOT" \
    bash -lc 'cd "$0" && source scripts/lib/pixel_common.sh && pixel_boot_last_action_json' "$REPO_ROOT"
)"
assert_eq \
  "$worktree_metadata_path" \
  "$REPO_ROOT/build/pixel/boot/last-action.json" \
  "boot metadata must stay worktree-local"

resolved_local="$(
  env PIXEL_ROOT_STOCK_BOOT_IMG="$LOCAL_BOOT" PIXEL_SHARED_STOCK_BOOT_IMG="$SHARED_BOOT" \
    bash -lc 'cd "$0" && source scripts/lib/pixel_common.sh && pixel_resolve_stock_boot_img' "$REPO_ROOT"
)"
assert_eq \
  "$resolved_local" \
  "$LOCAL_BOOT" \
  "local stock boot image should win over the shared fallback"

rm -f "$LOCAL_BOOT"
resolved_shared="$(
  env PIXEL_ROOT_STOCK_BOOT_IMG="$LOCAL_BOOT" PIXEL_SHARED_STOCK_BOOT_IMG="$SHARED_BOOT" \
    bash -lc 'cd "$0" && source scripts/lib/pixel_common.sh && pixel_resolve_stock_boot_img' "$REPO_ROOT"
)"
assert_eq \
  "$resolved_shared" \
  "$SHARED_BOOT" \
  "shared stock boot image should be used when the worktree-local copy is missing"

named_run_root="$TMP_DIR/named-run-collision"
named_run_dir_a="$(
  bash -lc '
    cd "$0"
    source scripts/lib/pixel_common.sh
    source scripts/lib/pixel_runtime_session_common.sh
    pixel_timestamp() { printf "%s\n" "20260421T000000Z"; }
    export PIXEL_SERIAL=SERIALA
    pixel_prepare_named_run_dir "$1"
  ' "$REPO_ROOT" "$named_run_root"
)"
named_run_dir_b="$(
  bash -lc '
    cd "$0"
    source scripts/lib/pixel_common.sh
    source scripts/lib/pixel_runtime_session_common.sh
    pixel_timestamp() { printf "%s\n" "20260421T000000Z"; }
    export PIXEL_SERIAL=SERIALA
    pixel_prepare_named_run_dir "$1"
  ' "$REPO_ROOT" "$named_run_root"
)"
named_run_dir_c="$(
  bash -lc '
    cd "$0"
    source scripts/lib/pixel_common.sh
    source scripts/lib/pixel_runtime_session_common.sh
    pixel_timestamp() { printf "%s\n" "20260421T000000Z"; }
    export PIXEL_SERIAL=SERIALB
    pixel_prepare_named_run_dir "$1"
  ' "$REPO_ROOT" "$named_run_root"
)"
assert_ne \
  "$named_run_dir_a" \
  "$named_run_dir_b" \
  "same-second same-serial run dirs must not collide"
assert_ne \
  "$named_run_dir_a" \
  "$named_run_dir_c" \
  "same-second different-serial run dirs must not collide"
test -d "$named_run_dir_a"
test -d "$named_run_dir_b"
test -d "$named_run_dir_c"

oneshot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 PIXEL_SERIAL=TESTSERIAL \
    "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
      --dry-run \
      --image "$PROBE_IMAGE" \
      --output "$ONESHOT_OUTPUT" \
      --wait-ready 30 \
      --adb-timeout 45 \
      --boot-timeout 60 \
      --no-wait-boot-completed \
      --proof-prop debug.shadow.boot.rc_probe=ready \
      --proof-logcat-substring subsystem_ramdump
)"

assert_contains "$oneshot_output" "pixel_boot_oneshot: dry-run"
assert_contains "$oneshot_output" "serial=TESTSERIAL"
assert_contains "$oneshot_output" "image=$PROBE_IMAGE"
assert_contains "$oneshot_output" "output_dir=$ONESHOT_OUTPUT"
assert_contains "$oneshot_output" "metadata_path=$ONESHOT_OUTPUT/boot-action.json"
assert_contains "$oneshot_output" "collect_output_dir=$ONESHOT_OUTPUT/collect"
assert_contains "$oneshot_output" "wait_ready_secs=30"
assert_contains "$oneshot_output" "adb_timeout_secs=45"
assert_contains "$oneshot_output" "boot_timeout_secs=60"
assert_contains "$oneshot_output" "wait_boot_completed=false"
assert_contains "$oneshot_output" "proof_prop=debug.shadow.boot.rc_probe=ready"
assert_contains "$oneshot_output" "proof_logcat_substring=subsystem_ramdump"
assert_contains "$oneshot_output" "proof_ps_substring="

if [[ -e "$ONESHOT_OUTPUT" ]]; then
  echo "pixel_boot_tooling_smoke: dry-run should not create the output dir" >&2
  exit 1
fi

oneshot_adb_return_dry_run_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 PIXEL_SERIAL=TESTSERIAL \
    "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
      --dry-run \
      --image "$PROBE_IMAGE" \
      --output "$ONESHOT_ADB_RETURN_OUTPUT" \
      --adb-timeout 45 \
      --boot-timeout 60 \
      --skip-collect \
      --recover-traces-after
)"

assert_contains "$oneshot_adb_return_dry_run_output" "pixel_boot_oneshot: dry-run"
assert_contains "$oneshot_adb_return_dry_run_output" "skip_collect=true"
assert_contains "$oneshot_adb_return_dry_run_output" "recover_traces_after=true"
assert_contains "$oneshot_adb_return_dry_run_output" "recover_traces_output_dir=$ONESHOT_ADB_RETURN_OUTPUT/recover-traces"
assert_contains "$oneshot_adb_return_dry_run_output" "late_recover_adb_timeout_secs=180"
assert_contains "$oneshot_adb_return_dry_run_output" "transport_timeline_path=$ONESHOT_ADB_RETURN_OUTPUT/transport-timeline.tsv"
if grep -Fq 'collect_output_dir=' <<<"$oneshot_adb_return_dry_run_output"; then
  echo "pixel_boot_tooling_smoke: skip-collect dry-run should not advertise a collect output dir" >&2
  exit 1
fi

if [[ -e "$ONESHOT_ADB_RETURN_OUTPUT" ]]; then
  echo "pixel_boot_tooling_smoke: skip-collect dry-run should not create the output dir" >&2
  exit 1
fi

flash_run_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 PIXEL_SERIAL=TESTSERIAL \
    "$REPO_ROOT/scripts/pixel/pixel_boot_flash_run.sh" \
      --dry-run \
      --image "$PROBE_IMAGE" \
      --slot inactive \
      --output "$FLASH_RUN_OUTPUT" \
      --wait-ready 30 \
      --adb-timeout 45 \
      --boot-timeout 60 \
      --allow-active-slot \
      --recover-after \
      --proof-prop debug.shadow.boot.rc_probe=ready
)"

assert_contains "$flash_run_output" "pixel_boot_flash_run: dry-run"
assert_contains "$flash_run_output" "serial=TESTSERIAL"
assert_contains "$flash_run_output" "image=$PROBE_IMAGE"
assert_contains "$flash_run_output" "requested_slot=inactive"
assert_contains "$flash_run_output" "output_dir=$FLASH_RUN_OUTPUT"
assert_contains "$flash_run_output" "metadata_path=$FLASH_RUN_OUTPUT/boot-action.json"
assert_contains "$flash_run_output" "collect_output_dir=$FLASH_RUN_OUTPUT/collect"
assert_contains "$flash_run_output" "wait_ready_secs=30"
assert_contains "$flash_run_output" "adb_timeout_secs=45"
assert_contains "$flash_run_output" "boot_timeout_secs=60"
assert_contains "$flash_run_output" "allow_active_slot=true"
assert_contains "$flash_run_output" "recover_after=true"
assert_contains "$flash_run_output" "proof_prop=debug.shadow.boot.rc_probe=ready"
assert_contains "$flash_run_output" "activate_target=true"

if [[ -e "$FLASH_RUN_OUTPUT" ]]; then
  echo "pixel_boot_tooling_smoke: flash-run dry-run should not create the output dir" >&2
  exit 1
fi

oneshot_fastboot_return_dry_run_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 PIXEL_SERIAL=TESTSERIAL \
    "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
      --dry-run \
      --image "$PROBE_IMAGE" \
      --output "$ONESHOT_FASTBOOT_RETURN_OUTPUT" \
      --success-signal fastboot-return \
      --return-timeout 45
)"

assert_contains "$oneshot_fastboot_return_dry_run_output" "pixel_boot_oneshot: dry-run"
assert_contains "$oneshot_fastboot_return_dry_run_output" "success_signal=fastboot-return"
assert_contains "$oneshot_fastboot_return_dry_run_output" "return_timeout_secs=45"
assert_contains "$oneshot_fastboot_return_dry_run_output" "fastboot_leave_timeout_secs=15"

flash_run_fastboot_return_dry_run_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 PIXEL_SERIAL=TESTSERIAL \
    "$REPO_ROOT/scripts/pixel/pixel_boot_flash_run.sh" \
      --dry-run \
      --image "$PROBE_IMAGE" \
      --slot inactive \
      --output "$FLASH_RUN_FASTBOOT_RETURN_OUTPUT" \
      --success-signal fastboot-return \
      --return-timeout 45 \
      --recover-after
)"

assert_contains "$flash_run_fastboot_return_dry_run_output" "pixel_boot_flash_run: dry-run"
assert_contains "$flash_run_fastboot_return_dry_run_output" "success_signal=fastboot-return"
assert_contains "$flash_run_fastboot_return_dry_run_output" "return_timeout_secs=45"
assert_contains "$flash_run_fastboot_return_dry_run_output" "recover_after=true"

install_fastboot_cycle_mocks

reset_fastboot_cycle_state
oneshot_adb_logcat_proof_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    PIXEL_SERIAL=TESTSERIAL \
    PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
    MOCK_DEVICE_STATE_DIR="$MOCK_DEVICE_STATE_DIR" \
    MOCK_PROBE_IMAGE_PATH="$PROBE_IMAGE" \
    MOCK_STOCK_IMAGE_PATH="$STOCK_BOOT_IMAGE" \
    MOCK_FASTBOOT_BOOT_RETURN_MODE=adb \
    MOCK_ADB_RETURN_POLLS=2 \
    MOCK_RO_BOOT_BOOTREASON=reboot \
    MOCK_SYS_BOOT_REASON=reboot \
    MOCK_LOGCAT_D_OUTPUT='04-22 17:33:02.474  3124  3124 E subsystem_ramdump: Unable to open /sys/module/subsystem_restart/parameters/enable_ramdumps' \
    "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
      --image "$PROBE_IMAGE" \
      --output "$ONESHOT_ADB_LOGCAT_PROOF_OUTPUT" \
      --proof-logcat-substring 'subsystem_ramdump: Unable to open /sys/module/subsystem_restart/parameters/enable_ramdumps'
)"

assert_contains "$oneshot_adb_logcat_proof_output" "Collected one-shot boot evidence: $ONESHOT_ADB_LOGCAT_PROOF_OUTPUT/collect"
assert_json_field "$ONESHOT_ADB_LOGCAT_PROOF_OUTPUT/status.json" ok true
assert_json_field "$ONESHOT_ADB_LOGCAT_PROOF_OUTPUT/status.json" collect_succeeded true
assert_json_field "$ONESHOT_ADB_LOGCAT_PROOF_OUTPUT/status.json" collection_succeeded true
assert_json_field "$ONESHOT_ADB_LOGCAT_PROOF_OUTPUT/status.json" proof_mode logcat-substring
assert_json_field "$ONESHOT_ADB_LOGCAT_PROOF_OUTPUT/status.json" proof_logcat_substring "subsystem_ramdump: Unable to open /sys/module/subsystem_restart/parameters/enable_ramdumps"
assert_json_field "$ONESHOT_ADB_LOGCAT_PROOF_OUTPUT/status.json" proof_logcat_match_count 1
assert_json_field "$ONESHOT_ADB_LOGCAT_PROOF_OUTPUT/status.json" proof_logcat_matched true
assert_json_field "$ONESHOT_ADB_LOGCAT_PROOF_OUTPUT/status.json" helper_dir_present false
assert_json_field "$ONESHOT_ADB_LOGCAT_PROOF_OUTPUT/status.json" collect_status/proof_mode logcat-substring
assert_json_field "$ONESHOT_ADB_LOGCAT_PROOF_OUTPUT/status.json" collect_status/proof_logcat_match_count 1
assert_json_field "$ONESHOT_ADB_LOGCAT_PROOF_OUTPUT/collect/status.json" proof_logcat_matched true

reset_fastboot_cycle_state
oneshot_adb_device_path_proof_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    PIXEL_SERIAL=TESTSERIAL \
    PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
    MOCK_DEVICE_STATE_DIR="$MOCK_DEVICE_STATE_DIR" \
    MOCK_PROBE_IMAGE_PATH="$PROBE_IMAGE" \
    MOCK_STOCK_IMAGE_PATH="$STOCK_BOOT_IMAGE" \
    MOCK_FASTBOOT_BOOT_RETURN_MODE=adb \
    MOCK_ADB_RETURN_POLLS=2 \
    MOCK_RO_BOOT_BOOTREASON=reboot \
    MOCK_SYS_BOOT_REASON=reboot \
    MOCK_EXISTING_DEVICE_PATHS=/data/vendor/wifidump \
    "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
      --image "$PROBE_IMAGE" \
      --output "$ONESHOT_ADB_DEVICE_PATH_PROOF_OUTPUT" \
      --proof-device-path /data/vendor/wifidump
)"

assert_contains "$oneshot_adb_device_path_proof_output" "Collected one-shot boot evidence: $ONESHOT_ADB_DEVICE_PATH_PROOF_OUTPUT/collect"
assert_json_field "$ONESHOT_ADB_DEVICE_PATH_PROOF_OUTPUT/status.json" ok true
assert_json_field "$ONESHOT_ADB_DEVICE_PATH_PROOF_OUTPUT/status.json" collect_succeeded true
assert_json_field "$ONESHOT_ADB_DEVICE_PATH_PROOF_OUTPUT/status.json" proof_mode device-path
assert_json_field "$ONESHOT_ADB_DEVICE_PATH_PROOF_OUTPUT/status.json" proof_device_path /data/vendor/wifidump
assert_json_field "$ONESHOT_ADB_DEVICE_PATH_PROOF_OUTPUT/status.json" proof_device_path_present true
assert_json_field "$ONESHOT_ADB_DEVICE_PATH_PROOF_OUTPUT/status.json" collect_status/proof_mode device-path
assert_json_field "$ONESHOT_ADB_DEVICE_PATH_PROOF_OUTPUT/collect/status.json" proof_device_path_present true

reset_fastboot_cycle_state
oneshot_adb_ps_proof_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    PIXEL_SERIAL=TESTSERIAL \
    PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
    MOCK_DEVICE_STATE_DIR="$MOCK_DEVICE_STATE_DIR" \
    MOCK_PROBE_IMAGE_PATH="$PROBE_IMAGE" \
    MOCK_STOCK_IMAGE_PATH="$STOCK_BOOT_IMAGE" \
    MOCK_FASTBOOT_BOOT_RETURN_MODE=adb \
    MOCK_ADB_RETURN_POLLS=2 \
    MOCK_RO_BOOT_BOOTREASON=reboot \
    MOCK_SYS_BOOT_REASON=reboot \
    MOCK_PS_OUTPUT='radio 2312 1 qcrild2 /vendor/bin/qcrild2' \
    "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
      --image "$PROBE_IMAGE" \
      --output "$ONESHOT_ADB_PS_PROOF_OUTPUT" \
      --proof-ps-substring qcrild2
)"

assert_contains "$oneshot_adb_ps_proof_output" "Collected one-shot boot evidence: $ONESHOT_ADB_PS_PROOF_OUTPUT/collect"
assert_json_field "$ONESHOT_ADB_PS_PROOF_OUTPUT/status.json" ok true
assert_json_field "$ONESHOT_ADB_PS_PROOF_OUTPUT/status.json" collect_succeeded true
assert_json_field "$ONESHOT_ADB_PS_PROOF_OUTPUT/status.json" proof_mode ps-substring
assert_json_field "$ONESHOT_ADB_PS_PROOF_OUTPUT/status.json" proof_ps_substring qcrild2
assert_json_field "$ONESHOT_ADB_PS_PROOF_OUTPUT/status.json" proof_ps_match_count 1
assert_json_field "$ONESHOT_ADB_PS_PROOF_OUTPUT/status.json" proof_ps_matched true
assert_json_field "$ONESHOT_ADB_PS_PROOF_OUTPUT/status.json" collect_status/proof_mode ps-substring
assert_json_field "$ONESHOT_ADB_PS_PROOF_OUTPUT/collect/status.json" proof_ps_matched true

reset_fastboot_cycle_state
printf 'stale metadata\n' >"$MOCK_DEVICE_STATE_DIR/metadata-token-$PROBE_RUN_TOKEN"
printf 'b\n' >"$MOCK_DEVICE_STATE_DIR/active_slot"
oneshot_adb_return_stdout="$TMP_DIR/oneshot-adb-return.stdout"
oneshot_adb_return_stderr="$TMP_DIR/oneshot-adb-return.stderr"
set +e
env \
  PATH="$MOCK_BIN:$PATH" \
  SHADOW_BOOTIMG_SHELL=1 \
  PIXEL_SERIAL=TESTSERIAL \
  PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
  MOCK_DEVICE_STATE_DIR="$MOCK_DEVICE_STATE_DIR" \
  MOCK_PROBE_IMAGE_PATH="$PROBE_IMAGE" \
  MOCK_STOCK_IMAGE_PATH="$STOCK_BOOT_IMAGE" \
  MOCK_FASTBOOT_BOOT_RETURN_MODE=adb \
  MOCK_ADB_RETURN_POLLS=2 \
  MOCK_RO_BOOT_BOOTREASON=kernel_panic \
  MOCK_SYS_BOOT_REASON=kernel_panic \
  "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
    --image "$PROBE_IMAGE" \
    --output "$ONESHOT_ADB_RETURN_OUTPUT" \
    --skip-collect \
    --recover-traces-after \
    >"$oneshot_adb_return_stdout" \
    2>"$oneshot_adb_return_stderr"
oneshot_adb_return_status=$?
set -e
if [[ "$oneshot_adb_return_status" -eq 0 ]]; then
  echo "pixel_boot_tooling_smoke: expected adb-return oneshot failure for kernel_panic bootreason" >&2
  exit 1
fi

oneshot_adb_return_output="$(cat "$oneshot_adb_return_stdout")"
assert_contains "$oneshot_adb_return_output" "Skipped helper-dir collection for one-shot boot run"
assert_contains "$oneshot_adb_return_output" "Captured Android-side recovery bundle: $ONESHOT_ADB_RETURN_OUTPUT/recover-traces"
assert_contains "$oneshot_adb_return_output" "Recovery bundle matched shadow tags: false"
assert_contains "$oneshot_adb_return_output" "Recovery bundle matched uncorrelated shadow tags: false"
assert_contains "$oneshot_adb_return_output" "Bootreason indicates failed Android boot: ro.boot.bootreason=kernel_panic; sys.boot.reason=kernel_panic"
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" ok false
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" success_signal adb
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" hello_init_run_token "$PROBE_RUN_TOKEN"
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" hello_init_token_dir "/metadata/shadow-hello-init/by-token/$PROBE_RUN_TOKEN"
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" skip_collect true
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" collect_attempted false
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" collect_succeeded false
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" recover_traces_after true
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" recover_traces_attempted true
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" recover_traces_succeeded true
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" recover_traces_matched_any_shadow_tags false
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" recover_traces_matched_any_uncorrelated_shadow_tags false
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" recover_traces_uncorrelated_previous_boot_channels_with_matches 0
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" recover_traces_proof_ok false
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" recover_traces_absence_reason_summary pstore_empty
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" recover_traces_expected_durable_logging_summary "kmsg=true,pmsg=true"
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" token_preclear_attempted true
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" token_preclear_succeeded true
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" token_preclear_reason cleared
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" token_preclear_root_id "uid=0(root) gid=0(root) groups=0(root)"
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" boot_completed true
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" slot_after b
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" failure_stage bootreason-failure
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" bootreason_indicates_failure true
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" bootreason_failure_summary "ro.boot.bootreason=kernel_panic; sys.boot.reason=kernel_panic"
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" bootreason_props/ro.boot.bootreason kernel_panic
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" bootreason_props/sys.boot.reason kernel_panic
test -f "$ONESHOT_ADB_RETURN_OUTPUT/recover-traces/status.json"
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/recover-traces/status.json" matched_any_shadow_tags false
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/recover-traces/status.json" current_boot_channel_attempts 6
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/recover-traces/status.json" channels/kernel-current-best-effort/source_kind root-dmesg
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/recover-traces/status.json" bootreason_props/ro.boot.bootreason kernel_panic
assert_eq "$(cat "$MOCK_DEVICE_STATE_DIR/precleared_run_token")" "$PROBE_RUN_TOKEN" "oneshot should pre-clear the expected metadata run token"
assert_eq "$(cat "$MOCK_DEVICE_STATE_DIR/preclear_verified_run_token")" "$PROBE_RUN_TOKEN" "oneshot should verify the cleared metadata run token"
if [[ -e "$MOCK_DEVICE_STATE_DIR/metadata-token-$PROBE_RUN_TOKEN" ]]; then
  echo "pixel_boot_tooling_smoke: oneshot should remove stale metadata for the run token" >&2
  exit 1
fi
if [[ -e "$ONESHOT_ADB_RETURN_OUTPUT/collect" ]]; then
  echo "pixel_boot_tooling_smoke: skip-collect adb-return run should not create the helper collect dir" >&2
  exit 1
fi

reset_fastboot_cycle_state
stale_history_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    PIXEL_SERIAL=TESTSERIAL \
    PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
    MOCK_DEVICE_STATE_DIR="$MOCK_DEVICE_STATE_DIR" \
    MOCK_PROBE_IMAGE_PATH="$PROBE_IMAGE" \
    MOCK_STOCK_IMAGE_PATH="$STOCK_BOOT_IMAGE" \
    MOCK_FASTBOOT_BOOT_RETURN_MODE=adb \
    MOCK_ADB_RETURN_POLLS=2 \
    MOCK_RO_BOOT_BOOTREASON=reboot \
    MOCK_SYS_BOOT_REASON=bootloader \
    MOCK_SYS_BOOT_REASON_LAST=bootloader \
    MOCK_PERSIST_SYS_BOOT_REASON_HISTORY=$'bootloader,1700000001\nkernel_panic,1699999999' \
    "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
      --image "$PROBE_IMAGE" \
      --output "$ONESHOT_ADB_RETURN_STALE_HISTORY_OUTPUT" \
      --skip-collect \
      --recover-traces-after
)"

assert_contains "$stale_history_output" "Captured Android-side recovery bundle: $ONESHOT_ADB_RETURN_STALE_HISTORY_OUTPUT/recover-traces"
assert_json_field "$ONESHOT_ADB_RETURN_STALE_HISTORY_OUTPUT/status.json" ok true
assert_json_field "$ONESHOT_ADB_RETURN_STALE_HISTORY_OUTPUT/status.json" failure_stage ""
assert_json_field "$ONESHOT_ADB_RETURN_STALE_HISTORY_OUTPUT/status.json" bootreason_indicates_failure false
assert_json_field "$ONESHOT_ADB_RETURN_STALE_HISTORY_OUTPUT/status.json" bootreason_failure_summary ""

reset_fastboot_cycle_state
oneshot_adb_return_nowait_stdout="$TMP_DIR/oneshot-adb-return-nowait.stdout"
oneshot_adb_return_nowait_stderr="$TMP_DIR/oneshot-adb-return-nowait.stderr"
set +e
env \
  PATH="$MOCK_BIN:$PATH" \
  SHADOW_BOOTIMG_SHELL=1 \
  PIXEL_SERIAL=TESTSERIAL \
  PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
  MOCK_DEVICE_STATE_DIR="$MOCK_DEVICE_STATE_DIR" \
  MOCK_PROBE_IMAGE_PATH="$PROBE_IMAGE" \
  MOCK_STOCK_IMAGE_PATH="$STOCK_BOOT_IMAGE" \
  MOCK_FASTBOOT_BOOT_RETURN_MODE=adb \
  MOCK_ADB_RETURN_POLLS=2 \
  MOCK_SYS_BOOT_COMPLETED=0 \
  MOCK_RO_BOOT_BOOTREASON=kernel_panic \
  MOCK_SYS_BOOT_REASON=kernel_panic \
  MOCK_TRACE_MODE=matched \
  MOCK_TRACE_RUN_TOKEN="$PROBE_RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
    --image "$PROBE_IMAGE" \
    --output "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT" \
    --skip-collect \
    --recover-traces-after \
    --no-wait-boot-completed \
    >"$oneshot_adb_return_nowait_stdout" \
    2>"$oneshot_adb_return_nowait_stderr"
oneshot_adb_return_nowait_status=$?
set -e
if [[ "$oneshot_adb_return_nowait_status" -eq 0 ]]; then
  echo "pixel_boot_tooling_smoke: expected no-wait adb-return oneshot failure for kernel_panic bootreason" >&2
  exit 1
fi

oneshot_adb_return_nowait_output="$(cat "$oneshot_adb_return_nowait_stdout")"
assert_contains "$oneshot_adb_return_nowait_output" "Captured Android-side recovery bundle: $ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/recover-traces"
assert_contains "$oneshot_adb_return_nowait_output" "Recovery bundle matched shadow tags: true"
assert_contains "$oneshot_adb_return_nowait_output" "Recovery bundle matched uncorrelated shadow tags: true"
assert_contains "$oneshot_adb_return_nowait_output" "Recovery bundle uncorrelated previous-boot matches: 1"
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" ok false
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" wait_boot_completed false
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" boot_completed false
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" recover_traces_succeeded true
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" recover_traces_matched_any_shadow_tags true
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" recover_traces_matched_any_uncorrelated_shadow_tags true
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" recover_traces_previous_boot_channels_with_matches 4
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" recover_traces_uncorrelated_previous_boot_channels_with_matches 1
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" recover_traces_current_boot_channels_with_matches 4
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" recover_traces_proof_ok true
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" recover_traces_expected_durable_logging_summary "kmsg=true,pmsg=true"
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" failure_stage bootreason-failure
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" bootreason_indicates_failure true
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/recover-traces/status.json" wait_boot_completed false
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/recover-traces/status.json" matched_any_shadow_tags true
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/recover-traces/status.json" matched_any_uncorrelated_shadow_tags true
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/recover-traces/status.json" uncorrelated_previous_boot_channels_with_matches 1
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/recover-traces/status.json" current_boot_channels_with_matches 4
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/recover-traces/status.json" channels/kernel-current-best-effort/source_kind root-dmesg
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/recover-traces/status.json" android_has_kgsl_holders true
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/recover-traces/status.json" channels/kgsl-holder-scan/holder_count 1

reset_fastboot_cycle_state
oneshot_adb_late_recover_stdout="$TMP_DIR/oneshot-adb-late-recover.stdout"
oneshot_adb_late_recover_stderr="$TMP_DIR/oneshot-adb-late-recover.stderr"
set +e
env \
  PATH="$MOCK_BIN:$PATH" \
  SHADOW_BOOTIMG_SHELL=1 \
  PIXEL_SERIAL=TESTSERIAL \
  PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
  MOCK_DEVICE_STATE_DIR="$MOCK_DEVICE_STATE_DIR" \
  MOCK_PROBE_IMAGE_PATH="$PROBE_IMAGE" \
  MOCK_STOCK_IMAGE_PATH="$STOCK_BOOT_IMAGE" \
  MOCK_FASTBOOT_BOOT_RETURN_MODE=adb \
  MOCK_ADB_RETURN_POLLS=3 \
  MOCK_RO_BOOT_BOOTREASON=reboot \
  MOCK_SYS_BOOT_REASON=bootloader \
  PIXEL_BOOT_ONESHOT_LATE_RECOVER_ADB_TIMEOUT_SECS=5 \
  "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
    --image "$PROBE_IMAGE" \
    --output "$ONESHOT_ADB_LATE_RECOVER_OUTPUT" \
    --adb-timeout 1 \
    --boot-timeout 60 \
    --skip-collect \
    --recover-traces-after \
    >"$oneshot_adb_late_recover_stdout" \
    2>"$oneshot_adb_late_recover_stderr"
oneshot_adb_late_recover_status=$?
set -e
if [[ "$oneshot_adb_late_recover_status" -eq 0 ]]; then
  echo "pixel_boot_tooling_smoke: expected late-recovered wait-adb oneshot failure" >&2
  exit 1
fi
assert_contains "$(cat "$oneshot_adb_late_recover_stderr")" "pixel: timed out waiting for adb device TESTSERIAL"
oneshot_adb_late_recover_output="$(cat "$oneshot_adb_late_recover_stdout")"
assert_contains "$oneshot_adb_late_recover_output" "Late recovery after wait-adb timeout succeeded"
assert_contains "$oneshot_adb_late_recover_output" "Captured Android-side recovery bundle: $ONESHOT_ADB_LATE_RECOVER_OUTPUT/recover-traces"
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" ok false
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" failure_stage wait-adb
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" adb_ready true
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" boot_completed true
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" slot_after a
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" recover_traces_attempted true
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" recover_traces_succeeded true
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" recover_traces_reason late-wait-adb
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" recover_traces_adb_timeout_secs_used 5
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" recover_traces_proof_ok false
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" recover_traces_absence_reason_summary pstore_empty
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" bootreason_indicates_failure false
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" bootreason_props/sys.boot.reason bootloader
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" transport_initial_state none
assert_json_field_one_of "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" transport_first_none_elapsed_secs 0 1
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" transport_last_state none
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" transport_late_recovery_reached_adb true
test -f "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/recover-traces/status.json"
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/recover-traces/status.json" ok true
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/recover-traces/status.json" transport_last_state adb
test -f "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/transport-timeline.tsv"
oneshot_adb_late_recover_timeline="$(cat "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/transport-timeline.tsv")"
assert_contains "$oneshot_adb_late_recover_timeline" $'elapsed_secs\ttransport'
if [[ "$oneshot_adb_late_recover_timeline" != *$'0\tnone'* && "$oneshot_adb_late_recover_timeline" != *$'1\tnone'* ]]; then
  fail "expected late recover transport timeline to include 0 or 1 seconds in none state"
fi
assert_contains "$oneshot_adb_late_recover_timeline" 'stop:wait-adb-timeout'
assert_contains "$oneshot_adb_late_recover_timeline" 'stop:recover-traces-adb-ready'

reset_fastboot_cycle_state
oneshot_adb_late_recover_fail_stdout="$TMP_DIR/oneshot-adb-late-recover-fail.stdout"
oneshot_adb_late_recover_fail_stderr="$TMP_DIR/oneshot-adb-late-recover-fail.stderr"
set +e
env \
  PATH="$MOCK_BIN:$PATH" \
  SHADOW_BOOTIMG_SHELL=1 \
  PIXEL_SERIAL=TESTSERIAL \
  PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
  MOCK_DEVICE_STATE_DIR="$MOCK_DEVICE_STATE_DIR" \
  MOCK_PROBE_IMAGE_PATH="$PROBE_IMAGE" \
  MOCK_STOCK_IMAGE_PATH="$STOCK_BOOT_IMAGE" \
  MOCK_FASTBOOT_BOOT_RETURN_MODE=never \
  PIXEL_BOOT_ONESHOT_LATE_RECOVER_ADB_TIMEOUT_SECS=2 \
  "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
    --image "$PROBE_IMAGE" \
    --output "$ONESHOT_ADB_LATE_RECOVER_FAIL_OUTPUT" \
    --adb-timeout 1 \
    --boot-timeout 60 \
    --skip-collect \
    --recover-traces-after \
    >"$oneshot_adb_late_recover_fail_stdout" \
    2>"$oneshot_adb_late_recover_fail_stderr"
oneshot_adb_late_recover_fail_status=$?
set -e
if [[ "$oneshot_adb_late_recover_fail_status" -eq 0 ]]; then
  echo "pixel_boot_tooling_smoke: expected late-recover failure when adb never returns" >&2
  exit 1
fi
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_FAIL_OUTPUT/status.json" failure_stage wait-adb
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_FAIL_OUTPUT/status.json" recover_traces_succeeded false
test -f "$ONESHOT_ADB_LATE_RECOVER_FAIL_OUTPUT/recover-traces/status.json"
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_FAIL_OUTPUT/recover-traces/status.json" ok false
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_FAIL_OUTPUT/recover-traces/status.json" failure_stage wait-adb
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_FAIL_OUTPUT/recover-traces/status.json" transport_initial_state none
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_FAIL_OUTPUT/recover-traces/status.json" transport_last_state none
assert_contains "$(cat "$ONESHOT_ADB_LATE_RECOVER_FAIL_OUTPUT/transport-timeline.tsv")" 'stop:wait-adb-timeout'
assert_contains "$(cat "$ONESHOT_ADB_LATE_RECOVER_FAIL_OUTPUT/transport-timeline.tsv")" 'stop:recover-traces-wait-adb-timeout'

reset_fastboot_cycle_state
oneshot_adb_late_fastboot_auto_reboot_stdout="$TMP_DIR/oneshot-adb-late-fastboot-auto-reboot.stdout"
oneshot_adb_late_fastboot_auto_reboot_stderr="$TMP_DIR/oneshot-adb-late-fastboot-auto-reboot.stderr"
set +e
env \
  PATH="$MOCK_BIN:$PATH" \
  SHADOW_BOOTIMG_SHELL=1 \
  PIXEL_SERIAL=TESTSERIAL \
  PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
  MOCK_DEVICE_STATE_DIR="$MOCK_DEVICE_STATE_DIR" \
  MOCK_PROBE_IMAGE_PATH="$PROBE_IMAGE" \
  MOCK_STOCK_IMAGE_PATH="$STOCK_BOOT_IMAGE" \
  MOCK_FASTBOOT_BOOT_RETURN_MODE=fastboot-cycle \
  MOCK_FASTBOOT_RETURN_POLLS=3 \
  MOCK_ADB_RETURN_POLLS=2 \
  MOCK_RO_BOOT_BOOTREASON=reboot \
  MOCK_SYS_BOOT_REASON=bootloader \
  PIXEL_BOOT_ONESHOT_LATE_RECOVER_ADB_TIMEOUT_SECS=6 \
  "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
    --image "$PROBE_IMAGE" \
    --output "$ONESHOT_ADB_LATE_FASTBOOT_AUTO_REBOOT_OUTPUT" \
    --adb-timeout 1 \
    --boot-timeout 60 \
    --skip-collect \
    --recover-traces-after \
    >"$oneshot_adb_late_fastboot_auto_reboot_stdout" \
    2>"$oneshot_adb_late_fastboot_auto_reboot_stderr"
oneshot_adb_late_fastboot_auto_reboot_status=$?
set -e
if [[ "$oneshot_adb_late_fastboot_auto_reboot_status" -eq 0 ]]; then
  echo "pixel_boot_tooling_smoke: expected late fastboot auto-reboot oneshot failure" >&2
  exit 1
fi
oneshot_adb_late_fastboot_auto_reboot_output="$(cat "$oneshot_adb_late_fastboot_auto_reboot_stdout")"
assert_contains "$oneshot_adb_late_fastboot_auto_reboot_output" "Auto-rebooted TESTSERIAL from fastboot return after"
assert_contains "$oneshot_adb_late_fastboot_auto_reboot_output" "Late recovery after wait-adb timeout succeeded"
assert_json_field "$ONESHOT_ADB_LATE_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" failure_stage wait-adb
assert_json_field "$ONESHOT_ADB_LATE_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" fastboot_auto_reboot_attempted true
assert_json_field "$ONESHOT_ADB_LATE_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" fastboot_auto_reboot_succeeded true
assert_json_field "$ONESHOT_ADB_LATE_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" fastboot_auto_reboot_reason returned-fastboot-after-leave
assert_json_field "$ONESHOT_ADB_LATE_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" transport_last_state none
assert_json_field "$ONESHOT_ADB_LATE_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" transport_late_recovery_reached_adb true
assert_json_field "$ONESHOT_ADB_LATE_FASTBOOT_AUTO_REBOOT_OUTPUT/recover-traces/status.json" fastboot_auto_reboot_attempted true
assert_json_field "$ONESHOT_ADB_LATE_FASTBOOT_AUTO_REBOOT_OUTPUT/recover-traces/status.json" fastboot_auto_reboot_succeeded true
assert_json_field "$ONESHOT_ADB_LATE_FASTBOOT_AUTO_REBOOT_OUTPUT/recover-traces/status.json" transport_initial_state fastboot
assert_json_field "$ONESHOT_ADB_LATE_FASTBOOT_AUTO_REBOOT_OUTPUT/recover-traces/status.json" transport_last_state adb
assert_contains "$(cat "$ONESHOT_ADB_LATE_FASTBOOT_AUTO_REBOOT_OUTPUT/transport-timeline.tsv")" 'stop:wait-adb-timeout'
assert_contains "$(cat "$ONESHOT_ADB_LATE_FASTBOOT_AUTO_REBOOT_OUTPUT/transport-timeline.tsv")" $'\tfastboot\tstate'
assert_contains "$(cat "$ONESHOT_ADB_LATE_FASTBOOT_AUTO_REBOOT_OUTPUT/transport-timeline.tsv")" 'stop:recover-traces-adb-ready'

reset_fastboot_cycle_state
ONESHOT_ADB_FASTBOOT_TIMEOUT_OUTPUT="$TMP_DIR/oneshot-adb-fastboot-timeout-output"
oneshot_adb_fastboot_timeout_stdout="$TMP_DIR/oneshot-adb-fastboot-timeout.stdout"
oneshot_adb_fastboot_timeout_stderr="$TMP_DIR/oneshot-adb-fastboot-timeout.stderr"
set +e
env \
  PATH="$MOCK_BIN:$PATH" \
  SHADOW_BOOTIMG_SHELL=1 \
  PIXEL_SERIAL=TESTSERIAL \
  PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
  MOCK_DEVICE_STATE_DIR="$MOCK_DEVICE_STATE_DIR" \
  MOCK_PROBE_IMAGE_PATH="$PROBE_IMAGE" \
  MOCK_STOCK_IMAGE_PATH="$STOCK_BOOT_IMAGE" \
  MOCK_FASTBOOT_BOOT_RETURN_MODE=fastboot \
  MOCK_FASTBOOT_RETURN_POLLS=2 \
  "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
    --image "$PROBE_IMAGE" \
    --output "$ONESHOT_ADB_FASTBOOT_TIMEOUT_OUTPUT" \
    --adb-timeout 3 \
    --boot-timeout 60 \
    --skip-collect \
    >"$oneshot_adb_fastboot_timeout_stdout" \
    2>"$oneshot_adb_fastboot_timeout_stderr"
oneshot_adb_fastboot_timeout_status=$?
set -e
if [[ "$oneshot_adb_fastboot_timeout_status" -eq 0 ]]; then
  echo "pixel_boot_tooling_smoke: expected adb-mode oneshot timeout when device returns to fastboot" >&2
  exit 1
fi
assert_contains "$(cat "$oneshot_adb_fastboot_timeout_stderr")" "pixel: timed out waiting for adb device TESTSERIAL"
assert_json_field "$ONESHOT_ADB_FASTBOOT_TIMEOUT_OUTPUT/status.json" failure_stage wait-adb
assert_json_field "$ONESHOT_ADB_FASTBOOT_TIMEOUT_OUTPUT/status.json" transport_initial_state fastboot
assert_json_field_one_of "$ONESHOT_ADB_FASTBOOT_TIMEOUT_OUTPUT/status.json" transport_first_fastboot_elapsed_secs 0 1
assert_json_field "$ONESHOT_ADB_FASTBOOT_TIMEOUT_OUTPUT/status.json" transport_last_state fastboot
test -f "$ONESHOT_ADB_FASTBOOT_TIMEOUT_OUTPUT/transport-timeline.tsv"
assert_contains "$(cat "$ONESHOT_ADB_FASTBOOT_TIMEOUT_OUTPUT/transport-timeline.tsv")" $'0\tfastboot'

reset_fastboot_cycle_state
oneshot_adb_fastboot_auto_reboot_stdout="$TMP_DIR/oneshot-adb-fastboot-auto-reboot.stdout"
oneshot_adb_fastboot_auto_reboot_stderr="$TMP_DIR/oneshot-adb-fastboot-auto-reboot.stderr"
set +e
env \
  PATH="$MOCK_BIN:$PATH" \
  SHADOW_BOOTIMG_SHELL=1 \
  PIXEL_SERIAL=TESTSERIAL \
  PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
  MOCK_DEVICE_STATE_DIR="$MOCK_DEVICE_STATE_DIR" \
  MOCK_PROBE_IMAGE_PATH="$PROBE_IMAGE" \
  MOCK_STOCK_IMAGE_PATH="$STOCK_BOOT_IMAGE" \
  MOCK_FASTBOOT_BOOT_RETURN_MODE=fastboot-cycle \
  MOCK_FASTBOOT_RETURN_POLLS=3 \
  MOCK_ADB_RETURN_POLLS=2 \
  MOCK_RO_BOOT_BOOTREASON=reboot \
  MOCK_SYS_BOOT_REASON=bootloader \
  "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
    --image "$PROBE_IMAGE" \
    --output "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT" \
    --adb-timeout 6 \
    --boot-timeout 60 \
    --skip-collect \
    >"$oneshot_adb_fastboot_auto_reboot_stdout" \
    2>"$oneshot_adb_fastboot_auto_reboot_stderr"
oneshot_adb_fastboot_auto_reboot_status=$?
set -e
if [[ "$oneshot_adb_fastboot_auto_reboot_status" -eq 0 ]]; then
  echo "pixel_boot_tooling_smoke: expected adb-mode oneshot failure after fastboot auto-reboot" >&2
  exit 1
fi
oneshot_adb_fastboot_auto_reboot_output="$(cat "$oneshot_adb_fastboot_auto_reboot_stdout")"
assert_contains "$oneshot_adb_fastboot_auto_reboot_output" "Auto-rebooted TESTSERIAL from fastboot return after"
assert_contains "$oneshot_adb_fastboot_auto_reboot_output" "Run returned to fastboot and was auto-rebooted to Android by the host"
assert_json_field "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" failure_stage fastboot-return-auto-rebooted
assert_json_field "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" adb_ready true
assert_json_field "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" slot_after a
assert_json_field "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" fastboot_auto_reboot_attempted true
assert_json_field "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" fastboot_auto_reboot_succeeded true
assert_json_field "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" fastboot_auto_reboot_reason returned-fastboot-after-leave
assert_json_field "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" transport_initial_state none
assert_json_field_one_of "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" transport_first_none_elapsed_secs 0 1
assert_json_field "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" transport_last_state adb
test -f "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT/transport-timeline.tsv"
transport_timeline_contents="$(cat "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT/transport-timeline.tsv")"
assert_contains_one_of "$transport_timeline_contents" $'0\tnone' $'1\tnone'
assert_contains "$transport_timeline_contents" $'\tfastboot'

reset_fastboot_cycle_state
oneshot_fastboot_return_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    PIXEL_SERIAL=TESTSERIAL \
    PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
    MOCK_DEVICE_STATE_DIR="$MOCK_DEVICE_STATE_DIR" \
    MOCK_PROBE_IMAGE_PATH="$PROBE_IMAGE" \
    MOCK_STOCK_IMAGE_PATH="$STOCK_BOOT_IMAGE" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
      --image "$PROBE_IMAGE" \
      --output "$ONESHOT_FASTBOOT_RETURN_OUTPUT" \
      --success-signal fastboot-return \
      --return-timeout 4
)"

assert_contains "$oneshot_fastboot_return_output" "Observed fastboot return after"
assert_json_field "$ONESHOT_FASTBOOT_RETURN_OUTPUT/status.json" ok true
assert_json_field "$ONESHOT_FASTBOOT_RETURN_OUTPUT/status.json" success_signal fastboot-return
assert_json_field "$ONESHOT_FASTBOOT_RETURN_OUTPUT/status.json" collect_attempted false
assert_json_field "$ONESHOT_FASTBOOT_RETURN_OUTPUT/status.json" collect_succeeded false
assert_json_field "$ONESHOT_FASTBOOT_RETURN_OUTPUT/status.json" fastboot_departed true
assert_json_field "$ONESHOT_FASTBOOT_RETURN_OUTPUT/status.json" fastboot_returned true
assert_json_field "$ONESHOT_FASTBOOT_RETURN_OUTPUT/status.json" fastboot_slot_after_return a

reset_fastboot_cycle_state
oneshot_fastboot_return_fail_stdout="$TMP_DIR/oneshot-fastboot-return-fail.stdout"
oneshot_fastboot_return_fail_stderr="$TMP_DIR/oneshot-fastboot-return-fail.stderr"
set +e
env \
  PATH="$MOCK_BIN:$PATH" \
  SHADOW_BOOTIMG_SHELL=1 \
  PIXEL_SERIAL=TESTSERIAL \
  PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
  MOCK_DEVICE_STATE_DIR="$MOCK_DEVICE_STATE_DIR" \
  MOCK_PROBE_IMAGE_PATH="$PROBE_IMAGE" \
  MOCK_STOCK_IMAGE_PATH="$STOCK_BOOT_IMAGE" \
  MOCK_FASTBOOT_RETURN_MODE=never \
  "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
    --image "$PROBE_IMAGE" \
    --output "$ONESHOT_FASTBOOT_RETURN_FAIL_OUTPUT" \
    --success-signal fastboot-return \
    --return-timeout 2 \
    >"$oneshot_fastboot_return_fail_stdout" \
    2>"$oneshot_fastboot_return_fail_stderr"
oneshot_fastboot_return_fail_status=$?
set -e
if [[ "$oneshot_fastboot_return_fail_status" -eq 0 ]]; then
  echo "pixel_boot_tooling_smoke: expected fastboot-return oneshot failure" >&2
  exit 1
fi
assert_contains "$(cat "$oneshot_fastboot_return_fail_stderr")" "timed out waiting for fastboot device TESTSERIAL to return after leaving fastboot"
assert_json_field "$ONESHOT_FASTBOOT_RETURN_FAIL_OUTPUT/status.json" ok false
assert_json_field "$ONESHOT_FASTBOOT_RETURN_FAIL_OUTPUT/status.json" failure_stage wait-fastboot-return
assert_json_field "$ONESHOT_FASTBOOT_RETURN_FAIL_OUTPUT/status.json" collect_attempted false
assert_json_field "$ONESHOT_FASTBOOT_RETURN_FAIL_OUTPUT/status.json" fastboot_departed true
assert_json_field "$ONESHOT_FASTBOOT_RETURN_FAIL_OUTPUT/status.json" fastboot_returned false

reset_fastboot_cycle_state
flash_run_fastboot_return_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    PIXEL_SERIAL=TESTSERIAL \
    PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
    PIXEL_ROOT_STOCK_BOOT_IMG="$STOCK_BOOT_IMAGE" \
    MOCK_DEVICE_STATE_DIR="$MOCK_DEVICE_STATE_DIR" \
    MOCK_PROBE_IMAGE_PATH="$PROBE_IMAGE" \
    MOCK_STOCK_IMAGE_PATH="$STOCK_BOOT_IMAGE" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_flash_run.sh" \
      --image "$PROBE_IMAGE" \
      --slot inactive \
      --output "$FLASH_RUN_FASTBOOT_RETURN_OUTPUT" \
      --success-signal fastboot-return \
      --return-timeout 4 \
      --recover-after
)"

assert_contains "$flash_run_fastboot_return_output" "Observed fastboot return after"
assert_json_field "$FLASH_RUN_FASTBOOT_RETURN_OUTPUT/status.json" ok true
assert_json_field "$FLASH_RUN_FASTBOOT_RETURN_OUTPUT/status.json" success_signal fastboot-return
assert_json_field "$FLASH_RUN_FASTBOOT_RETURN_OUTPUT/status.json" flash_succeeded true
assert_json_field "$FLASH_RUN_FASTBOOT_RETURN_OUTPUT/status.json" collect_attempted false
assert_json_field "$FLASH_RUN_FASTBOOT_RETURN_OUTPUT/status.json" collect_succeeded false
assert_json_field "$FLASH_RUN_FASTBOOT_RETURN_OUTPUT/status.json" fastboot_departed true
assert_json_field "$FLASH_RUN_FASTBOOT_RETURN_OUTPUT/status.json" fastboot_returned true
assert_json_field "$FLASH_RUN_FASTBOOT_RETURN_OUTPUT/status.json" fastboot_slot_after_return b
assert_json_field "$FLASH_RUN_FASTBOOT_RETURN_OUTPUT/status.json" recover_attempted true
assert_json_field "$FLASH_RUN_FASTBOOT_RETURN_OUTPUT/status.json" recover_succeeded true

wrapper_build_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --wrapper "$WRAPPER_STANDARD_BIN" \
      --key "$AVB_KEY_PATH" \
      --output "$WRAPPER_OUTPUT_IMAGE" \
      --add "init.extra.rc=$ADDED_RC"
)"
assert_contains "$wrapper_build_output" "Build mode: wrapper"
assert_contains "$wrapper_build_output" "Wrapper mode: standard"
assert_cpio_entry_equals "$WRAPPER_OUTPUT_IMAGE" init $'#!/system/bin/sh\n# shadow-init-wrapper-mode:standard\necho wrapper-standard\n'
assert_cpio_entry_equals "$WRAPPER_OUTPUT_IMAGE" init.stock $'stock-init\n'
assert_cpio_entry_equals "$WRAPPER_OUTPUT_IMAGE" init.extra.rc $'import /init.extra.rc\n'
assert_cpio_entry_equals "$WRAPPER_OUTPUT_IMAGE" system/etc/init/hw/init.rc $'on boot\n    setprop shadow.boot.base 1\n'

wrapper_helper_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 INIT_WRAPPER_OUT="$WRAPPER_BUILD_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_build_init_wrapper.sh" --mode standard
)"
assert_contains "$wrapper_helper_output" "Built init-wrapper (standard) -> $WRAPPER_BUILD_OUTPUT"
assert_contains "$(cat "$WRAPPER_BUILD_OUTPUT")" "shadow-init-wrapper-mode:standard"

minimal_wrapper_helper_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 INIT_WRAPPER_OUT="$MINIMAL_BUILD_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_build_init_wrapper.sh" --mode minimal
)"
assert_contains "$minimal_wrapper_helper_output" "Built init-wrapper (minimal) -> $MINIMAL_BUILD_OUTPUT"
assert_contains "$(cat "$MINIMAL_BUILD_OUTPUT")" "shadow-init-wrapper-mode:minimal"

c_wrapper_helper_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 \
    "$REPO_ROOT/scripts/pixel/pixel_build_init_wrapper_c.sh" --output "$C_WRAPPER_BUILD_OUTPUT"
)"
assert_contains "$c_wrapper_helper_output" "Built init-wrapper-c (minimal) -> $C_WRAPPER_BUILD_OUTPUT"
assert_contains "$c_wrapper_helper_output" "Wrapper entry path: /init"
assert_contains "$c_wrapper_helper_output" "Wrapper handoff target: /init.stock"
assert_contains "$(cat "$C_WRAPPER_BUILD_OUTPUT")" "shadow-init-wrapper-mode:minimal"
assert_contains "$(cat "$C_WRAPPER_BUILD_OUTPUT")" "shadow-init-wrapper-impl:tinyc-direct"
assert_contains "$(cat "$C_WRAPPER_BUILD_OUTPUT")" "shadow-init-wrapper-path:/init"
assert_contains "$(cat "$C_WRAPPER_BUILD_OUTPUT")" "shadow-init-wrapper-target:/init.stock"

system_c_wrapper_helper_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 \
    "$REPO_ROOT/scripts/pixel/pixel_build_init_wrapper_c.sh" \
      --output "$C_WRAPPER_SYSTEM_BUILD_OUTPUT" \
      --stock-path /system/bin/init.stock
)"
assert_contains "$system_c_wrapper_helper_output" "Built init-wrapper-c (minimal) -> $C_WRAPPER_SYSTEM_BUILD_OUTPUT"
assert_contains "$system_c_wrapper_helper_output" "Wrapper entry path: /system/bin/init"
assert_contains "$system_c_wrapper_helper_output" "Wrapper handoff target: /system/bin/init.stock"
assert_contains "$(cat "$C_WRAPPER_SYSTEM_BUILD_OUTPUT")" "shadow-init-wrapper-mode:minimal"
assert_contains "$(cat "$C_WRAPPER_SYSTEM_BUILD_OUTPUT")" "shadow-init-wrapper-impl:tinyc-direct"
assert_contains "$(cat "$C_WRAPPER_SYSTEM_BUILD_OUTPUT")" "shadow-init-wrapper-path:/system/bin/init"
assert_contains "$(cat "$C_WRAPPER_SYSTEM_BUILD_OUTPUT")" "shadow-init-wrapper-target:/system/bin/init.stock"

minimal_wrapper_build_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build.sh" \
      --wrapper-mode minimal \
      --input "$BOOT_BUILD_INPUT" \
      --wrapper "$WRAPPER_MINIMAL_BIN" \
      --key "$AVB_KEY_PATH" \
      --output "$MINIMAL_WRAPPER_OUTPUT_IMAGE"
)"
assert_contains "$minimal_wrapper_build_output" "Build mode: wrapper"
assert_contains "$minimal_wrapper_build_output" "Wrapper mode: minimal"
assert_cpio_entry_equals "$MINIMAL_WRAPPER_OUTPUT_IMAGE" init $'#!/system/bin/sh\n# shadow-init-wrapper-mode:minimal\necho wrapper-minimal\n'
assert_cpio_entry_equals "$MINIMAL_WRAPPER_OUTPUT_IMAGE" init.stock $'stock-init\n'

c_wrapper_build_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build.sh" \
      --wrapper-mode minimal \
      --input "$BOOT_BUILD_INPUT" \
      --wrapper "$C_WRAPPER_BUILD_OUTPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$C_WRAPPER_OUTPUT_IMAGE"
)"
assert_contains "$c_wrapper_build_output" "Build mode: wrapper"
assert_contains "$c_wrapper_build_output" "Wrapper mode: minimal"
assert_cpio_entry_equals "$C_WRAPPER_OUTPUT_IMAGE" init $'#!/system/bin/sh\n# shadow-init-wrapper-mode:minimal\n# shadow-init-wrapper-impl:tinyc-direct\n# shadow-init-wrapper-path:/init\n# shadow-init-wrapper-target:/init.stock\necho wrapper-c-minimal\n'
assert_cpio_entry_equals "$C_WRAPPER_OUTPUT_IMAGE" init.stock $'stock-init\n'

if env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_build.sh" \
    --wrapper-mode minimal \
    --input "$BOOT_BUILD_INPUT" \
    --wrapper "$WRAPPER_STANDARD_BIN" \
    --key "$AVB_KEY_PATH" \
    --output "$TMP_DIR/should-fail-wrapper-mode-mismatch.img" >/dev/null 2>&1; then
  echo "pixel_boot_tooling_smoke: minimal wrapper build should reject a standard wrapper binary" >&2
  exit 1
fi

stock_init_build_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build.sh" \
      --stock-init \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$STOCK_INIT_OUTPUT_IMAGE" \
      --add "init.extra.rc=$ADDED_RC" \
      --replace "system/etc/init/hw/init.rc=$PATCHED_INIT_RC"
)"
assert_contains "$stock_init_build_output" "Build mode: stock-init"
assert_cpio_entry_equals "$STOCK_INIT_OUTPUT_IMAGE" init $'stock-init\n'
assert_cpio_entry_missing "$STOCK_INIT_OUTPUT_IMAGE" init.stock
assert_cpio_entry_equals "$STOCK_INIT_OUTPUT_IMAGE" init.extra.rc $'import /init.extra.rc\n'
assert_cpio_entry_equals "$STOCK_INIT_OUTPUT_IMAGE" system/etc/init/hw/init.rc $'import /init.shadow.rc\n\non boot\n    setprop debug.shadow.boot.rc_probe ready\n'

cmdline_probe_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_cmdline_probe.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$CMDLINE_PROBE_OUTPUT_IMAGE" \
      --androidboot shadow_probe=cmdline-smoke \
      --androidboot init_rc=/system/etc/init/hw/init.rc \
      --keep-work-dir
)"
assert_contains "$cmdline_probe_output" "Build mode: stock-init"
assert_contains "$cmdline_probe_output" "Extra cmdline tokens: 2"
assert_contains "$cmdline_probe_output" "Probe mode: cmdline"
assert_contains "$cmdline_probe_output" "Cmdline token: androidboot.shadow_probe=cmdline-smoke"
assert_contains "$cmdline_probe_output" "Cmdline token: androidboot.init_rc=/system/etc/init/hw/init.rc"
assert_cpio_entry_equals "$CMDLINE_PROBE_OUTPUT_IMAGE" init $'stock-init\n'
cmdline_probe_workdir="$(printf '%s\n' "$cmdline_probe_output" | awk -F': ' '/^Kept workdir: /{print $2; exit}')"
if [[ -z "$cmdline_probe_workdir" ]]; then
  echo "pixel_boot_tooling_smoke: cmdline probe output did not report a kept workdir" >&2
  exit 1
fi
assert_contains "$(cat "$cmdline_probe_workdir/mkbootimg_args.modified.txt")" "androidboot.shadow_probe=cmdline-smoke"
assert_contains "$(cat "$cmdline_probe_workdir/mkbootimg_args.modified.txt")" "androidboot.init_rc=/system/etc/init/hw/init.rc"

init_symlink_build_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_init_symlink_probe.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$INIT_SYMLINK_OUTPUT_IMAGE"
)"
assert_contains "$init_symlink_build_output" "Build mode: stock-init"
assert_contains "$init_symlink_build_output" "Extra renamed entries: 1"
assert_contains "$init_symlink_build_output" "Extra added entries: 1"
assert_contains "$init_symlink_build_output" "Probe mode: init-symlink"
assert_contains "$init_symlink_build_output" "Init path mutation: rename init=init.stock and restore /init as a symlink"
assert_contains "$init_symlink_build_output" "Init symlink target: init.stock"
assert_cpio_entry_symlink_target "$INIT_SYMLINK_OUTPUT_IMAGE" init "init.stock"
assert_cpio_entry_equals "$INIT_SYMLINK_OUTPUT_IMAGE" init.stock $'stock-init\n'

system_init_symlink_build_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_SYSTEM_INIT_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_system_init_symlink_probe.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$SYSTEM_INIT_SYMLINK_OUTPUT_IMAGE"
)"
assert_contains "$system_init_symlink_build_output" "Build mode: stock-init"
assert_contains "$system_init_symlink_build_output" "Extra renamed entries: 1"
assert_contains "$system_init_symlink_build_output" "Extra added entries: 1"
assert_contains "$system_init_symlink_build_output" "Probe mode: system-init-symlink"
assert_contains "$system_init_symlink_build_output" "Root init path: preserve stock /init -> /system/bin/init symlink"
assert_contains "$system_init_symlink_build_output" "System init mutation: rename system/bin/init=system/bin/init.stock and restore system/bin/init as a symlink"
assert_contains "$system_init_symlink_build_output" "System init symlink target: init.stock"
assert_cpio_entry_symlink_target "$SYSTEM_INIT_SYMLINK_OUTPUT_IMAGE" init "/system/bin/init"
assert_cpio_entry_symlink_target "$SYSTEM_INIT_SYMLINK_OUTPUT_IMAGE" system/bin/init "init.stock"
assert_cpio_entry_equals "$SYSTEM_INIT_SYMLINK_OUTPUT_IMAGE" system/bin/init.stock $'stock-system-init\n'

system_init_wrapper_build_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_SYSTEM_INIT_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_system_init_wrapper_probe.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$SYSTEM_INIT_WRAPPER_OUTPUT_IMAGE"
)"
assert_contains "$system_init_wrapper_build_output" "Build mode: stock-init"
assert_contains "$system_init_wrapper_build_output" "Extra renamed entries: 1"
assert_contains "$system_init_wrapper_build_output" "Extra added entries: 1"
assert_contains "$system_init_wrapper_build_output" "Probe mode: system-init-wrapper"
assert_contains "$system_init_wrapper_build_output" "Root init path: preserve stock /init -> /system/bin/init symlink"
assert_contains "$system_init_wrapper_build_output" "System init mutation: rename system/bin/init=system/bin/init.stock and replace system/bin/init with an exact-path wrapper"
assert_contains "$system_init_wrapper_build_output" "Wrapper entry path: /system/bin/init"
assert_contains "$system_init_wrapper_build_output" "Wrapper handoff target: /system/bin/init.stock"
assert_cpio_entry_symlink_target "$SYSTEM_INIT_WRAPPER_OUTPUT_IMAGE" init "/system/bin/init"
assert_cpio_entry_equals "$SYSTEM_INIT_WRAPPER_OUTPUT_IMAGE" system/bin/init $'#!/system/bin/sh\n# shadow-init-wrapper-mode:minimal\n# shadow-init-wrapper-impl:tinyc-direct\n# shadow-init-wrapper-path:/system/bin/init\n# shadow-init-wrapper-target:/system/bin/init.stock\necho wrapper-c-system-init-minimal\n'
assert_cpio_entry_equals "$SYSTEM_INIT_WRAPPER_OUTPUT_IMAGE" system/bin/init.stock $'stock-system-init\n'

set +e
system_init_nonstock_root_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_SYSTEM_INIT_NONSTOCK_ROOT_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_system_init_symlink_probe.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-system-init-symlink-nonstock-root.img" 2>&1
)"
system_init_nonstock_root_status="$?"
set -e
if [[ "$system_init_nonstock_root_status" -eq 0 ]]; then
  echo "pixel_boot_tooling_smoke: system-init symlink probe should reject a non-stock root /init shape" >&2
  exit 1
fi
assert_contains "$system_init_nonstock_root_output" "expected stock root /init symlink to /system/bin/init"

set +e
system_init_wrapper_mismatch_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_SYSTEM_INIT_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_system_init_wrapper_probe.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --wrapper "$C_WRAPPER_BUILD_OUTPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-system-init-wrapper-mismatch.img" 2>&1
)"
system_init_wrapper_mismatch_status="$?"
set -e
if [[ "$system_init_wrapper_mismatch_status" -eq 0 ]]; then
  echo "pixel_boot_tooling_smoke: system-init wrapper probe should reject the root-init wrapper variant" >&2
  exit 1
fi
assert_contains "$system_init_wrapper_mismatch_output" "wrapper binary is missing the expected entry-path sentinel: shadow-init-wrapper-path:/system/bin/init"

set +e
system_init_wrapper_nonelf_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_SYSTEM_INIT_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_system_init_wrapper_probe.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --wrapper "$BAD_C_WRAPPER_SYSTEM_BUILD_OUTPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-system-init-wrapper-nonelf.img" 2>&1
)"
system_init_wrapper_nonelf_status="$?"
set -e
if [[ "$system_init_wrapper_nonelf_status" -eq 0 ]]; then
  echo "pixel_boot_tooling_smoke: system-init wrapper probe should reject a non-ELF explicit wrapper" >&2
  exit 1
fi
assert_contains "$system_init_wrapper_nonelf_output" "expected an arm64 wrapper binary"

set +e
system_init_wrapper_wrong_target_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_SYSTEM_INIT_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_system_init_wrapper_probe.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --wrapper "$WRONG_TARGET_C_WRAPPER_SYSTEM_BUILD_OUTPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-system-init-wrapper-wrong-target.img" 2>&1
)"
system_init_wrapper_wrong_target_status="$?"
set -e
if [[ "$system_init_wrapper_wrong_target_status" -eq 0 ]]; then
  echo "pixel_boot_tooling_smoke: system-init wrapper probe should reject the wrong handoff target variant" >&2
  exit 1
fi
assert_contains "$system_init_wrapper_wrong_target_output" "wrapper binary is missing the expected handoff-path sentinel: shadow-init-wrapper-target:/system/bin/init.stock"

log_probe_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_log_probe.sh" \
      --stock-init \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$LOG_PROBE_OUTPUT_IMAGE" \
      --trigger post-fs-data \
      --device-log-root /data/local/tmp/shadow-boot
)"
assert_contains "$log_probe_output" "Build mode: stock-init"
assert_contains "$log_probe_output" "Patch target: system/etc/init/hw/init.rc"
assert_contains "$log_probe_output" "Patch target profile: unclassified"
assert_cpio_entry_equals "$LOG_PROBE_OUTPUT_IMAGE" init $'stock-init\n'
assert_cpio_entry_missing "$LOG_PROBE_OUTPUT_IMAGE" init.stock
assert_cpio_entry_startswith "$LOG_PROBE_OUTPUT_IMAGE" system/etc/init/hw/init.rc $'import /init.shadow.rc\n'
assert_cpio_entry_startswith "$LOG_PROBE_OUTPUT_IMAGE" init.shadow.rc $'on post-fs-data\n'
assert_cpio_entry_startswith "$LOG_PROBE_OUTPUT_IMAGE" shadow-boot-helper $'#!/system/bin/sh\n'

log_probe_prefers_normal_anchor_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK_WITH_RECOVERY" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_log_probe.sh" \
      --stock-init \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$LOG_PROBE_OUTPUT_IMAGE" \
      --trigger post-fs-data \
      --device-log-root /data/local/tmp/shadow-boot
)"
assert_contains "$log_probe_prefers_normal_anchor_output" "Patch target: system/etc/init/hw/init.rc"
assert_contains "$log_probe_prefers_normal_anchor_output" "Patch target profile: unclassified"
assert_cpio_entry_startswith "$LOG_PROBE_OUTPUT_IMAGE" system/etc/init/hw/init.rc $'import /init.shadow.rc\n'

log_probe_recovery_style_anchor_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK_RECOVERY_STYLE" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_log_probe.sh" \
      --stock-init \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$LOG_PROBE_OUTPUT_IMAGE" \
      --trigger post-fs-data \
      --device-log-root /data/local/tmp/shadow-boot
)"
assert_contains "$log_probe_recovery_style_anchor_output" "Patch target profile: recovery-style"

log_preflight_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_log_probe.sh" \
      --stock-init \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$LOG_PREFLIGHT_OUTPUT_IMAGE" \
      --trigger post-fs-data \
      --device-log-root /data/local/tmp/shadow-boot \
      --preflight-profile phase1-shell
)"
assert_contains "$log_preflight_output" "Build mode: stock-init"
assert_contains "$log_preflight_output" "Preflight profile: phase1-shell"
assert_cpio_entry_contains "$LOG_PREFLIGHT_OUTPUT_IMAGE" init.shadow.rc 'setprop debug.shadow.boot.preflight.import triggered'
assert_cpio_entry_contains "$LOG_PREFLIGHT_OUTPUT_IMAGE" system/etc/ramdisk/build.prop 'debug.shadow.boot.preflight.second_stage=ready'
assert_cpio_entry_contains "$LOG_PREFLIGHT_OUTPUT_IMAGE" shadow-boot-helper-launcher 'setprop "$preflight_launch_proof_key" "$preflight_launch_proof_value"'
assert_cpio_entry_contains "$LOG_PREFLIGHT_OUTPUT_IMAGE" shadow-boot-helper-launcher 'exec /system/bin/sh /shadow-boot-helper "$@"'
assert_cpio_entry_contains "$LOG_PREFLIGHT_OUTPUT_IMAGE" shadow-boot-helper 'setprop "$preflight_status_prop_key"'
assert_cpio_entry_contains "$LOG_PREFLIGHT_OUTPUT_IMAGE" shadow-boot-helper 'preflight-summary.txt'
assert_cpio_entry_contains "$LOG_PREFLIGHT_OUTPUT_IMAGE" shadow-boot-helper 'runtime-linux-dir'
assert_cpio_entry_contains "$LOG_PREFLIGHT_OUTPUT_IMAGE" shadow-boot-helper 'record_preflight_path system-launcher true file /data/local/tmp/shadow-runtime-gnu/run-shadow-system'
assert_cpio_entry_contains "$LOG_PREFLIGHT_OUTPUT_IMAGE" shadow-boot-helper 'record_preflight_path guest-client-launcher true file /data/local/tmp/shadow-runtime-gnu/run-shadow-blitz-demo'

kgsl_probe_build_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_kgsl_probe.sh" \
      --stock-init \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$KGSL_PROBE_OUTPUT_IMAGE" \
      --trigger post-fs-data \
      --timeout 12 \
      --device-log-root /data/local/tmp/shadow-boot
)"
assert_contains "$kgsl_probe_build_output" "Wrote kgsl-probe boot image: $KGSL_PROBE_OUTPUT_IMAGE"
assert_contains "$kgsl_probe_build_output" "Trigger: post-fs-data"
assert_contains "$kgsl_probe_build_output" "Timeout: 12s"
assert_contains "$kgsl_probe_build_output" "Second-stage proof prop: debug.shadow.boot.kgsl.second_stage=ready"
assert_cpio_entry_contains "$KGSL_PROBE_OUTPUT_IMAGE" shadow-boot-helper 'exec 3</dev/kgsl-3d0'
assert_cpio_entry_contains "$KGSL_PROBE_OUTPUT_IMAGE" shadow-boot-helper 'kgsl-probe-summary.txt'
assert_cpio_entry_contains "$KGSL_PROBE_OUTPUT_IMAGE" shadow-boot-helper 'kgsl-probe-wchan.txt'
assert_cpio_entry_contains "$KGSL_PROBE_OUTPUT_IMAGE" system/etc/ramdisk/build.prop 'debug.shadow.boot.kgsl.second_stage=ready'

rc_probe_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_rc_probe.sh" \
      --stock-init \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$RC_PROBE_OUTPUT_IMAGE" \
      --trigger post-fs-data \
      --property debug.shadow.boot.rc_probe=ready
)"
assert_contains "$rc_probe_output" "Build mode: stock-init"
assert_contains "$rc_probe_output" "Patch target: system/etc/init/hw/init.rc"
assert_contains "$rc_probe_output" "Patch target profile: unclassified"
assert_contains "$rc_probe_output" "Trigger: post-fs-data"
assert_contains "$rc_probe_output" "Property: debug.shadow.boot.rc_probe=ready"
assert_cpio_entry_equals "$RC_PROBE_OUTPUT_IMAGE" init $'stock-init\n'
assert_cpio_entry_missing "$RC_PROBE_OUTPUT_IMAGE" init.stock
assert_cpio_entry_startswith "$RC_PROBE_OUTPUT_IMAGE" system/etc/init/hw/init.rc $'import /init.shadow.rc\n'
assert_cpio_entry_equals "$RC_PROBE_OUTPUT_IMAGE" init.shadow.rc $'on post-fs-data\n    setprop debug.shadow.boot.rc_probe ready\n'
assert_cpio_entry_missing "$RC_PROBE_OUTPUT_IMAGE" shadow-boot-helper

rc_probe_prefers_normal_anchor_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK_WITH_RECOVERY" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_rc_probe.sh" \
      --stock-init \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$RC_PROBE_OUTPUT_IMAGE" \
      --trigger post-fs-data \
      --property debug.shadow.boot.rc_probe=ready
)"
assert_contains "$rc_probe_prefers_normal_anchor_output" "Patch target: system/etc/init/hw/init.rc"
assert_contains "$rc_probe_prefers_normal_anchor_output" "Patch target profile: unclassified"
assert_cpio_entry_startswith "$RC_PROBE_OUTPUT_IMAGE" system/etc/init/hw/init.rc $'import /init.shadow.rc\n'

rc_probe_inline_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_rc_probe.sh" \
      --stock-init \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$RC_PROBE_INLINE_OUTPUT_IMAGE" \
      --trigger property:sys.boot_completed=1 \
      --property debug.shadow.boot.rc_probe=inline \
      --patch-mode inline
)"
assert_contains "$rc_probe_inline_output" "Patch mode: inline"
assert_contains "$rc_probe_inline_output" "Patch target: system/etc/init/hw/init.rc"
assert_contains "$rc_probe_inline_output" "Patch target profile: unclassified"
assert_contains "$rc_probe_inline_output" "Trigger: property:sys.boot_completed=1"
assert_contains "$rc_probe_inline_output" "Property: debug.shadow.boot.rc_probe=inline"
assert_cpio_entry_equals "$RC_PROBE_INLINE_OUTPUT_IMAGE" init $'stock-init\n'
assert_cpio_entry_missing "$RC_PROBE_INLINE_OUTPUT_IMAGE" init.stock
assert_cpio_entry_startswith "$RC_PROBE_INLINE_OUTPUT_IMAGE" system/etc/init/hw/init.rc $'on property:sys.boot_completed=1\n    setprop debug.shadow.boot.rc_probe inline\n\n'
assert_cpio_entry_missing "$RC_PROBE_INLINE_OUTPUT_IMAGE" init.shadow.rc
assert_cpio_entry_missing "$RC_PROBE_INLINE_OUTPUT_IMAGE" shadow-boot-helper

second_stage_rc_probe_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_SECOND_STAGE_RC_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_second_stage_rc_probe.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$SECOND_STAGE_RC_PROBE_OUTPUT_IMAGE" \
      --trigger property:sys.boot_completed=1 \
      --property debug.shadow.boot.second_stage_rc_probe=ready
)"
assert_contains "$second_stage_rc_probe_output" "Build mode: stock-init"
assert_contains "$second_stage_rc_probe_output" "Probe mode: second-stage-rc"
assert_contains "$second_stage_rc_probe_output" "Primary rc path mutation: /system/etc/init/hw/init.rc -> /second_stage_resources/.rc"
assert_contains "$second_stage_rc_probe_output" "Trigger: property:sys.boot_completed=1"
assert_contains "$second_stage_rc_probe_output" "Property: debug.shadow.boot.second_stage_rc_probe=ready"
assert_cpio_entry_symlink_target "$SECOND_STAGE_RC_PROBE_OUTPUT_IMAGE" init "/system/bin/init"
assert_cpio_entry_contains "$SECOND_STAGE_RC_PROBE_OUTPUT_IMAGE" system/bin/init '/second_stage_resources/.rc'
PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$SECOND_STAGE_RC_PROBE_OUTPUT_IMAGE" <<'PY'
from pathlib import Path
import sys

from cpio_edit import read_cpio

entries = {
    entry.name: entry.data
    for entry in read_cpio(Path(sys.argv[1])).without_trailer()
}

system_init = entries["system/bin/init"]
if b"/system/etc/init/hw/init.rc" in system_init:
    raise SystemExit("system/bin/init still contains the stock primary rc path")
PY
assert_cpio_entry_equals "$SECOND_STAGE_RC_PROBE_OUTPUT_IMAGE" second_stage_resources/.rc $'import /system/etc/init/hw/init.rc\n\non property:sys.boot_completed=1\n    setprop debug.shadow.boot.second_stage_rc_probe ready\n'

ramdisk_prop_probe_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK_PROP_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_ramdisk_prop_probe.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$RAMDISK_PROP_PROBE_OUTPUT_IMAGE" \
      --property debug.shadow.boot.ramdisk_prop_probe=ready \
      --property bootreceiver.enable=1
)"
assert_contains "$ramdisk_prop_probe_output" "Build mode: stock-init"
assert_contains "$ramdisk_prop_probe_output" "Probe mode: ramdisk-build-prop"
assert_contains "$ramdisk_prop_probe_output" "Ramdisk property entry: system/etc/ramdisk/build.prop"
assert_contains "$ramdisk_prop_probe_output" "Property: debug.shadow.boot.ramdisk_prop_probe=ready"
assert_contains "$ramdisk_prop_probe_output" "Property: bootreceiver.enable=1"
assert_cpio_entry_equals "$RAMDISK_PROP_PROBE_OUTPUT_IMAGE" init $'stock-init\n'
assert_cpio_entry_equals "$RAMDISK_PROP_PROBE_OUTPUT_IMAGE" system/etc/ramdisk/build.prop $'ro.build.version.release=13\nro.build.version.sdk=33\ndebug.shadow.boot.ramdisk_prop_probe=ready\nbootreceiver.enable=1\n'

rm -rf "$RC_TRIGGER_LADDER_OUTPUT"
rc_trigger_ladder_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    PIXEL_SERIAL=TESTSERIAL \
    PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
    PIXEL_BOOT_RC_TRIGGER_LADDER_BUILD_SCRIPT="$RC_TRIGGER_LADDER_BUILD_MOCK" \
    PIXEL_BOOT_RC_TRIGGER_LADDER_ONESHOT_SCRIPT="$RC_TRIGGER_LADDER_ONESHOT_MOCK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_rc_trigger_ladder.sh" \
      --serial TESTSERIAL \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output-dir "$RC_TRIGGER_LADDER_OUTPUT" \
      --property-key debug.shadow.boot.rc_probe \
      --trigger post-fs-data \
      --trigger property:init.svc.gpu=running
)"
assert_contains "$rc_trigger_ladder_output" "Trigger ladder output: $RC_TRIGGER_LADDER_OUTPUT"
assert_contains "$rc_trigger_ladder_output" "Matched cases: 2 / 2"
test -f "$RC_TRIGGER_LADDER_OUTPUT/matrix-summary.json"
test -f "$RC_TRIGGER_LADDER_OUTPUT/matrix.tsv"
test -f "$RC_TRIGGER_LADDER_OUTPUT/cases.tsv"
assert_json_field "$RC_TRIGGER_LADDER_OUTPUT/matrix-summary.json" kind boot_rc_trigger_ladder
assert_json_field "$RC_TRIGGER_LADDER_OUTPUT/matrix-summary.json" ok true
assert_json_field "$RC_TRIGGER_LADDER_OUTPUT/matrix-summary.json" case_count 2
assert_json_field "$RC_TRIGGER_LADDER_OUTPUT/matrix-summary.json" matched_case_count 2
assert_json_field "$RC_TRIGGER_LADDER_OUTPUT/matrix-summary.json" successful_case_count 2
assert_json_field "$RC_TRIGGER_LADDER_OUTPUT/matrix-summary.json" property_key debug.shadow.boot.rc_probe
assert_json_field "$RC_TRIGGER_LADDER_OUTPUT/matrix-summary.json" cases/0/trigger post-fs-data
assert_json_field "$RC_TRIGGER_LADDER_OUTPUT/matrix-summary.json" cases/0/proof_property_matched true
assert_json_field "$RC_TRIGGER_LADDER_OUTPUT/matrix-summary.json" cases/1/trigger property:init.svc.gpu=running
assert_json_field "$RC_TRIGGER_LADDER_OUTPUT/matrix-summary.json" cases/1/proof_property_matched true
assert_contains "$(cat "$RC_TRIGGER_LADDER_OUTPUT/matrix.tsv")" $'01-post-fs-data\tpost-fs-data\tdebug.shadow.boot.rc_probe=rc-trigger-01-post-fs-data\ttrue'
assert_contains "$(cat "$RC_TRIGGER_LADDER_OUTPUT/cases.tsv")" $'02-property-init.svc.gpu-running\tTESTSERIAL\tproperty:init.svc.gpu=running\tdebug.shadow.boot.rc_probe=rc-trigger-02-property-init.svc.gpu-running'

mkdir -p "$PREFLIGHT_LEASE_COMMON_ROOT"
env \
  SHADOW_REPO_COMMON_ROOT="$PREFLIGHT_LEASE_COMMON_ROOT" \
  SHADOW_DEVICE_LEASE_AGENT=review-holder \
  "$REPO_ROOT/scripts/shadowctl" lease acquire TESTSERIAL --lane stream-a --ttl 15m >/dev/null

rm -rf "$PREFLIGHT_CONFLICT_OUTPUT"
if preflight_conflict_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    SHADOW_REPO_COMMON_ROOT="$PREFLIGHT_LEASE_COMMON_ROOT" \
    SHADOW_DEVICE_LEASE_AGENT=stream-b-worker \
    PIXEL_SERIAL=TESTSERIAL \
    PIXEL_BOOT_PREFLIGHT_BUILD_SCRIPT="$PREFLIGHT_BUILD_MOCK" \
    PIXEL_BOOT_PREFLIGHT_ONESHOT_SCRIPT="$PREFLIGHT_ONESHOT_MOCK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_preflight.sh" \
      --serial TESTSERIAL \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output-dir "$PREFLIGHT_CONFLICT_OUTPUT" \
      --trigger post-fs-data \
      --patch-target init.recovery.rc \
      --adb-timeout 45 \
      --boot-timeout 60 \
      --recover-traces-after 2>&1
)"; then
  echo "pixel_boot_tooling_smoke: expected preflight lease conflict to fail" >&2
  exit 1
fi
assert_contains "$preflight_conflict_output" "active lease on TESTSERIAL"

rm -rf "$PREFLIGHT_OUTPUT"
rm -f "$LOCKF_LOG"
preflight_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    SHADOW_REPO_COMMON_ROOT="$PREFLIGHT_LEASE_COMMON_ROOT-success" \
    PIXEL_SERIAL=TESTSERIAL \
    MOCK_LOCKF_LOG="$LOCKF_LOG" \
    PIXEL_BOOT_PREFLIGHT_BUILD_SCRIPT="$PREFLIGHT_BUILD_MOCK" \
    PIXEL_BOOT_PREFLIGHT_ONESHOT_SCRIPT="$PREFLIGHT_ONESHOT_MOCK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_preflight.sh" \
      --serial TESTSERIAL \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output-dir "$PREFLIGHT_OUTPUT" \
      --trigger post-fs-data \
      --patch-target init.recovery.rc \
      --adb-timeout 45 \
      --boot-timeout 60 \
      --recover-traces-after
)"
assert_contains "$preflight_output" "Boot preflight output: $PREFLIGHT_OUTPUT"
assert_contains "$preflight_output" "Phase-1 preflight status: blocked"
assert_contains "$preflight_output" "Phase-1 preflight blocked reason: missing-required-paths"
assert_contains "$preflight_output" "Phase-1 preflight source: preflight-summary"
assert_contains "$preflight_output" "Phase-1 required missing labels: system-launcher,guest-client-launcher"
assert_contains "$preflight_output" "Preflight status: blocked"
test -f "$PREFLIGHT_OUTPUT/summary.json"
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" kind boot_preflight
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" ok true
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" second_stage_proof_prop debug.shadow.boot.preflight.second_stage=ready
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" second_stage_property_proved_current_boot true
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" import_proof_prop debug.shadow.boot.preflight.import=triggered
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" import_proved_current_boot true
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" helper_launch_proved_current_boot true
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" helper_proved_current_boot true
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" preflight_profile phase1-shell
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" preflight_status blocked
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" preflight_ready false
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" preflight_blocked_reason missing-required-paths
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" preflight_required_missing_labels system-launcher,guest-client-launcher
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" phase1_preflight_status blocked
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" phase1_preflight_ready false
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" phase1_preflight_blocked_reason missing-required-paths
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" phase1_preflight_status_source preflight-summary
assert_json_field "$PREFLIGHT_OUTPUT/summary.json" phase1_preflight_required_missing_labels system-launcher,guest-client-launcher
test -f "$PREFLIGHT_OUTPUT/device-run/status.json"
assert_json_field "$PREFLIGHT_OUTPUT/device-run/status.json" ok true
assert_json_field "$PREFLIGHT_OUTPUT/device-run/status.json" boot_oneshot_ok true
assert_json_field "$PREFLIGHT_OUTPUT/device-run/status.json" phase1_preflight_status blocked
assert_json_field "$PREFLIGHT_OUTPUT/device-run/status.json" phase1_preflight_blocked_reason missing-required-paths
assert_json_field "$PREFLIGHT_OUTPUT/device-run/status.json" phase1_preflight_status_source preflight-summary
assert_json_field "$PREFLIGHT_OUTPUT/device-run/status.json" phase1_preflight_required_missing_labels system-launcher,guest-client-launcher
assert_json_field "$PREFLIGHT_OUTPUT/device-run/status.json" phase1_preflight_device_status_aligned false
assert_contains "$(cat "$LOCKF_LOG")" "exec "
assert_contains "$(cat "$LOCKF_LOG")" "pixel_boot_preflight.sh"

rm -rf "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT"
rm -f "$LOCKF_LOG"
preflight_second_stage_blocked_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    SHADOW_REPO_COMMON_ROOT="$PREFLIGHT_LEASE_COMMON_ROOT-second-stage" \
    PIXEL_SERIAL=TESTSERIAL \
    MOCK_LOCKF_LOG="$LOCKF_LOG" \
    MOCK_PREFLIGHT_ONESHOT_MODE=second-stage-only \
    PIXEL_BOOT_PREFLIGHT_BUILD_SCRIPT="$PREFLIGHT_BUILD_MOCK" \
    PIXEL_BOOT_PREFLIGHT_ONESHOT_SCRIPT="$PREFLIGHT_ONESHOT_MOCK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_preflight.sh" \
      --serial TESTSERIAL \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output-dir "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT" \
      --trigger post-fs-data \
      --patch-target init.recovery.rc \
      --adb-timeout 45 \
      --boot-timeout 60 \
      --recover-traces-after
)"
assert_contains "$preflight_second_stage_blocked_output" "Boot preflight output: $PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT"
assert_contains "$preflight_second_stage_blocked_output" "Import proved current boot: false"
assert_contains "$preflight_second_stage_blocked_output" "Helper launch proved current boot: false"
assert_contains "$preflight_second_stage_blocked_output" "Phase-1 preflight status: blocked"
assert_contains "$preflight_second_stage_blocked_output" "Phase-1 preflight blocked reason: stock-init-import-not-proved"
assert_contains "$preflight_second_stage_blocked_output" "Phase-1 preflight source: second-stage-property-proof"
test -f "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/summary.json"
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/summary.json" kind boot_preflight
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/summary.json" ok true
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/summary.json" second_stage_property_proved_current_boot true
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/summary.json" import_proved_current_boot false
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/summary.json" helper_launch_proved_current_boot false
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/summary.json" phase1_preflight_status blocked
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/summary.json" phase1_preflight_ready false
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/summary.json" phase1_preflight_blocked_reason stock-init-import-not-proved
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/summary.json" phase1_preflight_status_source second-stage-property-proof
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/summary.json" phase1_preflight_required_missing_labels ""
test -f "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/device-run/status.json"
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/device-run/status.json" ok true
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/device-run/status.json" failure_stage ""
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/device-run/status.json" boot_oneshot_ok false
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/device-run/status.json" boot_oneshot_failure_stage collect
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/device-run/status.json" collection_succeeded false
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/device-run/status.json" phase1_preflight_status blocked
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/device-run/status.json" phase1_preflight_blocked_reason stock-init-import-not-proved
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/device-run/status.json" phase1_preflight_status_source second-stage-property-proof
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/device-run/status.json" phase1_preflight_required_missing_labels ""
assert_json_field "$PREFLIGHT_SECOND_STAGE_BLOCKED_OUTPUT/device-run/status.json" phase1_preflight_device_status_aligned true

rm -rf "$KGSL_PROBE_OUTPUT"
rm -f "$LOCKF_LOG"
kgsl_probe_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    SHADOW_REPO_COMMON_ROOT="$TMP_DIR/kgsl-probe-common-root" \
    PIXEL_SERIAL=TESTSERIAL \
    MOCK_LOCKF_LOG="$LOCKF_LOG" \
    PIXEL_BOOT_KGSL_PROBE_BUILD_SCRIPT="$KGSL_PROBE_BUILD_MOCK" \
    PIXEL_BOOT_KGSL_PROBE_ONESHOT_SCRIPT="$KGSL_PROBE_ONESHOT_MOCK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_kgsl_probe.sh" \
      --serial TESTSERIAL \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output-dir "$KGSL_PROBE_OUTPUT" \
      --trigger post-fs-data \
      --timeout 12 \
      --patch-target init.recovery.rc \
      --adb-timeout 45 \
      --boot-timeout 60 \
      --recover-traces-after
)"
assert_contains "$kgsl_probe_output" "Boot KGSL probe output: $KGSL_PROBE_OUTPUT"
assert_contains "$kgsl_probe_output" "Second-stage property proved: True"
assert_contains "$kgsl_probe_output" "Init-script-selection proved: True"
assert_contains "$kgsl_probe_output" "Imported-rc proved: True"
assert_contains "$kgsl_probe_output" "Control point proved: True"
assert_contains "$kgsl_probe_output" "Import proved current boot: True"
assert_contains "$kgsl_probe_output" "Helper launch proved current boot: True"
assert_contains "$kgsl_probe_output" "Launch discriminator: helper-launched-kgsl-outcome"
assert_contains "$kgsl_probe_output" "KGSL result: timeout"
assert_contains "$kgsl_probe_output" "KGSL wchan: request_firmware"
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" kind boot_kgsl_probe
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" ok true
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" second_stage_proof_prop debug.shadow.boot.kgsl.second_stage=ready
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" second_stage_property_proved_current_boot true
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" init_script_selection_proof_prop init.svc.servicemanager=running
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" init_script_selection_proved_current_boot true
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" imported_rc_proof_prop init.svc.adbd=running
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" imported_rc_proved_current_boot true
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" control_point_prop llk.enable=1
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" control_point_proof_prop init.svc.llkd-0=running
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" control_point_proved_current_boot true
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" import_proof_prop debug.shadow.boot.kgsl.import=triggered
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" import_proved_current_boot true
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" helper_launch_proved_current_boot true
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" helper_proved_current_boot true
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" launch_discriminator helper-launched-kgsl-outcome
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" kgsl_result timeout
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" kgsl_wchan request_firmware
assert_json_field "$KGSL_PROBE_OUTPUT/summary.json" bootreason_sys_boot_reason bootloader
assert_contains "$(cat "$LOCKF_LOG")" "pixel_boot_kgsl_probe.sh"

rm -rf "$KGSL_TRIGGER_LADDER_OUTPUT"
kgsl_trigger_ladder_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    PIXEL_SERIAL=TESTSERIAL \
    PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
    PIXEL_BOOT_KGSL_PROBE_BUILD_SCRIPT="$KGSL_PROBE_BUILD_MOCK" \
    PIXEL_BOOT_KGSL_PROBE_ONESHOT_SCRIPT="$KGSL_PROBE_ONESHOT_MOCK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_kgsl_trigger_ladder.sh" \
      --serial TESTSERIAL \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output-dir "$KGSL_TRIGGER_LADDER_OUTPUT" \
      --timeout 12 \
      --trigger post-fs-data \
      --trigger property:init.svc.gpu=running
)"
assert_contains "$kgsl_trigger_ladder_output" "KGSL trigger ladder output: $KGSL_TRIGGER_LADDER_OUTPUT"
test -f "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json"
test -f "$KGSL_TRIGGER_LADDER_OUTPUT/matrix.tsv"
test -f "$KGSL_TRIGGER_LADDER_OUTPUT/cases.tsv"
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" kind boot_kgsl_trigger_ladder
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" ok true
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" case_count 2
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" second_stage_proved_case_count 2
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" init_script_selection_proved_case_count 2
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" imported_rc_proved_case_count 2
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" control_point_proved_case_count 2
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" import_proved_case_count 2
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" helper_launch_case_count 2
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" surviving_discriminator helper-launched-kgsl-outcome
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" cases/0/kgsl_result timeout
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" cases/0/second_stage_property_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" cases/0/init_script_selection_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" cases/0/imported_rc_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" cases/0/control_point_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" cases/0/import_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_OUTPUT/matrix-summary.json" cases/1/helper_proved_current_boot true
assert_contains "$(cat "$KGSL_TRIGGER_LADDER_OUTPUT/matrix.tsv")" $'01-post-fs-data\tpost-fs-data\ttrue\ttrue\ttrue\ttrue\ttrue\ttrue\ttrue\ttrue\thelper-launched-kgsl-outcome\ttimeout'
assert_contains "$(cat "$KGSL_TRIGGER_LADDER_OUTPUT/cases.tsv")" $'02-property-init.svc.gpu-running\tTESTSERIAL\tproperty:init.svc.gpu=running'

rm -rf "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT"
set +e
kgsl_trigger_ladder_negative_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    PIXEL_SERIAL=TESTSERIAL \
    PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
    MOCK_KGSL_IMPORT_PROOF_MATCHED=1 \
    MOCK_KGSL_HELPER_LAUNCH_MATCHED=0 \
    PIXEL_BOOT_KGSL_PROBE_BUILD_SCRIPT="$KGSL_PROBE_BUILD_MOCK" \
    PIXEL_BOOT_KGSL_PROBE_ONESHOT_SCRIPT="$KGSL_PROBE_ONESHOT_MOCK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_kgsl_trigger_ladder.sh" \
      --serial TESTSERIAL \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output-dir "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT" \
      --timeout 12 \
      --trigger property:init.svc.gpu=running
)"
kgsl_trigger_ladder_negative_status="$?"
set -e
test "$kgsl_trigger_ladder_negative_status" -eq 1
assert_contains "$kgsl_trigger_ladder_negative_output" "KGSL trigger ladder output: $KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT"
assert_json_field "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT/matrix-summary.json" kind boot_kgsl_trigger_ladder
assert_json_field "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT/matrix-summary.json" ok false
assert_json_field "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT/matrix-summary.json" second_stage_proved_case_count 1
assert_json_field "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT/matrix-summary.json" init_script_selection_proved_case_count 1
assert_json_field "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT/matrix-summary.json" imported_rc_proved_case_count 1
assert_json_field "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT/matrix-summary.json" control_point_proved_case_count 1
assert_json_field "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT/matrix-summary.json" import_proved_case_count 1
assert_json_field "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT/matrix-summary.json" helper_launch_case_count 0
assert_json_field "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT/matrix-summary.json" surviving_discriminator import-proved-helper-missing
assert_json_field "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT/matrix-summary.json" cases/0/second_stage_property_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT/matrix-summary.json" cases/0/init_script_selection_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT/matrix-summary.json" cases/0/imported_rc_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT/matrix-summary.json" cases/0/control_point_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT/matrix-summary.json" cases/0/import_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT/matrix-summary.json" cases/0/helper_launch_proved_current_boot false
assert_json_field "$KGSL_TRIGGER_LADDER_NEGATIVE_OUTPUT/matrix-summary.json" cases/0/launch_discriminator import-proved-helper-missing

rm -rf "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT"
set +e
kgsl_trigger_ladder_imported_rc_only_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    PIXEL_SERIAL=TESTSERIAL \
    PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
    MOCK_KGSL_SECOND_STAGE_PROOF_MATCHED=1 \
    MOCK_KGSL_INIT_SCRIPT_SELECTION_PROOF_MATCHED=1 \
    MOCK_KGSL_IMPORTED_RC_PROOF_MATCHED=1 \
    MOCK_KGSL_CONTROL_POINT_PROOF_MATCHED=1 \
    MOCK_KGSL_IMPORT_PROOF_MATCHED=0 \
    MOCK_KGSL_HELPER_LAUNCH_MATCHED=0 \
    PIXEL_BOOT_KGSL_PROBE_BUILD_SCRIPT="$KGSL_PROBE_BUILD_MOCK" \
    PIXEL_BOOT_KGSL_PROBE_ONESHOT_SCRIPT="$KGSL_PROBE_ONESHOT_MOCK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_kgsl_trigger_ladder.sh" \
      --serial TESTSERIAL \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output-dir "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT" \
      --timeout 12 \
      --trigger property:init.svc.gpu=running
)"
kgsl_trigger_ladder_imported_rc_only_status="$?"
set -e
test "$kgsl_trigger_ladder_imported_rc_only_status" -eq 1
assert_contains "$kgsl_trigger_ladder_imported_rc_only_output" "KGSL trigger ladder output: $KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT"
assert_json_field "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT/matrix-summary.json" kind boot_kgsl_trigger_ladder
assert_json_field "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT/matrix-summary.json" ok false
assert_json_field "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT/matrix-summary.json" second_stage_proved_case_count 1
assert_json_field "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT/matrix-summary.json" init_script_selection_proved_case_count 1
assert_json_field "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT/matrix-summary.json" imported_rc_proved_case_count 1
assert_json_field "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT/matrix-summary.json" control_point_proved_case_count 1
assert_json_field "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT/matrix-summary.json" import_proved_case_count 0
assert_json_field "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT/matrix-summary.json" helper_launch_case_count 0
assert_json_field "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT/matrix-summary.json" surviving_discriminator imported-rc-proved-no-import-proof
assert_json_field "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT/matrix-summary.json" cases/0/second_stage_property_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT/matrix-summary.json" cases/0/init_script_selection_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT/matrix-summary.json" cases/0/imported_rc_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT/matrix-summary.json" cases/0/control_point_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT/matrix-summary.json" cases/0/import_proved_current_boot false
assert_json_field "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT/matrix-summary.json" cases/0/helper_launch_proved_current_boot false
assert_json_field "$KGSL_TRIGGER_LADDER_IMPORTED_RC_ONLY_OUTPUT/matrix-summary.json" cases/0/launch_discriminator imported-rc-proved-no-import-proof

rm -rf "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT"
set +e
kgsl_trigger_ladder_control_point_only_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    PIXEL_SERIAL=TESTSERIAL \
    PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
    MOCK_KGSL_SECOND_STAGE_PROOF_MATCHED=1 \
    MOCK_KGSL_IMPORTED_RC_PROOF_MATCHED=0 \
    MOCK_KGSL_CONTROL_POINT_PROOF_MATCHED=1 \
    MOCK_KGSL_IMPORT_PROOF_MATCHED=0 \
    MOCK_KGSL_HELPER_LAUNCH_MATCHED=0 \
    PIXEL_BOOT_KGSL_PROBE_BUILD_SCRIPT="$KGSL_PROBE_BUILD_MOCK" \
    PIXEL_BOOT_KGSL_PROBE_ONESHOT_SCRIPT="$KGSL_PROBE_ONESHOT_MOCK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_kgsl_trigger_ladder.sh" \
      --serial TESTSERIAL \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output-dir "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT" \
      --timeout 12 \
      --trigger property:init.svc.gpu=running
)"
kgsl_trigger_ladder_control_point_only_status="$?"
set -e
test "$kgsl_trigger_ladder_control_point_only_status" -eq 1
assert_contains "$kgsl_trigger_ladder_control_point_only_output" "KGSL trigger ladder output: $KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT"
assert_json_field "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT/matrix-summary.json" kind boot_kgsl_trigger_ladder
assert_json_field "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT/matrix-summary.json" ok false
assert_json_field "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT/matrix-summary.json" second_stage_proved_case_count 1
assert_json_field "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT/matrix-summary.json" init_script_selection_proved_case_count 1
assert_json_field "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT/matrix-summary.json" imported_rc_proved_case_count 0
assert_json_field "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT/matrix-summary.json" control_point_proved_case_count 1
assert_json_field "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT/matrix-summary.json" import_proved_case_count 0
assert_json_field "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT/matrix-summary.json" helper_launch_case_count 0
assert_json_field "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT/matrix-summary.json" surviving_discriminator control-point-proved-no-imported-rc-proof
assert_json_field "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT/matrix-summary.json" cases/0/second_stage_property_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT/matrix-summary.json" cases/0/init_script_selection_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT/matrix-summary.json" cases/0/imported_rc_proved_current_boot false
assert_json_field "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT/matrix-summary.json" cases/0/control_point_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT/matrix-summary.json" cases/0/import_proved_current_boot false
assert_json_field "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT/matrix-summary.json" cases/0/helper_launch_proved_current_boot false
assert_json_field "$KGSL_TRIGGER_LADDER_CONTROL_POINT_ONLY_OUTPUT/matrix-summary.json" cases/0/launch_discriminator control-point-proved-no-imported-rc-proof

rm -rf "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT"
set +e
kgsl_trigger_ladder_init_script_selection_only_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    PIXEL_SERIAL=TESTSERIAL \
    PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
    MOCK_KGSL_SECOND_STAGE_PROOF_MATCHED=1 \
    MOCK_KGSL_INIT_SCRIPT_SELECTION_PROOF_MATCHED=1 \
    MOCK_KGSL_IMPORTED_RC_PROOF_MATCHED=0 \
    MOCK_KGSL_CONTROL_POINT_PROOF_MATCHED=0 \
    MOCK_KGSL_IMPORT_PROOF_MATCHED=0 \
    MOCK_KGSL_HELPER_LAUNCH_MATCHED=0 \
    PIXEL_BOOT_KGSL_PROBE_BUILD_SCRIPT="$KGSL_PROBE_BUILD_MOCK" \
    PIXEL_BOOT_KGSL_PROBE_ONESHOT_SCRIPT="$KGSL_PROBE_ONESHOT_MOCK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_kgsl_trigger_ladder.sh" \
      --serial TESTSERIAL \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output-dir "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT" \
      --timeout 12 \
      --trigger property:init.svc.gpu=running
)"
kgsl_trigger_ladder_init_script_selection_only_status="$?"
set -e
test "$kgsl_trigger_ladder_init_script_selection_only_status" -eq 1
assert_contains "$kgsl_trigger_ladder_init_script_selection_only_output" "KGSL trigger ladder output: $KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT"
assert_json_field "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT/matrix-summary.json" kind boot_kgsl_trigger_ladder
assert_json_field "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT/matrix-summary.json" ok false
assert_json_field "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT/matrix-summary.json" second_stage_proved_case_count 1
assert_json_field "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT/matrix-summary.json" init_script_selection_proved_case_count 1
assert_json_field "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT/matrix-summary.json" imported_rc_proved_case_count 0
assert_json_field "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT/matrix-summary.json" control_point_proved_case_count 0
assert_json_field "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT/matrix-summary.json" import_proved_case_count 0
assert_json_field "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT/matrix-summary.json" helper_launch_case_count 0
assert_json_field "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT/matrix-summary.json" surviving_discriminator init-script-selection-proved-no-control-point
assert_json_field "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT/matrix-summary.json" cases/0/second_stage_property_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT/matrix-summary.json" cases/0/init_script_selection_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT/matrix-summary.json" cases/0/imported_rc_proved_current_boot false
assert_json_field "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT/matrix-summary.json" cases/0/control_point_proved_current_boot false
assert_json_field "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT/matrix-summary.json" cases/0/import_proved_current_boot false
assert_json_field "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT/matrix-summary.json" cases/0/helper_launch_proved_current_boot false
assert_json_field "$KGSL_TRIGGER_LADDER_INIT_SCRIPT_SELECTION_ONLY_OUTPUT/matrix-summary.json" cases/0/launch_discriminator init-script-selection-proved-no-control-point

rm -rf "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT"
set +e
kgsl_trigger_ladder_second_stage_only_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    PIXEL_SERIAL=TESTSERIAL \
    PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
    MOCK_KGSL_SECOND_STAGE_PROOF_MATCHED=1 \
    MOCK_KGSL_INIT_SCRIPT_SELECTION_PROOF_MATCHED=0 \
    MOCK_KGSL_IMPORTED_RC_PROOF_MATCHED=0 \
    MOCK_KGSL_CONTROL_POINT_PROOF_MATCHED=0 \
    MOCK_KGSL_IMPORT_PROOF_MATCHED=0 \
    MOCK_KGSL_HELPER_LAUNCH_MATCHED=0 \
    PIXEL_BOOT_KGSL_PROBE_BUILD_SCRIPT="$KGSL_PROBE_BUILD_MOCK" \
    PIXEL_BOOT_KGSL_PROBE_ONESHOT_SCRIPT="$KGSL_PROBE_ONESHOT_MOCK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_kgsl_trigger_ladder.sh" \
      --serial TESTSERIAL \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output-dir "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT" \
      --timeout 12 \
      --trigger property:init.svc.gpu=running
)"
kgsl_trigger_ladder_second_stage_only_status="$?"
set -e
test "$kgsl_trigger_ladder_second_stage_only_status" -eq 1
assert_contains "$kgsl_trigger_ladder_second_stage_only_output" "KGSL trigger ladder output: $KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT"
assert_json_field "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT/matrix-summary.json" kind boot_kgsl_trigger_ladder
assert_json_field "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT/matrix-summary.json" ok false
assert_json_field "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT/matrix-summary.json" second_stage_proved_case_count 1
assert_json_field "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT/matrix-summary.json" init_script_selection_proved_case_count 0
assert_json_field "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT/matrix-summary.json" imported_rc_proved_case_count 0
assert_json_field "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT/matrix-summary.json" control_point_proved_case_count 0
assert_json_field "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT/matrix-summary.json" import_proved_case_count 0
assert_json_field "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT/matrix-summary.json" helper_launch_case_count 0
assert_json_field "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT/matrix-summary.json" surviving_discriminator second-stage-property-proved-no-init-script-selection-proof
assert_json_field "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT/matrix-summary.json" cases/0/second_stage_property_proved_current_boot true
assert_json_field "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT/matrix-summary.json" cases/0/init_script_selection_proved_current_boot false
assert_json_field "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT/matrix-summary.json" cases/0/imported_rc_proved_current_boot false
assert_json_field "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT/matrix-summary.json" cases/0/control_point_proved_current_boot false
assert_json_field "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT/matrix-summary.json" cases/0/import_proved_current_boot false
assert_json_field "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT/matrix-summary.json" cases/0/helper_launch_proved_current_boot false
assert_json_field "$KGSL_TRIGGER_LADDER_SECOND_STAGE_ONLY_OUTPUT/matrix-summary.json" cases/0/launch_discriminator second-stage-property-proved-no-init-script-selection-proof

prepare_cached_tmpfs_gpu_bundle
install_tmpfs_gpu_smoke_mocks
rm -rf "$TMPFS_DEVICE_STATE_ROOT" "$TMPFS_DEV_GPU_OUTPUT"
tmpfs_dev_gpu_output="$(
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    PIXEL_SERIAL=TESTSERIAL \
    PIXEL_HOST_LOCK_HELD_SERIAL=TESTSERIAL \
    PIXEL_GPU_TMPFS_DEV_PRIMARY_SERIAL=TESTSERIAL \
    PIXEL_GPU_TMPFS_DEV_DEVICE_DIR="$TMPFS_DEVICE_DIR" \
    PIXEL_GPU_TMPFS_DEV_RUN_DIR="$TMPFS_DEV_GPU_OUTPUT" \
    PIXEL_VENDOR_TURNIP_LIB_PATH="$TMPFS_FAKE_TURNIP_LIB" \
    MOCK_TMPFS_DEVICE_ROOT="$TMPFS_DEVICE_STATE_ROOT" \
    MOCK_TMPFS_DEVICE_DIR="$TMPFS_DEVICE_DIR" \
    "$REPO_ROOT/scripts/pixel/pixel_tmpfs_dev_gpu_smoke.sh"
)"
assert_contains "$tmpfs_dev_gpu_output" "\"kgsl_holder_scan\""
test -f "$TMPFS_DEV_GPU_OUTPUT/kgsl-holder-scan.tsv"
assert_contains "$(cat "$TMPFS_DEV_GPU_OUTPUT/kgsl-holder-scan.tsv")" $'holder\t432\t7\tsurfaceflinger\t/system/bin/surfaceflinger'
assert_json_field "$TMPFS_DEV_GPU_OUTPUT/status.json" run_succeeded true
assert_json_field "$TMPFS_DEV_GPU_OUTPUT/status.json" summary_expected false
assert_json_field "$TMPFS_DEV_GPU_OUTPUT/status.json" device_profile_pulled true
assert_json_field "$TMPFS_DEV_GPU_OUTPUT/status.json" openlog_has_kgsl true
assert_json_field "$TMPFS_DEV_GPU_OUTPUT/status.json" requested_profile_nodes_present true
assert_json_field "$TMPFS_DEV_GPU_OUTPUT/status.json" vk_count_query_ok true
assert_json_field "$TMPFS_DEV_GPU_OUTPUT/status.json" kgsl_holder_scan/exit_code 0
assert_json_field "$TMPFS_DEV_GPU_OUTPUT/status.json" kgsl_holder_scan/has_holders true
assert_json_field "$TMPFS_DEV_GPU_OUTPUT/status.json" kgsl_holder_scan/holder_count 1
assert_json_field "$TMPFS_DEV_GPU_OUTPUT/status.json" kgsl_holder_scan/holders/0/comm surfaceflinger

"$REPO_ROOT/scripts/ci/pixel_boot_recover_traces_smoke.sh"

echo "pixel_boot_tooling_smoke: ok"
