#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-pixel-boot-hello-init.XXXXXX")"
MOCK_BIN="$TMP_DIR/bin"
BOOT_BUILD_INPUT="$TMP_DIR/build-input.img"
NONSTOCK_INPUT="$TMP_DIR/nonstock-input.img"
BOOT_BUILD_RAMDISK="$TMP_DIR/build-ramdisk.cpio"
BOOT_BUILD_NONSTOCK_RAMDISK="$TMP_DIR/build-nonstock-ramdisk.cpio"
HELLO_INIT_OUTPUT="$TMP_DIR/hello-init"
OUTPUT_IMAGE="$TMP_DIR/hello-init-boot.img"
MINIMAL_OUTPUT_IMAGE="$TMP_DIR/hello-init-boot-minimal.img"
TMPFS_LOG_OUTPUT_IMAGE="$TMP_DIR/hello-init-boot-tmpfs-logs.img"
AVB_KEY_PATH="$TMP_DIR/avb-testkey.pem"
MOCK_STORE_HELLO="$TMP_DIR/store-hello"
BAD_HELLO_INIT_BINARY="$TMP_DIR/bad-hello-init"
HELLO_INIT_CACHE_OUTPUT="$TMP_DIR/hello-init-cache"
MOCK_NIX_CALLS_FILE="$TMP_DIR/mock-nix-calls"
HELLO_RUN_TOKEN="hello-run-token-17"
TMPFS_RUN_TOKEN="tmpfs-log-token-00"
MINIMAL_RUN_TOKEN="minimal-run-token-00"
SECOND_RUN_TOKEN="second-run-token-11"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$MOCK_BIN" "$MOCK_STORE_HELLO/bin"
printf 'boot build input\n' >"$BOOT_BUILD_INPUT"
printf 'nonstock build input\n' >"$NONSTOCK_INPUT"
printf 'mock avb key\n' >"$AVB_KEY_PATH"

cat >"$HELLO_INIT_OUTPUT" <<'EOF'
#!/system/bin/sh
# shadow-owned-init-role:hello-init
# shadow-owned-init-impl:c-static
# shadow-owned-init-config:/shadow-init.cfg
# shadow-owned-init-mounts:dev=true,proc=true,sys=true
echo hello-init
EOF
chmod 0755 "$HELLO_INIT_OUTPUT"
cp "$HELLO_INIT_OUTPUT" "$MOCK_STORE_HELLO/bin/hello-init"

cat >"$BAD_HELLO_INIT_BINARY" <<'EOF'
#!/system/bin/sh
# shadow-owned-init-impl:c-static
# shadow-owned-init-config:/shadow-init.cfg
echo bad-hello-init
EOF
chmod 0755 "$BAD_HELLO_INIT_BINARY"
printf '0\n' >"$MOCK_NIX_CALLS_FILE"

PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$BOOT_BUILD_RAMDISK" <<'PY'
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

entries = [
    build_entry_from_path("init", root_init_path, 1),
    build_entry_from_path("system/bin/init", system_init_path, 2),
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

PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$BOOT_BUILD_NONSTOCK_RAMDISK" <<'PY'
from pathlib import Path
import sys

from cpio_edit import CpioArchive, CpioEntry, build_entry_from_path, write_cpio

ramdisk_path = Path(sys.argv[1])
tmp_dir = ramdisk_path.parent

root_init_path = tmp_dir / "root-init-nonstock"
root_init_path.write_text("not-a-symlink\n", encoding="utf-8")
root_init_path.chmod(0o755)

system_init_path = tmp_dir / "system-bin-init-nonstock"
system_init_path.write_text("stock-system-init\n", encoding="utf-8")
system_init_path.chmod(0o755)

entries = [
    build_entry_from_path("init", root_init_path, 1),
    build_entry_from_path("system/bin/init", system_init_path, 2),
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
printf '%s: ELF 64-bit LSB executable, ARM aarch64, statically linked\n' "$1"
EOF

cat >"$MOCK_BIN/nix" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\$1" != build ]]; then
  echo "mock nix: unexpected args: \$*" >&2
  exit 1
fi

count="\$(tr -d '[:space:]' <"$MOCK_NIX_CALLS_FILE")"
printf '%s\n' "\$((count + 1))" >"$MOCK_NIX_CALLS_FILE"

case "\$*" in
  *hello-init-device*)
    printf '%s\n' "$MOCK_STORE_HELLO"
    ;;
  *)
    echo "mock nix: unexpected package ref: \$*" >&2
    exit 1
    ;;
esac
EOF

chmod 0755 \
  "$MOCK_BIN/adb" \
  "$MOCK_BIN/avbtool" \
  "$MOCK_BIN/file" \
  "$MOCK_BIN/just" \
  "$MOCK_BIN/mkbootimg" \
  "$MOCK_BIN/nix" \
  "$MOCK_BIN/payload-dumper-go" \
  "$MOCK_BIN/unpack_bootimg"

assert_contains() {
  local haystack needle
  haystack="$1"
  needle="$2"

  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    echo "pixel_boot_hello_init_smoke: expected output to contain: $needle" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

assert_file_contains() {
  local file_path needle
  file_path="$1"
  needle="$2"

  if ! grep -Fq -- "$needle" "$file_path"; then
    echo "pixel_boot_hello_init_smoke: expected $file_path to contain: $needle" >&2
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

path, key_path, expected = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

value = data
for part in key_path.split("/"):
    value = value[part]

if isinstance(value, bool):
    rendered = "true" if value else "false"
elif value is None:
    rendered = ""
else:
    rendered = str(value)

if rendered != expected:
    raise SystemExit(f"{key_path}: expected {expected!r}, got {rendered!r}")
PY
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

hello_build_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 \
    "$REPO_ROOT/scripts/pixel/pixel_build_hello_init.sh" \
      --output "$HELLO_INIT_OUTPUT"
)"
assert_contains "$hello_build_output" "Built hello-init -> $HELLO_INIT_OUTPUT"
assert_contains "$(cat "$HELLO_INIT_OUTPUT")" "shadow-owned-init-role:hello-init"
assert_contains "$(cat "$HELLO_INIT_OUTPUT")" "shadow-owned-init-impl:c-static"
assert_contains "$(cat "$HELLO_INIT_OUTPUT")" "shadow-owned-init-config:/shadow-init.cfg"
assert_contains "$(cat "$HELLO_INIT_OUTPUT")" "shadow-owned-init-mounts:dev=true,proc=true,sys=true"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'shadow-owned-init-observability:kmsg=%s,pmsg=%s,stdio=%s,run_token=%s'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"observability-degraded"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"%sdev=%s,proc=%s,sys=%s"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'shadow-owned-init-run-token:'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'run_token=%s dev_mount=%s'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'ensure_char_device("/dev/kmsg", 0600, 1U, 11U)'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'ensure_char_device("/dev/pmsg0", 0222, 250U, 0U)'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'ensure_symlink_target("/dev/stdout", "/proc/self/fd/1")'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'bootstrap_tmpfs_dev_runtime(&config)'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'bootstrap_proc_stdio_links(&config)'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'wait_for_child_with_watchdog'

hello_reuse_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 \
    "$REPO_ROOT/scripts/pixel/pixel_build_hello_init.sh" \
      --output "$HELLO_INIT_OUTPUT"
)"
assert_contains "$hello_reuse_output" "Reusing cached hello-init -> $HELLO_INIT_OUTPUT"
if [[ "$(tr -d '[:space:]' <"$MOCK_NIX_CALLS_FILE")" != "1" ]]; then
  echo "pixel_boot_hello_init_smoke: expected pixel_build_hello_init.sh to avoid a second nix build" >&2
  exit 1
fi

hello_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_HELLO_INIT_DEFAULT_BIN="$HELLO_INIT_CACHE_OUTPUT" \
    PIXEL_HELLO_INIT_RUN_TOKEN="$HELLO_RUN_TOKEN" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_hello_init.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$OUTPUT_IMAGE" \
      --payload hello \
      --hold-secs 17 \
      --reboot-target bootloader
)"
assert_contains "$hello_boot_output" "Build mode: stock-init"
assert_contains "$hello_boot_output" "Extra added entries: 1"
assert_contains "$hello_boot_output" "Extra replaced entries: 1"
assert_contains "$hello_boot_output" "Owned userspace mode: hello-init"
assert_contains "$hello_boot_output" "Root init path: preserve stock /init -> /system/bin/init symlink"
assert_contains "$hello_boot_output" "System init mutation: replace system/bin/init with the owned static hello-init PID 1"
assert_contains "$hello_boot_output" "Config path: /shadow-init.cfg"
assert_contains "$hello_boot_output" "Payload: hello"
assert_contains "$hello_boot_output" "Hold seconds: 17"
assert_contains "$hello_boot_output" "Reboot target: bootloader"
assert_contains "$hello_boot_output" "Run token: $HELLO_RUN_TOKEN"
assert_contains "$hello_boot_output" "Dev mount style: devtmpfs"
assert_contains "$hello_boot_output" "Mount /dev: true"
assert_contains "$hello_boot_output" "Mount proc: true"
assert_contains "$hello_boot_output" "Mount sys: true"
assert_contains "$hello_boot_output" "Log kmsg: true"
assert_contains "$hello_boot_output" "Log pmsg: true"
assert_contains "$hello_boot_output" "Metadata path: $OUTPUT_IMAGE.hello-init.json"
assert_contains "$hello_boot_output" "Built hello-init -> $HELLO_INIT_CACHE_OUTPUT"
assert_cpio_entry_symlink_target "$OUTPUT_IMAGE" init "/system/bin/init"
assert_cpio_entry_equals "$OUTPUT_IMAGE" system/bin/init $'#!/system/bin/sh\n# shadow-owned-init-role:hello-init\n# shadow-owned-init-impl:c-static\n# shadow-owned-init-config:/shadow-init.cfg\n# shadow-owned-init-mounts:dev=true,proc=true,sys=true\necho hello-init\n'
assert_cpio_entry_equals "$OUTPUT_IMAGE" shadow-init.cfg $'# Generated by pixel_boot_build_hello_init.sh\npayload=hello\nhold_seconds=17\nreboot_target=bootloader\nrun_token=hello-run-token-17\n'
assert_cpio_entry_missing "$OUTPUT_IMAGE" system/bin/init.stock
assert_json_field "$OUTPUT_IMAGE.hello-init.json" kind hello_init_build
assert_json_field "$OUTPUT_IMAGE.hello-init.json" image "$OUTPUT_IMAGE"
assert_json_field "$OUTPUT_IMAGE.hello-init.json" payload hello
assert_json_field "$OUTPUT_IMAGE.hello-init.json" run_token "$HELLO_RUN_TOKEN"
assert_json_field "$OUTPUT_IMAGE.hello-init.json" log_kmsg true
assert_json_field "$OUTPUT_IMAGE.hello-init.json" log_pmsg true

tmpfs_log_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_HELLO_INIT_DEFAULT_BIN="$HELLO_INIT_CACHE_OUTPUT" \
    PIXEL_HELLO_INIT_RUN_TOKEN="$TMPFS_RUN_TOKEN" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_hello_init.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$TMPFS_LOG_OUTPUT_IMAGE" \
      --payload hello \
      --hold-secs 0 \
      --reboot-target restart \
      --dev-mount tmpfs \
      --mount-sys false
)"
assert_contains "$tmpfs_log_boot_output" "Dev mount style: tmpfs"
assert_contains "$tmpfs_log_boot_output" "Mount /dev: true"
assert_contains "$tmpfs_log_boot_output" "Mount proc: true"
assert_contains "$tmpfs_log_boot_output" "Mount sys: false"
assert_contains "$tmpfs_log_boot_output" "Log kmsg: true"
assert_contains "$tmpfs_log_boot_output" "Log pmsg: true"
assert_contains "$tmpfs_log_boot_output" "Run token: $TMPFS_RUN_TOKEN"
assert_cpio_entry_equals "$TMPFS_LOG_OUTPUT_IMAGE" shadow-init.cfg $'# Generated by pixel_boot_build_hello_init.sh\npayload=hello\nhold_seconds=0\nreboot_target=restart\nrun_token=tmpfs-log-token-00\ndev_mount=tmpfs\nmount_sys=false\n'
assert_json_field "$TMPFS_LOG_OUTPUT_IMAGE.hello-init.json" run_token "$TMPFS_RUN_TOKEN"
assert_json_field "$TMPFS_LOG_OUTPUT_IMAGE.hello-init.json" dev_mount tmpfs

minimal_hello_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_HELLO_INIT_DEFAULT_BIN="$HELLO_INIT_CACHE_OUTPUT" \
    PIXEL_HELLO_INIT_RUN_TOKEN="$MINIMAL_RUN_TOKEN" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_hello_init.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$MINIMAL_OUTPUT_IMAGE" \
      --payload hello \
      --hold-secs 0 \
      --reboot-target restart \
      --dev-mount tmpfs \
      --mount-dev false \
      --mount-proc false \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"
assert_contains "$minimal_hello_boot_output" "Dev mount style: tmpfs"
assert_contains "$minimal_hello_boot_output" "Mount /dev: false"
assert_contains "$minimal_hello_boot_output" "Mount proc: false"
assert_contains "$minimal_hello_boot_output" "Mount sys: false"
assert_contains "$minimal_hello_boot_output" "Log kmsg: false"
assert_contains "$minimal_hello_boot_output" "Log pmsg: false"
assert_contains "$minimal_hello_boot_output" "Run token: $MINIMAL_RUN_TOKEN"
assert_cpio_entry_equals "$MINIMAL_OUTPUT_IMAGE" shadow-init.cfg $'# Generated by pixel_boot_build_hello_init.sh\npayload=hello\nhold_seconds=0\nreboot_target=restart\nrun_token=minimal-run-token-00\ndev_mount=tmpfs\nmount_dev=false\nmount_proc=false\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\n'
assert_json_field "$MINIMAL_OUTPUT_IMAGE.hello-init.json" run_token "$MINIMAL_RUN_TOKEN"
assert_json_field "$MINIMAL_OUTPUT_IMAGE.hello-init.json" mount_dev false
assert_json_field "$MINIMAL_OUTPUT_IMAGE.hello-init.json" mount_proc false

second_hello_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_HELLO_INIT_DEFAULT_BIN="$HELLO_INIT_CACHE_OUTPUT" \
    PIXEL_HELLO_INIT_RUN_TOKEN="$SECOND_RUN_TOKEN" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_hello_init.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/hello-init-boot-second.img" \
      --payload hello \
      --hold-secs 11 \
      --reboot-target bootloader
)"
assert_contains "$second_hello_boot_output" "Reusing cached hello-init -> $HELLO_INIT_CACHE_OUTPUT"
assert_contains "$second_hello_boot_output" "Run token: $SECOND_RUN_TOKEN"
if [[ "$(tr -d '[:space:]' <"$MOCK_NIX_CALLS_FILE")" != "2" ]]; then
  echo "pixel_boot_hello_init_smoke: expected exactly two nix builds total after two boot-image builds" >&2
  exit 1
fi

chmod 0644 "$HELLO_INIT_CACHE_OUTPUT"
mode_repair_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 \
    "$REPO_ROOT/scripts/pixel/pixel_build_hello_init.sh" \
      --output "$HELLO_INIT_CACHE_OUTPUT"
)"
assert_contains "$mode_repair_output" "Reusing cached hello-init -> $HELLO_INIT_CACHE_OUTPUT"
if [[ ! -x "$HELLO_INIT_CACHE_OUTPUT" ]]; then
  echo "pixel_boot_hello_init_smoke: expected cached hello-init reuse to restore execute permissions" >&2
  exit 1
fi
if [[ "$(tr -d '[:space:]' <"$MOCK_NIX_CALLS_FILE")" != "2" ]]; then
  echo "pixel_boot_hello_init_smoke: expected mode repair reuse to avoid a new nix build" >&2
  exit 1
fi

printf '%s\n' 'deadbeef' >"$HELLO_INIT_CACHE_OUTPUT.build-id"
poisoned_cache_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 \
    "$REPO_ROOT/scripts/pixel/pixel_build_hello_init.sh" \
      --output "$HELLO_INIT_CACHE_OUTPUT"
)"
assert_contains "$poisoned_cache_output" "Built hello-init -> $HELLO_INIT_CACHE_OUTPUT"
if [[ "$(tr -d '[:space:]' <"$MOCK_NIX_CALLS_FILE")" != "3" ]]; then
  echo "pixel_boot_hello_init_smoke: expected poisoned cache rebuild to perform one more nix build" >&2
  exit 1
fi

set +e
nonstock_root_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_NONSTOCK_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_HELLO_INIT_DEFAULT_BIN="$HELLO_INIT_CACHE_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_hello_init.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-nonstock-root.img" 2>&1
)"
nonstock_root_status="$?"
set -e
if [[ "$nonstock_root_status" -eq 0 ]]; then
  echo "pixel_boot_hello_init_smoke: hello-init builder should reject a non-stock root /init shape" >&2
  exit 1
fi
assert_contains "$nonstock_root_output" "expected stock root /init symlink to /system/bin/init"

set +e
bad_binary_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_HELLO_INIT_DEFAULT_BIN="$HELLO_INIT_CACHE_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_hello_init.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$BAD_HELLO_INIT_BINARY" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-bad-hello-init.img" 2>&1
)"
bad_binary_status="$?"
set -e
if [[ "$bad_binary_status" -eq 0 ]]; then
  echo "pixel_boot_hello_init_smoke: hello-init builder should reject a binary without the role sentinel" >&2
  exit 1
fi
assert_contains "$bad_binary_output" "binary is missing the hello-init role sentinel"

set +e
bad_bool_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_HELLO_INIT_DEFAULT_BIN="$HELLO_INIT_CACHE_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_hello_init.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-bad-bool.img" \
      --mount-dev maybe 2>&1
)"
bad_bool_status="$?"
set -e
if [[ "$bad_bool_status" -eq 0 ]]; then
  echo "pixel_boot_hello_init_smoke: hello-init builder should reject unsupported bool words" >&2
  exit 1
fi
assert_contains "$bad_bool_output" "mount-dev must be true or false: maybe"

set +e
long_reboot_target_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_HELLO_INIT_DEFAULT_BIN="$HELLO_INIT_CACHE_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_hello_init.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-long-reboot-target.img" \
      --reboot-target "bootloader-target-name-that-is-way-too-long" 2>&1
)"
long_reboot_target_status="$?"
set -e
if [[ "$long_reboot_target_status" -eq 0 ]]; then
  echo "pixel_boot_hello_init_smoke: hello-init builder should reject an oversized reboot target" >&2
  exit 1
fi
assert_contains "$long_reboot_target_output" "reboot-target value exceeds max length 31"

set +e
nonstock_input_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_HELLO_INIT_DEFAULT_BIN="$HELLO_INIT_CACHE_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_hello_init.sh" \
      --input "$NONSTOCK_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-nonstock-input.img" 2>&1
)"
nonstock_input_status="$?"
set -e
if [[ "$nonstock_input_status" -eq 0 ]]; then
  echo "pixel_boot_hello_init_smoke: hello-init builder should reject a non-stock input image" >&2
  exit 1
fi
assert_contains "$nonstock_input_output" "input image must match the cached stock boot image exactly"

echo "pixel_boot_hello_init_smoke: ok"
