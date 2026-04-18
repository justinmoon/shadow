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
ONESHOT_OUTPUT="$TMP_DIR/oneshot-output"
FLASH_RUN_OUTPUT="$TMP_DIR/flash-run-output"
BOOT_BUILD_INPUT="$TMP_DIR/build-input.img"
BOOT_BUILD_RAMDISK="$TMP_DIR/build-ramdisk.cpio"
WRAPPER_BIN="$TMP_DIR/init-wrapper"
AVB_KEY_PATH="$TMP_DIR/avb-testkey.pem"
ADDED_RC="$TMP_DIR/init.extra.rc"
PATCHED_INIT_RC="$TMP_DIR/init.rc.patched"
WRAPPER_OUTPUT_IMAGE="$TMP_DIR/wrapper-output.img"
STOCK_INIT_OUTPUT_IMAGE="$TMP_DIR/stock-init-output.img"
LOG_PROBE_OUTPUT_IMAGE="$TMP_DIR/log-probe-stock-init.img"
RC_PROBE_OUTPUT_IMAGE="$TMP_DIR/rc-probe-stock-init.img"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$MOCK_BIN"
printf 'local boot image\n' >"$LOCAL_BOOT"
printf 'shared boot image\n' >"$SHARED_BOOT"
printf 'probe image\n' >"$PROBE_IMAGE"
printf 'boot build input\n' >"$BOOT_BUILD_INPUT"
cat >"$WRAPPER_BIN" <<'EOF'
#!/system/bin/sh
echo wrapper
EOF
chmod 0755 "$WRAPPER_BIN"
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

chmod 0755 \
  "$MOCK_BIN/adb" \
  "$MOCK_BIN/just" \
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

wrapper_build_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --wrapper "$WRAPPER_BIN" \
      --key "$AVB_KEY_PATH" \
      --output "$WRAPPER_OUTPUT_IMAGE" \
      --add "init.extra.rc=$ADDED_RC"
)"
assert_contains "$wrapper_build_output" "Build mode: wrapper"
assert_cpio_entry_equals "$WRAPPER_OUTPUT_IMAGE" init $'#!/system/bin/sh\necho wrapper\n'
assert_cpio_entry_equals "$WRAPPER_OUTPUT_IMAGE" init.stock $'stock-init\n'
assert_cpio_entry_equals "$WRAPPER_OUTPUT_IMAGE" init.extra.rc $'import /init.extra.rc\n'
assert_cpio_entry_equals "$WRAPPER_OUTPUT_IMAGE" system/etc/init/hw/init.rc $'on boot\n    setprop shadow.boot.base 1\n'

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

echo "pixel_boot_tooling_smoke: ok"
