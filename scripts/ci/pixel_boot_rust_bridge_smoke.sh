#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-pixel-boot-rust-bridge.XXXXXX")"
MOCK_BIN="$TMP_DIR/bin"
BOOT_BUILD_INPUT="$TMP_DIR/build-input.img"
BOOT_BUILD_RAMDISK="$TMP_DIR/build-ramdisk.cpio"
SHIM_BINARY="$TMP_DIR/hello-init-rust-shim"
CHILD_BINARY="$TMP_DIR/hello-init-rust-child"
OUTPUT_IMAGE="$TMP_DIR/rust-bridge-boot.img"
AVB_KEY_PATH="$TMP_DIR/avb-testkey.pem"
INPUT_RUN_TOKEN="rust-bridge-token-00"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$MOCK_BIN"
printf 'boot build input\n' >"$BOOT_BUILD_INPUT"
printf 'mock avb key\n' >"$AVB_KEY_PATH"

cat >"$SHIM_BINARY" <<'EOF'
#!/system/bin/sh
# shadow-owned-init-role:hello-init
# shadow-owned-init-impl:rust-static
# shadow-owned-init-config:/shadow-init.cfg
echo hello-init-rust-shim
EOF
chmod 0755 "$SHIM_BINARY"

cat >"$CHILD_BINARY" <<'EOF'
#!/system/bin/sh
# shadow-owned-init-role:hello-init
# shadow-owned-init-impl:rust-static
# shadow-owned-init-config:/shadow-init.cfg
echo hello-init-rust-child
EOF
chmod 0755 "$CHILD_BINARY"

cat >"$BOOT_BUILD_INPUT.hello-init.json" <<EOF
{
  "image": "$BOOT_BUILD_INPUT",
  "kind": "orange_gpu_build",
  "run_token": "$INPUT_RUN_TOKEN"
}
EOF

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

chmod 0755 \
  "$MOCK_BIN/adb" \
  "$MOCK_BIN/avbtool" \
  "$MOCK_BIN/file" \
  "$MOCK_BIN/just" \
  "$MOCK_BIN/mkbootimg" \
  "$MOCK_BIN/payload-dumper-go" \
  "$MOCK_BIN/unpack_bootimg"

assert_contains() {
  local haystack needle
  haystack="$1"
  needle="$2"

  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    echo "pixel_boot_rust_bridge_smoke: expected output to contain: $needle" >&2
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

actual = entries[entry_name].decode("utf-8", errors="surrogateescape")
if actual != expected_data:
    raise SystemExit(
        f"{entry_name}: expected {expected_data!r}, got {actual!r}"
    )
PY
}

export PATH="$MOCK_BIN:$PATH"
export MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK"
export PIXEL_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT"

rust_bridge_output="$(
  scripts/pixel/pixel_boot_build_rust_bridge.sh \
    --input "$BOOT_BUILD_INPUT" \
    --shim "$SHIM_BINARY" \
    --child "$CHILD_BINARY" \
    --key "$AVB_KEY_PATH" \
    --output "$OUTPUT_IMAGE"
)"

assert_contains "$rust_bridge_output" "Copied companion metadata: $OUTPUT_IMAGE.hello-init.json"
assert_contains "$rust_bridge_output" "Rust bridge input: $BOOT_BUILD_INPUT"
assert_contains "$rust_bridge_output" "Rust bridge output: $OUTPUT_IMAGE"
assert_contains "$rust_bridge_output" "Shim binary: $SHIM_BINARY"
assert_contains "$rust_bridge_output" "Child binary: $CHILD_BINARY"
assert_contains "$rust_bridge_output" "Child entry path: /hello-init-child"

assert_cpio_entry_equals "$OUTPUT_IMAGE" system/bin/init $'#!/system/bin/sh\n# shadow-owned-init-role:hello-init\n# shadow-owned-init-impl:rust-static\n# shadow-owned-init-config:/shadow-init.cfg\necho hello-init-rust-shim\n'
assert_cpio_entry_equals "$OUTPUT_IMAGE" hello-init-child $'#!/system/bin/sh\n# shadow-owned-init-role:hello-init\n# shadow-owned-init-impl:rust-static\n# shadow-owned-init-config:/shadow-init.cfg\necho hello-init-rust-child\n'
assert_json_field "$OUTPUT_IMAGE.hello-init.json" image "$OUTPUT_IMAGE"
assert_json_field "$OUTPUT_IMAGE.hello-init.json" hello_init_child_path "/hello-init-child"
assert_json_field "$OUTPUT_IMAGE.hello-init.json" hello_init_impl "rust-bridge"
assert_json_field "$OUTPUT_IMAGE.hello-init.json" hello_init_mode "rust-bridge"
assert_json_field "$OUTPUT_IMAGE.hello-init.json" kind "orange_gpu_build"
assert_json_field "$OUTPUT_IMAGE.hello-init.json" run_token "$INPUT_RUN_TOKEN"

echo "pixel_boot_rust_bridge_smoke: ok"
