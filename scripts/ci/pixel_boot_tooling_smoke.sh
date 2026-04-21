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
BOOT_BUILD_SYSTEM_INIT_RAMDISK="$TMP_DIR/build-system-init-ramdisk.cpio"
BOOT_BUILD_SYSTEM_INIT_NONSTOCK_ROOT_RAMDISK="$TMP_DIR/build-system-init-nonstock-root-ramdisk.cpio"
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
INIT_SYMLINK_OUTPUT_IMAGE="$TMP_DIR/init-symlink-output.img"
SYSTEM_INIT_SYMLINK_OUTPUT_IMAGE="$TMP_DIR/system-init-symlink-output.img"
SYSTEM_INIT_WRAPPER_OUTPUT_IMAGE="$TMP_DIR/system-init-wrapper-output.img"
LOG_PROBE_OUTPUT_IMAGE="$TMP_DIR/log-probe-stock-init.img"
RC_PROBE_OUTPUT_IMAGE="$TMP_DIR/rc-probe-stock-init.img"
MOCK_STORE_STANDARD="$TMP_DIR/store-standard"
MOCK_STORE_MINIMAL="$TMP_DIR/store-minimal"
MOCK_STORE_C="$TMP_DIR/store-c"
MOCK_STORE_C_SYSTEM="$TMP_DIR/store-c-system"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

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
mkdir -p "$MOCK_STORE_STANDARD/bin" "$MOCK_STORE_MINIMAL/bin" "$MOCK_STORE_C/bin" "$MOCK_STORE_C_SYSTEM/bin"

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
    setprop shadow.boot.rc_probe ready
EOF

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

entries = [
    build_entry_from_path("init", init_path, 1),
    build_entry_from_path("system/etc/init/hw/init.rc", init_rc_path, 2),
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
  *)
    printf '%s: ELF 64-bit LSB executable, ARM aarch64, statically linked\n' "$1"
    ;;
esac
EOF

cat >"$MOCK_BIN/nix" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\$1" != build ]]; then
  echo "mock nix: unexpected args: \$*" >&2
  exit 1
fi

case "\$*" in
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
    echo "mock nix: unexpected package ref: \$*" >&2
    exit 1
    ;;
esac
EOF

chmod 0755 \
  "$MOCK_BIN/adb" \
  "$MOCK_BIN/file" \
  "$MOCK_BIN/just" \
  "$MOCK_BIN/nix" \
  "$MOCK_BIN/payload-dumper-go" \
  "$MOCK_BIN/unpack_bootimg" \
  "$MOCK_BIN/mkbootimg" \
  "$MOCK_BIN/avbtool"

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
      "logcat -d -v threadtime")
        if [[ "$trace_mode" == "matched" ]]; then
          printf '04-19 10:05:00.000 root root I shadow-drm: current boot kernel handoff summary run_token=%s\n' "$trace_run_token"
        else
          printf '04-19 10:05:00.000 root root I ActivityManager: idle\n'
        fi
        ;;
      "logcat -b kernel -d -v threadtime")
        if [[ "$trace_mode" == "matched" ]]; then
          printf '<6>[shadow-drm] current kernel snapshot run_token=%s\n' "$trace_run_token"
        else
          printf '<6>[kernel] boot complete\n'
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
}

reset_fastboot_cycle_state() {
  mkdir -p "$MOCK_DEVICE_STATE_DIR"
  printf 'adb\n' >"$MOCK_DEVICE_STATE_DIR/transport"
  printf 'a\n' >"$MOCK_DEVICE_STATE_DIR/active_slot"
  printf 'stock\n' >"$MOCK_DEVICE_STATE_DIR/boot_a_image"
  printf 'stock\n' >"$MOCK_DEVICE_STATE_DIR/boot_b_image"
  rm -f \
    "$MOCK_DEVICE_STATE_DIR/pending_transport" \
    "$MOCK_DEVICE_STATE_DIR/pending_polls"
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
      --proof-prop shadow.boot.rc_probe=ready
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
assert_contains "$oneshot_output" "proof_prop=shadow.boot.rc_probe=ready"

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
      --proof-prop shadow.boot.rc_probe=ready
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
assert_contains "$flash_run_output" "proof_prop=shadow.boot.rc_probe=ready"
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
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" boot_completed true
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" slot_after b
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" failure_stage bootreason-failure
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" bootreason_indicates_failure true
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" bootreason_failure_summary "ro.boot.bootreason=kernel_panic; sys.boot.reason=kernel_panic"
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" bootreason_props/ro.boot.bootreason kernel_panic
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/status.json" bootreason_props/sys.boot.reason kernel_panic
test -f "$ONESHOT_ADB_RETURN_OUTPUT/recover-traces/status.json"
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/recover-traces/status.json" matched_any_shadow_tags false
assert_json_field "$ONESHOT_ADB_RETURN_OUTPUT/recover-traces/status.json" bootreason_props/ro.boot.bootreason kernel_panic
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
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" recover_traces_current_boot_channels_with_matches 3
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" recover_traces_proof_ok true
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" recover_traces_expected_durable_logging_summary "kmsg=true,pmsg=true"
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" failure_stage bootreason-failure
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/status.json" bootreason_indicates_failure true
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/recover-traces/status.json" wait_boot_completed false
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/recover-traces/status.json" matched_any_shadow_tags true
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/recover-traces/status.json" matched_any_uncorrelated_shadow_tags true
assert_json_field "$ONESHOT_ADB_RETURN_NOWAIT_OUTPUT/recover-traces/status.json" uncorrelated_previous_boot_channels_with_matches 1

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
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" transport_first_none_elapsed_secs 0
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" transport_last_state none
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/status.json" transport_late_recovery_reached_adb true
test -f "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/recover-traces/status.json"
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/recover-traces/status.json" ok true
assert_json_field "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/recover-traces/status.json" transport_last_state adb
test -f "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/transport-timeline.tsv"
assert_contains "$(cat "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/transport-timeline.tsv")" $'elapsed_secs\ttransport'
assert_contains "$(cat "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/transport-timeline.tsv")" $'0\tnone'
assert_contains "$(cat "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/transport-timeline.tsv")" 'stop:wait-adb-timeout'
assert_contains "$(cat "$ONESHOT_ADB_LATE_RECOVER_OUTPUT/transport-timeline.tsv")" 'stop:recover-traces-adb-ready'

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
assert_json_field "$ONESHOT_ADB_FASTBOOT_TIMEOUT_OUTPUT/status.json" transport_first_fastboot_elapsed_secs 0
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
assert_json_field "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" transport_first_none_elapsed_secs 0
assert_json_field "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT/status.json" transport_last_state adb
test -f "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT/transport-timeline.tsv"
assert_contains "$(cat "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT/transport-timeline.tsv")" $'0\tnone'
assert_contains "$(cat "$ONESHOT_ADB_FASTBOOT_AUTO_REBOOT_OUTPUT/transport-timeline.tsv")" $'\tfastboot'

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
assert_cpio_entry_equals "$STOCK_INIT_OUTPUT_IMAGE" system/etc/init/hw/init.rc $'import /init.shadow.rc\n\non boot\n    setprop shadow.boot.rc_probe ready\n'

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
assert_cpio_entry_equals "$LOG_PROBE_OUTPUT_IMAGE" init $'stock-init\n'
assert_cpio_entry_missing "$LOG_PROBE_OUTPUT_IMAGE" init.stock
assert_cpio_entry_startswith "$LOG_PROBE_OUTPUT_IMAGE" system/etc/init/hw/init.rc $'import /init.shadow.rc\n'
assert_cpio_entry_startswith "$LOG_PROBE_OUTPUT_IMAGE" init.shadow.rc $'on post-fs-data\n'
assert_cpio_entry_startswith "$LOG_PROBE_OUTPUT_IMAGE" shadow-boot-helper $'#!/system/bin/sh\n'

rc_probe_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_rc_probe.sh" \
      --stock-init \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$RC_PROBE_OUTPUT_IMAGE" \
      --trigger post-fs-data \
      --property shadow.boot.rc_probe=ready
)"
assert_contains "$rc_probe_output" "Build mode: stock-init"
assert_contains "$rc_probe_output" "Patch target: system/etc/init/hw/init.rc"
assert_contains "$rc_probe_output" "Trigger: post-fs-data"
assert_contains "$rc_probe_output" "Property: shadow.boot.rc_probe=ready"
assert_cpio_entry_equals "$RC_PROBE_OUTPUT_IMAGE" init $'stock-init\n'
assert_cpio_entry_missing "$RC_PROBE_OUTPUT_IMAGE" init.stock
assert_cpio_entry_startswith "$RC_PROBE_OUTPUT_IMAGE" system/etc/init/hw/init.rc $'import /init.shadow.rc\n'
assert_cpio_entry_equals "$RC_PROBE_OUTPUT_IMAGE" init.shadow.rc $'on post-fs-data\n    setprop shadow.boot.rc_probe ready\n'
assert_cpio_entry_missing "$RC_PROBE_OUTPUT_IMAGE" shadow-boot-helper

"$REPO_ROOT/scripts/ci/pixel_boot_recover_traces_smoke.sh"

echo "pixel_boot_tooling_smoke: ok"
