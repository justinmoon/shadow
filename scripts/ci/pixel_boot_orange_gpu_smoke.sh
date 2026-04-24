#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-pixel-boot-orange-gpu.XXXXXX")"
MOCK_BIN="$TMP_DIR/bin"
MOCK_NIX_BIN="$TMP_DIR/nix-bin"
MOCK_RUST_STORE="$TMP_DIR/mock-rust-store"
BOOT_BUILD_INPUT="$TMP_DIR/build-input.img"
BOOT_BUILD_RAMDISK="$TMP_DIR/build-ramdisk.cpio"
HELLO_INIT_OUTPUT="$TMP_DIR/hello-init"
HELLO_INIT_RUST_CHILD_OUTPUT="$TMP_DIR/hello-init-rust-child"
HELLO_INIT_RUST_SHIM_OUTPUT="$TMP_DIR/hello-init-rust-shim"
HELLO_INIT_RUST_EXEC_SHIM_OUTPUT="$TMP_DIR/hello-init-rust-shim-exec"
ORANGE_INIT_OUTPUT="$TMP_DIR/orange-init"
SHADOW_SESSION_OUTPUT="$TMP_DIR/shadow-session"
SHADOW_COMPOSITOR_OUTPUT="$TMP_DIR/shadow-compositor-guest"
SHADOW_COMPOSITOR_DYNAMIC_OUTPUT="$TMP_DIR/shadow-compositor-guest-gnu"
APP_DIRECT_PRESENT_LAUNCHER_OUTPUT="$TMP_DIR/app-direct-present-launcher"
GPU_BUNDLE_DIR="$TMP_DIR/gpu-bundle"
APP_DIRECT_PRESENT_BUNDLE_DIR="$TMP_DIR/app-direct-present-bundle"
TS_APP_DIRECT_PRESENT_BUNDLE_DIR="$TMP_DIR/ts-app-direct-present-bundle"
TS_TIMELINE_APP_DIRECT_PRESENT_BUNDLE_DIR="$TMP_DIR/ts-timeline-app-direct-present-bundle"
BAD_LOADER_BUNDLE_DIR="$TMP_DIR/bad-loader-bundle"
BAD_BINARY_BUNDLE_DIR="$TMP_DIR/bad-binary-bundle"
CAMERA_LINKER_CAPSULE_DIR="$TMP_DIR/camera-linker-capsule"
CAMERA_HAL_BIONIC_PROBE_BINARY="$TMP_DIR/camera-hal-bionic-probe"
OUTPUT_IMAGE="$TMP_DIR/orange-gpu-boot.img"
DEFAULT_OUTPUT_IMAGE="$TMP_DIR/orange-gpu-default-boot.img"
AVB_KEY_PATH="$TMP_DIR/avb-testkey.pem"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p \
  "$MOCK_BIN" \
  "$MOCK_NIX_BIN" \
  "$MOCK_RUST_STORE/bin" \
  "$GPU_BUNDLE_DIR/lib" \
  "$GPU_BUNDLE_DIR/share/vulkan/icd.d" \
  "$APP_DIRECT_PRESENT_BUNDLE_DIR/lib" \
  "$TS_APP_DIRECT_PRESENT_BUNDLE_DIR/lib" \
  "$TS_TIMELINE_APP_DIRECT_PRESENT_BUNDLE_DIR/lib" \
  "$BAD_LOADER_BUNDLE_DIR/lib" \
  "$BAD_LOADER_BUNDLE_DIR/share/vulkan/icd.d" \
  "$BAD_BINARY_BUNDLE_DIR/lib" \
  "$BAD_BINARY_BUNDLE_DIR/share/vulkan/icd.d" \
  "$CAMERA_LINKER_CAPSULE_DIR/vendor/lib64/hw" \
  "$CAMERA_LINKER_CAPSULE_DIR/system/lib64" \
  "$CAMERA_LINKER_CAPSULE_DIR/apex/com.android.runtime/bin" \
  "$CAMERA_LINKER_CAPSULE_DIR/linkerconfig"
printf 'boot build input\n' >"$BOOT_BUILD_INPUT"
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

cat >"$HELLO_INIT_RUST_CHILD_OUTPUT" <<'EOF'
#!/system/bin/sh
# shadow-owned-init-role:hello-init
# shadow-owned-init-impl:rust-static
# shadow-owned-init-config:/shadow-init.cfg
echo hello-init-rust-child
EOF
chmod 0755 "$HELLO_INIT_RUST_CHILD_OUTPUT"
cp "$HELLO_INIT_RUST_CHILD_OUTPUT" "$MOCK_RUST_STORE/bin/hello-init"

cat >"$HELLO_INIT_RUST_SHIM_OUTPUT" <<'EOF'
#!/system/bin/sh
# shadow-owned-init-role:hello-init
# shadow-owned-init-impl:rust-static
# shadow-owned-init-config:/shadow-init.cfg
echo hello-init-rust-shim
EOF
chmod 0755 "$HELLO_INIT_RUST_SHIM_OUTPUT"

cat >"$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" <<'EOF'
#!/system/bin/sh
# shadow-owned-init-role:hello-init
# shadow-owned-init-impl:rust-static
# shadow-owned-init-config:/shadow-init.cfg
echo hello-init-rust-shim-exec
EOF
chmod 0755 "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT"

cat >"$ORANGE_INIT_OUTPUT" <<'EOF'
#!/system/bin/sh
# shadow-owned-init-role:orange-init
# shadow-owned-init-impl:drm-rect-device
# shadow-owned-init-path:/orange-init
echo orange-init
EOF
chmod 0755 "$ORANGE_INIT_OUTPUT"

cat >"$SHADOW_SESSION_OUTPUT" <<'EOF'
#!/system/bin/sh
echo shadow-session
EOF
chmod 0755 "$SHADOW_SESSION_OUTPUT"

cat >"$SHADOW_COMPOSITOR_OUTPUT" <<'EOF'
#!/system/bin/sh
echo shadow-compositor-guest
EOF
chmod 0755 "$SHADOW_COMPOSITOR_OUTPUT"

cat >"$SHADOW_COMPOSITOR_DYNAMIC_OUTPUT" <<'EOF'
ELF_BINARY_AARCH64
shadow-compositor-guest
EOF
chmod 0755 "$SHADOW_COMPOSITOR_DYNAMIC_OUTPUT"

cat >"$APP_DIRECT_PRESENT_LAUNCHER_OUTPUT" <<'EOF'
MOCK_AARCH64_STATIC_APP_DIRECT_PRESENT_LAUNCHER
shadow-app-direct-present-launcher-role:static-loader-exec
EOF
chmod 0755 "$APP_DIRECT_PRESENT_LAUNCHER_OUTPUT"

printf 'ELF_RUST_DEMO_AARCH64\n' >"$APP_DIRECT_PRESENT_BUNDLE_DIR/shadow-rust-demo"
chmod 0755 "$APP_DIRECT_PRESENT_BUNDLE_DIR/shadow-rust-demo"
printf 'ELF_RUNTIME_LOADER_AARCH64\n' >"$APP_DIRECT_PRESENT_BUNDLE_DIR/lib/ld-linux-aarch64.so.1"
chmod 0755 "$APP_DIRECT_PRESENT_BUNDLE_DIR/lib/ld-linux-aarch64.so.1"
printf 'ELF_LIBC_AARCH64\n' >"$APP_DIRECT_PRESENT_BUNDLE_DIR/lib/libc.so.6"
printf 'ELF_LIBM_AARCH64\n' >"$APP_DIRECT_PRESENT_BUNDLE_DIR/lib/libm.so.6"
printf 'ELF_LIBGCC_S_AARCH64\n' >"$APP_DIRECT_PRESENT_BUNDLE_DIR/lib/libgcc_s.so.1"

printf 'ELF_CAMERA_HAL_SM6150\n' >"$CAMERA_LINKER_CAPSULE_DIR/vendor/lib64/hw/camera.sm6150.so"
printf 'ELF_LIBCAMERA_METADATA\n' >"$CAMERA_LINKER_CAPSULE_DIR/system/lib64/libcamera_metadata.so"
printf 'ELF_ANDROID_RUNTIME_LINKER64\n' >"$CAMERA_LINKER_CAPSULE_DIR/apex/com.android.runtime/bin/linker64"
printf 'dir.system = /system\n' >"$CAMERA_LINKER_CAPSULE_DIR/linkerconfig/ld.config.txt"
chmod 0755 "$CAMERA_LINKER_CAPSULE_DIR/apex/com.android.runtime/bin/linker64"
printf 'ELF_CAMERA_HAL_BIONIC_PROBE\n' >"$CAMERA_HAL_BIONIC_PROBE_BINARY"
chmod 0755 "$CAMERA_HAL_BIONIC_PROBE_BINARY"

printf 'ELF_BLITZ_AARCH64\n' >"$TS_APP_DIRECT_PRESENT_BUNDLE_DIR/shadow-blitz-demo"
chmod 0755 "$TS_APP_DIRECT_PRESENT_BUNDLE_DIR/shadow-blitz-demo"
printf 'ELF_SHADOW_SYSTEM_AARCH64\n' >"$TS_APP_DIRECT_PRESENT_BUNDLE_DIR/shadow-system"
chmod 0755 "$TS_APP_DIRECT_PRESENT_BUNDLE_DIR/shadow-system"
printf 'console.error("counter bundle")\n' >"$TS_APP_DIRECT_PRESENT_BUNDLE_DIR/runtime-app-counter-bundle.js"
printf 'ELF_RUNTIME_LOADER_AARCH64\n' >"$TS_APP_DIRECT_PRESENT_BUNDLE_DIR/lib/ld-linux-aarch64.so.1"
chmod 0755 "$TS_APP_DIRECT_PRESENT_BUNDLE_DIR/lib/ld-linux-aarch64.so.1"
printf 'ELF_LIBC_AARCH64\n' >"$TS_APP_DIRECT_PRESENT_BUNDLE_DIR/lib/libc.so.6"
printf 'ELF_LIBM_AARCH64\n' >"$TS_APP_DIRECT_PRESENT_BUNDLE_DIR/lib/libm.so.6"
printf 'ELF_LIBGCC_S_AARCH64\n' >"$TS_APP_DIRECT_PRESENT_BUNDLE_DIR/lib/libgcc_s.so.1"

cp -R "$TS_APP_DIRECT_PRESENT_BUNDLE_DIR"/. "$TS_TIMELINE_APP_DIRECT_PRESENT_BUNDLE_DIR"/
rm -f "$TS_TIMELINE_APP_DIRECT_PRESENT_BUNDLE_DIR/runtime-app-counter-bundle.js"
printf 'console.error("timeline bundle")\n' >"$TS_TIMELINE_APP_DIRECT_PRESENT_BUNDLE_DIR/runtime-app-timeline-bundle.js"

printf 'ELF_BINARY_AARCH64\n' >"$GPU_BUNDLE_DIR/shadow-gpu-smoke"
chmod 0755 "$GPU_BUNDLE_DIR/shadow-gpu-smoke"
printf 'ELF_LOADER_AARCH64\n' >"$GPU_BUNDLE_DIR/lib/ld-linux-aarch64.so.1"
chmod 0755 "$GPU_BUNDLE_DIR/lib/ld-linux-aarch64.so.1"
printf 'ELF_VULKAN_LOADER_AARCH64\n' >"$GPU_BUNDLE_DIR/lib/libvulkan.so.1"
printf 'ELF_TURNIP_AARCH64\n' >"$GPU_BUNDLE_DIR/lib/libvulkan_freedreno.so"
cat >"$GPU_BUNDLE_DIR/share/vulkan/icd.d/freedreno_icd.aarch64.json" <<'EOF'
{
  "ICD": {
    "api_version": "1.4.335",
    "library_arch": "64",
    "library_path": "/orange-gpu/lib/libvulkan_freedreno.so"
  },
  "file_format_version": "1.0.1"
}
EOF

cp -R "$GPU_BUNDLE_DIR"/. "$BAD_LOADER_BUNDLE_DIR"/
cp -R "$GPU_BUNDLE_DIR"/. "$BAD_BINARY_BUNDLE_DIR"/
printf 'not-an-elf-loader\n' >"$BAD_LOADER_BUNDLE_DIR/lib/ld-linux-aarch64.so.1"
chmod 0755 "$BAD_LOADER_BUNDLE_DIR/lib/ld-linux-aarch64.so.1"
printf '#!/bin/sh\necho not-an-elf-binary\n' >"$BAD_BINARY_BUNDLE_DIR/shadow-gpu-smoke"
chmod 0755 "$BAD_BINARY_BUNDLE_DIR/shadow-gpu-smoke"

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

cat >"$MOCK_NIX_BIN/nix" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$MOCK_RUST_STORE"
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
target=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--brief)
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "mock file: unexpected option: $1" >&2
      exit 1
      ;;
    *)
      target="$1"
      shift
      break
      ;;
  esac
done

if [[ -z "$target" && $# -gt 0 ]]; then
  target="$1"
fi

[[ -n "$target" ]] || {
  echo "mock file: missing target" >&2
  exit 1
}

if grep -aFq -- 'ELF_LOADER_AARCH64' "$target" 2>/dev/null; then
  printf '%s: ELF 64-bit LSB shared object, ARM aarch64, version 1 (SYSV), static-pie linked, not stripped\n' "$target"
elif grep -aFq -- 'ELF_BINARY_AARCH64' "$target" 2>/dev/null; then
  printf '%s: ELF 64-bit LSB pie executable, ARM aarch64, version 1 (SYSV), dynamically linked, interpreter /orange-gpu/lib/ld-linux-aarch64.so.1, not stripped\n' "$target"
elif grep -aFq -- 'ELF_BLITZ_AARCH64' "$target" 2>/dev/null || grep -aFq -- 'ELF_SHADOW_SYSTEM_AARCH64' "$target" 2>/dev/null; then
  printf '%s: ELF 64-bit LSB pie executable, ARM aarch64, version 1 (SYSV), dynamically linked, interpreter /orange-gpu/app-direct-present/lib/ld-linux-aarch64.so.1, not stripped\n' "$target"
elif grep -aFq -- 'shadow-owned-init-role:orange-init' "$target" 2>/dev/null; then
  printf '%s: ELF 64-bit LSB executable, ARM aarch64, statically linked\n' "$target"
elif grep -aFq -- 'shadow-owned-init-role:hello-init' "$target" 2>/dev/null; then
  printf '%s: ELF 64-bit LSB executable, ARM aarch64, statically linked\n' "$target"
elif grep -aFq -- 'shadow-session' "$target" 2>/dev/null; then
  printf '%s: ELF 64-bit LSB executable, ARM aarch64, statically linked\n' "$target"
elif grep -aFq -- 'shadow-compositor-guest' "$target" 2>/dev/null; then
  printf '%s: ELF 64-bit LSB executable, ARM aarch64, statically linked\n' "$target"
elif grep -aFq -- 'shadow-app-direct-present-launcher-role:static-loader-exec' "$target" 2>/dev/null; then
  printf '%s: ELF 64-bit LSB executable, ARM aarch64, statically linked\n' "$target"
elif grep -aFq -- 'ELF_VULKAN_LOADER_AARCH64' "$target" 2>/dev/null || grep -aFq -- 'ELF_TURNIP_AARCH64' "$target" 2>/dev/null; then
  printf '%s: ELF 64-bit LSB shared object, ARM aarch64, version 1 (SYSV), dynamically linked, not stripped\n' "$target"
elif grep -aq '^#!' "$target" 2>/dev/null; then
  printf '%s: POSIX shell script, ASCII text executable\n' "$target"
else
  printf '%s: ASCII text\n' "$target"
fi
EOF

chmod 0755 \
  "$MOCK_BIN/adb" \
  "$MOCK_BIN/avbtool" \
  "$MOCK_BIN/file" \
  "$MOCK_BIN/just" \
  "$MOCK_BIN/mkbootimg" \
  "$MOCK_BIN/payload-dumper-go" \
  "$MOCK_BIN/unpack_bootimg" \
  "$MOCK_NIX_BIN/nix"

assert_contains() {
  local haystack needle
  haystack="$1"
  needle="$2"

  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    echo "pixel_boot_orange_gpu_smoke: expected output to contain: $needle" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

assert_command_fails_contains() {
  local expected="$1"
  shift
  local output_path="$TMP_DIR/command-failure.out"

  if "$@" >"$output_path" 2>&1; then
    echo "pixel_boot_orange_gpu_smoke: expected command to fail: $*" >&2
    cat "$output_path" >&2
    exit 1
  fi

  assert_contains "$(cat "$output_path")" "$expected"
}

run_shadow_gpu_cli_allow_headless_skip() {
  local scene="$1"
  shift
  local output_path="$TMP_DIR/${scene}.out"

  if "$@" >"$output_path" 2>&1; then
    cat "$output_path"
    return 0
  fi

  if grep -Fq -- 'No suitable graphics adapter found' "$output_path"; then
    printf '%s cli: explicit host skip because no graphics adapter is present\n' "$scene"
    return 0
  fi

  cat "$output_path" >&2
  exit 1
}

assert_file_contains() {
  local file_path needle
  file_path="$1"
  needle="$2"

  if ! grep -Fq -- "$needle" "$file_path"; then
    echo "pixel_boot_orange_gpu_smoke: expected $file_path to contain: $needle" >&2
    exit 1
  fi
}

assert_file_not_contains() {
  local file_path needle
  file_path="$1"
  needle="$2"

  if grep -Fq -- "$needle" "$file_path"; then
    echo "pixel_boot_orange_gpu_smoke: expected $file_path to omit: $needle" >&2
    exit 1
  fi
}

assert_json_field_equals() {
  local file_path key expected
  file_path="$1"
  key="$2"
  expected="$3"

  python3 - "$file_path" "$key" "$expected" <<'PY'
import json
import sys
from pathlib import Path

file_path, key, expected = sys.argv[1:4]
payload = json.loads(Path(file_path).read_text(encoding="utf-8"))
actual = payload.get(key)
if isinstance(actual, bool):
    actual = "true" if actual else "false"
elif actual is None:
    actual = ""
else:
    actual = str(actual)

if actual != expected:
    raise SystemExit(f"unexpected json value for {key}: {actual!r} != {expected!r}")
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

assert_cpio_entry_contains() {
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
if expected_data.encode("utf-8") not in entries[entry_name]:
    raise SystemExit(
        f"cpio entry {entry_name} does not contain expected data: {expected_data!r}"
    )
PY
}

assert_cpio_entry_present() {
  local archive_path entry_name
  archive_path="$1"
  entry_name="$2"

  PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$archive_path" "$entry_name" <<'PY'
from pathlib import Path
import sys

from cpio_edit import read_cpio

archive_path, entry_name = sys.argv[1:3]
entries = {entry.name for entry in read_cpio(Path(archive_path)).without_trailer()}
if entry_name not in entries:
    raise SystemExit(f"missing cpio entry: {entry_name}")
PY
}

assert_cpio_entry_absent() {
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

assert_cpio_tar_xz_entry_present() {
  local archive_path cpio_entry tar_entry
  archive_path="$1"
  cpio_entry="$2"
  tar_entry="$3"

  PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$archive_path" "$cpio_entry" "$tar_entry" <<'PY'
from pathlib import Path
import io
import sys
import tarfile

from cpio_edit import read_cpio

archive_path, cpio_entry, tar_entry = sys.argv[1:4]
entries = {
    entry.name: entry.data
    for entry in read_cpio(Path(archive_path)).without_trailer()
}
payload = entries.get(cpio_entry)
if payload is None:
    raise SystemExit(f"missing cpio entry: {cpio_entry}")
with tarfile.open(fileobj=io.BytesIO(payload), mode="r:xz") as archive:
    names = {member.name.removeprefix("./") for member in archive.getmembers()}
if tar_entry not in names:
    raise SystemExit(f"missing tar.xz entry: {tar_entry}")
PY
}

assert_cpio_tar_xz_entry_absent() {
  local archive_path cpio_entry tar_entry
  archive_path="$1"
  cpio_entry="$2"
  tar_entry="$3"

  PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$archive_path" "$cpio_entry" "$tar_entry" <<'PY'
from pathlib import Path
import io
import sys
import tarfile

from cpio_edit import read_cpio

archive_path, cpio_entry, tar_entry = sys.argv[1:4]
entries = {
    entry.name: entry.data
    for entry in read_cpio(Path(archive_path)).without_trailer()
}
payload = entries.get(cpio_entry)
if payload is None:
    raise SystemExit(f"missing cpio entry: {cpio_entry}")
with tarfile.open(fileobj=io.BytesIO(payload), mode="r:xz") as archive:
    names = {member.name.removeprefix("./") for member in archive.getmembers()}
if tar_entry in names:
    raise SystemExit(f"unexpected tar.xz entry present: {tar_entry}")
PY
}

assert_cpio_tar_xz_entry_equals() {
  local archive_path cpio_entry tar_entry expected_data
  archive_path="$1"
  cpio_entry="$2"
  tar_entry="$3"
  expected_data="$4"

  PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$archive_path" "$cpio_entry" "$tar_entry" "$expected_data" <<'PY'
from pathlib import Path
import io
import sys
import tarfile

from cpio_edit import read_cpio

archive_path, cpio_entry, tar_entry, expected_data = sys.argv[1:5]
entries = {
    entry.name: entry.data
    for entry in read_cpio(Path(archive_path)).without_trailer()
}
payload = entries.get(cpio_entry)
if payload is None:
    raise SystemExit(f"missing cpio entry: {cpio_entry}")
with tarfile.open(fileobj=io.BytesIO(payload), mode="r:xz") as archive:
    members = {member.name.removeprefix("./"): member for member in archive.getmembers()}
    member = members.get(tar_entry)
    if member is None:
        raise SystemExit(f"missing tar.xz entry: {tar_entry}")
    extracted = archive.extractfile(member)
    data = b"" if extracted is None else extracted.read()
if data != expected_data.encode("utf-8"):
    raise SystemExit(f"unexpected tar.xz entry contents for {tar_entry}: {data!r}")
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

assert_orange_gpu_offscreen_branch_shape() {
  python3 - "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "} else if (orange_gpu_mode_is_vulkan_offscreen(config)) {"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing offscreen branch marker")
start += len(marker)
end = source.find("\n        } else {", start)
if end < 0:
    raise SystemExit("missing end of offscreen branch")
branch = source[start:end]
required = [
    'scene=smoke mode=vulkan-offscreen',
    '"--scene"',
    '"smoke"',
    '"--summary-path"',
]
for needle in required:
    if needle not in branch:
        raise SystemExit(f"missing offscreen branch needle: {needle}")
for needle in ['"--present-kms"', 'hold_seconds,']:
    if needle in branch:
        raise SystemExit(f"unexpected offscreen branch needle: {needle}")
PY
}

assert_orange_gpu_instance_branch_shape() {
  python3 - "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "} else if (orange_gpu_mode_is_vulkan_instance_smoke(config)) {"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing instance-smoke branch marker")
start += len(marker)
end = source.find("\n        } else if (orange_gpu_mode_is_raw_vulkan_instance_smoke(config)) {", start)
if end < 0:
    raise SystemExit("missing end of instance-smoke branch")
branch = source[start:end]
required = [
    'scene=instance-smoke mode=vulkan-instance-smoke',
    '"--scene"',
    '"instance-smoke"',
    '"--summary-path"',
]
for needle in required:
    if needle not in branch:
        raise SystemExit(f"missing instance-smoke branch needle: {needle}")
for needle in ['"--present-kms"', 'hold_seconds,']:
    if needle in branch:
        raise SystemExit(f"unexpected instance-smoke branch needle: {needle}")
PY
}

assert_orange_gpu_raw_vulkan_instance_branch_shape() {
  python3 - "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "} else if (orange_gpu_mode_is_raw_vulkan_instance_smoke(config)) {"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing raw-vulkan-instance-smoke branch marker")
start += len(marker)
end = source.find("\n        } else if (orange_gpu_mode_is_firmware_probe_only(config)) {", start)
if end < 0:
    raise SystemExit("missing end of raw-vulkan-instance-smoke branch")
branch = source[start:end]
required = [
    'scene=raw-vulkan-instance-smoke mode=raw-vulkan-instance-smoke',
    '"--scene"',
    '"raw-vulkan-instance-smoke"',
    '"--summary-path"',
]
for needle in required:
    if needle not in branch:
        raise SystemExit(f"missing raw-vulkan-instance-smoke branch needle: {needle}")
for needle in ['"--present-kms"', 'hold_seconds,']:
    if needle in branch:
        raise SystemExit(f"unexpected raw-vulkan-instance-smoke branch needle: {needle}")
PY
}

assert_orange_gpu_firmware_probe_only_branch_shape() {
  python3 - "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "} else if (orange_gpu_mode_is_firmware_probe_only(config)) {"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing firmware-probe-only branch marker")
start += len(marker)
end = source.find("\n        } else if (orange_gpu_mode_is_c_kgsl_open_readonly_smoke(config)) {", start)
if end < 0:
    raise SystemExit("missing end of firmware-probe-only branch")
branch = source[start:end]
required = [
    '"orange-gpu-child-c-probe"',
    '"mode=firmware-probe-only"',
    "_exit(probe_bootstrap_gpu_firmware(",
]
for needle in required:
    if needle not in branch:
        raise SystemExit(f"missing firmware-probe-only branch needle: {needle}")
for needle in ['"--scene"', 'shadow-gpu-smoke']:
    if needle in branch:
        raise SystemExit(f"unexpected firmware-probe-only branch needle: {needle}")
PY
}

assert_orange_gpu_raw_vulkan_physical_device_count_branch_shape() {
  python3 - "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "} else if (orange_gpu_mode_is_raw_vulkan_physical_device_count_smoke(config)) {"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing raw-vulkan-physical-device-count-smoke branch marker")
start += len(marker)
end = source.find("\n        } else if (orange_gpu_mode_is_raw_vulkan_physical_device_count_query_no_destroy_smoke(config)) {", start)
if end < 0:
    raise SystemExit("missing end of raw-vulkan-physical-device-count-smoke branch")
branch = source[start:end]
required = [
    'scene=raw-vulkan-physical-device-count-smoke mode=raw-vulkan-physical-device-count-smoke',
    '"--scene"',
    '"raw-vulkan-physical-device-count-smoke"',
    '"--summary-path"',
]
for needle in required:
    if needle not in branch:
        raise SystemExit(f"missing raw-vulkan-physical-device-count-smoke branch needle: {needle}")
for needle in ['"--present-kms"', 'hold_seconds,']:
    if needle in branch:
        raise SystemExit(f"unexpected raw-vulkan-physical-device-count-smoke branch needle: {needle}")
PY
}

assert_orange_gpu_raw_vulkan_physical_device_count_query_no_destroy_branch_shape() {
  python3 - "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "} else if (orange_gpu_mode_is_raw_vulkan_physical_device_count_query_no_destroy_smoke(config)) {"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing raw-vulkan-physical-device-count-query-no-destroy-smoke branch marker")
start += len(marker)
end = source.find("\n        } else if (orange_gpu_mode_is_raw_vulkan_physical_device_count_query_exit_smoke(config)) {", start)
if end < 0:
    raise SystemExit("missing end of raw-vulkan-physical-device-count-query-no-destroy-smoke branch")
branch = source[start:end]
required = [
    'scene=raw-vulkan-physical-device-count-query-no-destroy-smoke mode=raw-vulkan-physical-device-count-query-no-destroy-smoke',
    '"--scene"',
    '"raw-vulkan-physical-device-count-query-no-destroy-smoke"',
    '"--summary-path"',
]
for needle in required:
    if needle not in branch:
        raise SystemExit(f"missing raw-vulkan-physical-device-count-query-no-destroy-smoke branch needle: {needle}")
for needle in ['"--present-kms"', 'hold_seconds,']:
    if needle in branch:
        raise SystemExit(f"unexpected raw-vulkan-physical-device-count-query-no-destroy-smoke branch needle: {needle}")
PY
}

assert_orange_gpu_raw_vulkan_physical_device_count_query_exit_branch_shape() {
  python3 - "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "} else if (orange_gpu_mode_is_raw_vulkan_physical_device_count_query_exit_smoke(config)) {"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing raw-vulkan-physical-device-count-query-exit-smoke branch marker")
start += len(marker)
end = source.find("\n        } else if (orange_gpu_mode_is_raw_vulkan_physical_device_count_query_smoke(config)) {", start)
if end < 0:
    raise SystemExit("missing end of raw-vulkan-physical-device-count-query-exit-smoke branch")
branch = source[start:end]
required = [
    'scene=raw-vulkan-physical-device-count-query-exit-smoke mode=raw-vulkan-physical-device-count-query-exit-smoke',
    '"--scene"',
    '"raw-vulkan-physical-device-count-query-exit-smoke"',
    '"--summary-path"',
]
for needle in required:
    if needle not in branch:
        raise SystemExit(f"missing raw-vulkan-physical-device-count-query-exit-smoke branch needle: {needle}")
for needle in ['"--present-kms"', 'hold_seconds,']:
    if needle in branch:
        raise SystemExit(f"unexpected raw-vulkan-physical-device-count-query-exit-smoke branch needle: {needle}")
PY
}

assert_orange_gpu_raw_vulkan_physical_device_count_query_branch_shape() {
  python3 - "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "} else if (orange_gpu_mode_is_raw_vulkan_physical_device_count_query_smoke(config)) {"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing raw-vulkan-physical-device-count-query-smoke branch marker")
start += len(marker)
end = source.find("\n        } else if (orange_gpu_mode_is_vulkan_enumerate_adapters_count_smoke(config)) {", start)
if end < 0:
    raise SystemExit("missing end of raw-vulkan-physical-device-count-query-smoke branch")
branch = source[start:end]
required = [
    'scene=raw-vulkan-physical-device-count-query-smoke mode=raw-vulkan-physical-device-count-query-smoke',
    '"--scene"',
    '"raw-vulkan-physical-device-count-query-smoke"',
    '"--summary-path"',
]
for needle in required:
    if needle not in branch:
        raise SystemExit(f"missing raw-vulkan-physical-device-count-query-smoke branch needle: {needle}")
for needle in ['"--present-kms"', 'hold_seconds,']:
    if needle in branch:
        raise SystemExit(f"unexpected raw-vulkan-physical-device-count-query-smoke branch needle: {needle}")
PY
}

assert_orange_gpu_enumerate_adapters_count_branch_shape() {
  python3 - "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "} else if (orange_gpu_mode_is_vulkan_enumerate_adapters_count_smoke(config)) {"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing enumerate-adapters-count-smoke branch marker")
start += len(marker)
end = source.find("\n        } else if (orange_gpu_mode_is_vulkan_enumerate_adapters_smoke(config)) {", start)
if end < 0:
    raise SystemExit("missing end of enumerate-adapters-count-smoke branch")
branch = source[start:end]
required = [
    'scene=enumerate-adapters-count-smoke mode=vulkan-enumerate-adapters-count-smoke',
    '"--scene"',
    '"enumerate-adapters-count-smoke"',
    '"--summary-path"',
]
for needle in required:
    if needle not in branch:
        raise SystemExit(f"missing enumerate-adapters-count-smoke branch needle: {needle}")
for needle in ['"--present-kms"', 'hold_seconds,']:
    if needle in branch:
        raise SystemExit(f"unexpected enumerate-adapters-count-smoke branch needle: {needle}")
PY
}

assert_orange_gpu_enumerate_adapters_branch_shape() {
  python3 - "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "} else if (orange_gpu_mode_is_vulkan_enumerate_adapters_smoke(config)) {"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing enumerate-adapters-smoke branch marker")
start += len(marker)
end = source.find("\n        } else if (orange_gpu_mode_is_vulkan_adapter_smoke(config)) {", start)
if end < 0:
    raise SystemExit("missing end of enumerate-adapters-smoke branch")
branch = source[start:end]
required = [
    'scene=enumerate-adapters-smoke mode=vulkan-enumerate-adapters-smoke',
    '"--scene"',
    '"enumerate-adapters-smoke"',
    '"--summary-path"',
]
for needle in required:
    if needle not in branch:
        raise SystemExit(f"missing enumerate-adapters-smoke branch needle: {needle}")
for needle in ['"--present-kms"', 'hold_seconds,']:
    if needle in branch:
        raise SystemExit(f"unexpected enumerate-adapters-smoke branch needle: {needle}")
PY
}

assert_orange_gpu_adapter_branch_shape() {
  python3 - "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "} else if (orange_gpu_mode_is_vulkan_adapter_smoke(config)) {"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing adapter-smoke branch marker")
start += len(marker)
end = source.find("\n        } else if (orange_gpu_mode_is_vulkan_device_request_smoke(config)) {", start)
if end < 0:
    raise SystemExit("missing end of adapter-smoke branch")
branch = source[start:end]
required = [
    'scene=adapter-smoke mode=vulkan-adapter-smoke',
    '"--scene"',
    '"adapter-smoke"',
    '"--summary-path"',
]
for needle in required:
    if needle not in branch:
        raise SystemExit(f"missing adapter-smoke branch needle: {needle}")
for needle in ['"--present-kms"', 'hold_seconds,']:
    if needle in branch:
        raise SystemExit(f"unexpected adapter-smoke branch needle: {needle}")
PY
}

assert_orange_gpu_device_request_branch_shape() {
  python3 - "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "} else if (orange_gpu_mode_is_vulkan_device_request_smoke(config)) {"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing device-request-smoke branch marker")
start += len(marker)
end = source.find("\n        } else if (orange_gpu_mode_is_vulkan_device_smoke(config)) {", start)
if end < 0:
    raise SystemExit("missing end of device-request-smoke branch")
branch = source[start:end]
required = [
    'scene=device-request-smoke mode=vulkan-device-request-smoke',
    '"--scene"',
    '"device-request-smoke"',
    '"--summary-path"',
]
for needle in required:
    if needle not in branch:
        raise SystemExit(f"missing device-request-smoke branch needle: {needle}")
for needle in ['"--present-kms"', 'hold_seconds,']:
    if needle in branch:
        raise SystemExit(f"unexpected device-request-smoke branch needle: {needle}")
PY
}

assert_orange_gpu_device_branch_shape() {
  python3 - "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "} else if (orange_gpu_mode_is_vulkan_device_smoke(config)) {"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing device-smoke branch marker")
start += len(marker)
end = source.find("\n        } else {", start)
if end < 0:
    raise SystemExit("missing end of device-smoke branch")
branch = source[start:end]
required = [
    'scene=device-smoke mode=vulkan-device-smoke',
    '"--scene"',
    '"device-smoke"',
    '"--summary-path"',
]
for needle in required:
    if needle not in branch:
        raise SystemExit(f"missing device-smoke branch needle: {needle}")
for needle in ['"--present-kms"', 'hold_seconds,']:
    if needle in branch:
        raise SystemExit(f"unexpected device-smoke branch needle: {needle}")
PY
}

assert_orange_gpu_parent_probe_seam_shape() {
  python3 - "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")

def extract(signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise SystemExit(f"missing function signature: {signature}")
    brace = source.find("{", start)
    if brace < 0:
        raise SystemExit(f"missing function body for: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        ch = source[index]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise SystemExit(f"unterminated function body for: {signature}")

probe_body = extract("static int run_orange_gpu_parent_probe(")
for needle in [
    'SHADOW_HELLO_INIT_ORANGE_GPU_PROBE_OUTPUT_PATH',
    'SHADOW_HELLO_INIT_ORANGE_GPU_PROBE_SUMMARY_PATH',
    '"orange-gpu-parent-probe-start"',
    '"orange-gpu-parent-probe-child-exec"',
    '"orange-gpu-parent-probe-attempt-success"',
    '"orange-gpu-parent-probe-complete"',
    '"raw-vulkan-physical-device-count-query-exit-smoke"',
]:
    if needle not in probe_body:
        raise SystemExit(f"missing parent-probe seam needle: {needle}")

payload_body = extract("static int run_orange_gpu_payload(")
probe_call = 'probe_status = run_orange_gpu_parent_probe('
probe_ready_call = 'run_orange_gpu_checkpoint(config, "probe-ready", 1U);'
launch_stage = '"orange-gpu-launch"'
continue_stage = '"orange-gpu-parent-probe-continue"'

probe_idx = payload_body.find(probe_call)
if probe_idx < 0:
    raise SystemExit("missing parent-probe call in run_orange_gpu_payload")
if probe_ready_call not in payload_body:
    raise SystemExit("missing probe-ready checkpoint call in run_orange_gpu_payload")
launch_idx = payload_body.find(launch_stage)
if launch_idx < 0:
    raise SystemExit("missing real orange-gpu launch stage in run_orange_gpu_payload")
if probe_idx > launch_idx:
    raise SystemExit("parent probe call appears after the real orange-gpu launch stage")
if continue_stage not in payload_body:
    raise SystemExit("missing parent-probe continue breadcrumb in run_orange_gpu_payload")
PY
}

assert_hello_init_metadata_stage_seam_shape() {
  python3 - "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")

def extract(signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise SystemExit(f"missing function signature: {signature}")
    brace = source.find("{", start)
    if brace < 0:
        raise SystemExit(f"missing function body for: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        ch = source[index]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise SystemExit(f"unterminated function body for: {signature}")

uevent_body = extract("static bool read_metadata_block_identity_from_uevent(")
for needle in [
    'SHADOW_HELLO_INIT_METADATA_PARTNAME',
    '"PARTNAME="',
    '"MAJOR="',
    '"MINOR="',
]:
    if needle not in uevent_body:
        raise SystemExit(f"missing metadata uevent parser needle: {needle}")

sysfs_body = extract("static bool discover_metadata_block_identity_from_sysfs(")
for needle in [
    'SHADOW_HELLO_INIT_METADATA_SYSFS_BLOCK_ROOT',
    '"%s/%s/uevent"',
    'readdir(block_dir)',
]:
    if needle not in sysfs_body:
        raise SystemExit(f"missing metadata sysfs fallback needle: {needle}")

prepare_body = extract("static bool prepare_metadata_stage_runtime_best_effort(")
bootstrap_body = extract("static int bootstrap_tmpfs_metadata_block_runtime(")
for needle in [
    'SHADOW_HELLO_INIT_METADATA_DEVICE_PATH',
    '"ext4"',
    '"f2fs"',
    'SHADOW_HELLO_INIT_METADATA_ROOT',
    'SHADOW_HELLO_INIT_METADATA_BY_TOKEN_ROOT',
]:
    if needle not in prepare_body:
        raise SystemExit(f"missing metadata prepare seam needle: {needle}")
discover_idx = prepare_body.find('discover_metadata_block_identity_from_sysfs(config, runtime);')
bootstrap_idx = prepare_body.find('bootstrap_tmpfs_metadata_block_runtime(config, runtime)')
if min(discover_idx, bootstrap_idx) < 0:
    raise SystemExit("missing metadata fallback/bootstrap call in prepare path")
if discover_idx > bootstrap_idx:
    raise SystemExit("metadata sysfs fallback appears after tmpfs metadata bootstrap")
for needle in ['"/dev/block"', '"/dev/block/by-name"', 'ensure_block_device(']:
    if needle not in bootstrap_body:
        raise SystemExit(f"missing metadata bootstrap seam needle: {needle}")

write_body = extract("static bool write_metadata_stage_best_effort(")
for needle in [
    'write_atomic_text_file(',
    '"metadata-stage-write"',
    '"metadata-stage-write-failed"',
    'runtime->stage_path',
]:
    if needle not in write_body:
        raise SystemExit(f"missing metadata write seam needle: {needle}")

atomic_body = extract("static int write_atomic_buffer_file(")
for needle in ['rename(temp_path, final_path)', 'fsync(temp_fd)', 'fsync(final_fd)', 'fsync_directory_path(directory_path)']:
    if needle not in atomic_body:
        raise SystemExit(f"missing atomic metadata write needle: {needle}")

main_body = extract("int main(void)")
validated_idx = main_body.find('run_orange_gpu_checkpoint(\n            &config,\n            "validated"')
prepare_idx = main_body.find('prepare_metadata_stage_runtime_best_effort(&config, &metadata_stage)')
write_idx = main_body.find('write_metadata_stage_best_effort(&metadata_stage, "validated")')
payload_idx = main_body.find('payload_status = run_orange_gpu_payload(&config, &metadata_stage);')
if min(validated_idx, prepare_idx, write_idx, payload_idx) < 0:
    raise SystemExit("missing metadata-stage main flow markers")
if not (validated_idx < prepare_idx < write_idx < payload_idx):
    raise SystemExit("metadata-stage flow is not ordered validated -> prepare -> write -> payload")

payload_body = extract("static int run_orange_gpu_payload(")
start_idx = payload_body.find('"parent-probe-start"')
probe_idx = payload_body.find('sizeof(probe_result_stage)')
result_idx = payload_body.find('write_metadata_stage_best_effort(\n            metadata_stage,\n            probe_result_stage')
if min(start_idx, probe_idx, result_idx) < 0:
    raise SystemExit("missing metadata parent-probe markers")
if not (start_idx < probe_idx < result_idx):
    raise SystemExit("metadata parent-probe writes are not ordered start -> probe -> result")

init_runtime_body = extract("static void init_metadata_stage_runtime(")
for needle in [
    'runtime->probe_stage_path',
    'runtime->temp_probe_stage_path',
    'runtime->probe_fingerprint_path',
    'runtime->temp_probe_fingerprint_path',
    '"%s/probe-stage.txt"',
    '"%s/probe-fingerprint.txt"',
]:
    if needle not in init_runtime_body:
        raise SystemExit(f"missing metadata probe runtime seam needle: {needle}")

setenv_body = extract("static int set_orange_gpu_child_env(")
for needle in [
    'SHADOW_HELLO_INIT_GPU_SMOKE_STAGE_PATH_ENV',
    'SHADOW_HELLO_INIT_GPU_SMOKE_STAGE_PREFIX_ENV',
]:
    if needle not in setenv_body:
        raise SystemExit(f"missing metadata probe child env seam needle: {needle}")

parent_probe_body = extract("static int run_orange_gpu_parent_probe(")
for needle in ['metadata_stage->probe_stage_path', '"parent-probe-attempt-%u"']:
    if needle not in parent_probe_body:
        raise SystemExit(f"missing metadata probe child seam needle: {needle}")

fingerprint_body = extract("static bool write_metadata_probe_fingerprint_best_effort(")
for needle in [
    '"/dev/kgsl-3d0"',
    '"/dev/dri/card0"',
    '"/dev/dri/renderD128"',
    '"/dev/dma_heap/system"',
    '"/dev/ion"',
    '"/proc/mounts"',
    'SHADOW_HELLO_INIT_ORANGE_GPU_ICD_PATH',
    '"metadata-probe-fingerprint-write"',
]:
    if needle not in fingerprint_body:
        raise SystemExit(f"missing metadata probe fingerprint seam needle: {needle}")
PY
}

assert_app_direct_present_typescript_manifest_selector_shape() {
  python3 - "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
signature = "stage_app_direct_present_typescript_bundle()"
start = source.find(signature)
if start < 0:
    raise SystemExit("missing stage_app_direct_present_typescript_bundle")
brace = source.find("{", start)
if brace < 0:
    raise SystemExit("missing stage_app_direct_present_typescript_bundle body")
depth = 0
end = -1
for index in range(brace, len(source)):
    char = source[index]
    if char == "{":
        depth += 1
    elif char == "}":
        depth -= 1
        if depth == 0:
            end = index + 1
            break
if end < 0:
    raise SystemExit("unterminated stage_app_direct_present_typescript_bundle body")
body = source[start:end]
required = [
    "--profile pixel-shell",
    '--include-app "$APP_DIRECT_PRESENT_APP_ID"',
    '"PIXEL_SHELL_${runtime_app_env_prefix}_CACHE_DIR"',
    "python3 -c",
    'data["apps"][app_id]["effectiveBundlePath"]',
]
for needle in required:
    if needle not in body:
        raise SystemExit(f"missing TypeScript manifest selector needle: {needle}")
for needle in [
    "--profile single",
    "--app-id app",
    'python3 - "$APP_DIRECT_PRESENT_APP_ID" <<',
    'data["apps"]["app"]["effectiveBundlePath"]',
]:
    if needle in body:
        raise SystemExit(f"unexpected single-app TypeScript selector needle: {needle}")
PY
}

assert_runtime_build_artifacts_timeline_manifest_selector_cli() {
  local cache_root output_path
  cache_root="$TMP_DIR/runtime-pixel-shell-timeline"
  output_path="$TMP_DIR/runtime-build-artifacts-timeline.json"

  PIXEL_SHELL_TIMELINE_CACHE_DIR="$cache_root" \
    "$REPO_ROOT/scripts/runtime_build_artifacts.sh" \
      --profile pixel-shell \
      --include-app timeline >"$output_path"

  python3 - "$output_path" "$cache_root" <<'PY'
import json
import sys
from pathlib import Path

output_path = Path(sys.argv[1])
cache_root = Path(sys.argv[2]).resolve()
data = json.loads(output_path.read_text(encoding="utf-8"))
apps = data.get("apps")
if data.get("profile") != "pixel-shell":
    raise SystemExit("runtime selector did not use pixel-shell profile")
if not isinstance(apps, dict) or set(apps) != {"timeline"}:
    raise SystemExit(f"runtime selector did not select only timeline: {apps!r}")
timeline = apps["timeline"]
expected = {
    "id": "timeline",
    "inputPath": "runtime/app-nostr-timeline/app.tsx",
    "bundleEnv": "SHADOW_RUNTIME_APP_TIMELINE_BUNDLE_PATH",
    "bundleFilename": "runtime-app-timeline-bundle.js",
}
for key, value in expected.items():
    if timeline.get(key) != value:
        raise SystemExit(f"timeline selector field mismatch: {key}={timeline.get(key)!r}")
config = timeline.get("runtimeAppConfig")
if not isinstance(config, dict) or config.get("syncOnStart") is not True:
    raise SystemExit("timeline selector did not preserve runtimeAppConfig.syncOnStart")
bundle_path_value = timeline.get("effectiveBundlePath")
if not isinstance(bundle_path_value, str):
    raise SystemExit("timeline selector did not emit effectiveBundlePath")
bundle_path = Path(bundle_path_value).resolve()
if not bundle_path.exists():
    raise SystemExit(f"timeline selector bundle does not exist: {bundle_path}")
if not bundle_path.is_relative_to(cache_root):
    raise SystemExit(f"timeline selector ignored cache env: {bundle_path} not under {cache_root}")
PY
}

assert_hello_init_orange_gpu_mode_parser_smoke() {
  local smoke_c="$TMP_DIR/hello-init-orange-gpu-mode-smoke.c"
  local smoke_bin="$TMP_DIR/hello-init-orange-gpu-mode-smoke"

  python3 - "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" "$smoke_c" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
output_path = Path(sys.argv[2])

def extract(signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise SystemExit(f"missing function signature: {signature}")
    brace = source.find("{", start)
    if brace < 0:
        raise SystemExit(f"missing function body for: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        ch = source[index]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise SystemExit(f"unterminated function body for: {signature}")

functions = [
    extract("static bool copy_string("),
    extract("static char *trim_whitespace(char *value) {"),
    extract("static bool parse_orange_gpu_mode_value("),
]

program = """#include <ctype.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

{functions}

int main(void) {{
    char buffer[64];

    if (!parse_orange_gpu_mode_value("vulkan-instance-smoke", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid instance-smoke mode\\n");
        return 1;
    }}
    if (strcmp(buffer, "vulkan-instance-smoke") != 0) {{
        fprintf(stderr, "unexpected parsed instance-smoke mode: %s\\n", buffer);
        return 2;
    }}
    if (!parse_orange_gpu_mode_value("raw-vulkan-instance-smoke", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid raw-vulkan-instance-smoke mode\\n");
        return 3;
    }}
    if (strcmp(buffer, "raw-vulkan-instance-smoke") != 0) {{
        fprintf(stderr, "unexpected parsed raw-vulkan-instance-smoke mode: %s\\n", buffer);
        return 4;
    }}
    if (!parse_orange_gpu_mode_value("firmware-probe-only", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid firmware-probe-only mode\\n");
        return 5;
    }}
    if (strcmp(buffer, "firmware-probe-only") != 0) {{
        fprintf(stderr, "unexpected parsed firmware-probe-only mode: %s\\n", buffer);
        return 6;
    }}
    if (!parse_orange_gpu_mode_value("raw-vulkan-physical-device-count-query-exit-smoke", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid raw-vulkan-physical-device-count-query-exit-smoke mode\\n");
        return 7;
    }}
    if (strcmp(buffer, "raw-vulkan-physical-device-count-query-exit-smoke") != 0) {{
        fprintf(stderr, "unexpected parsed raw-vulkan-physical-device-count-query-exit-smoke mode: %s\\n", buffer);
        return 8;
    }}
    if (!parse_orange_gpu_mode_value("raw-vulkan-physical-device-count-query-no-destroy-smoke", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid raw-vulkan-physical-device-count-query-no-destroy-smoke mode\\n");
        return 9;
    }}
    if (strcmp(buffer, "raw-vulkan-physical-device-count-query-no-destroy-smoke") != 0) {{
        fprintf(stderr, "unexpected parsed raw-vulkan-physical-device-count-query-no-destroy-smoke mode: %s\\n", buffer);
        return 10;
    }}
    if (!parse_orange_gpu_mode_value("raw-vulkan-physical-device-count-query-smoke", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid raw-vulkan-physical-device-count-query-smoke mode\\n");
        return 11;
    }}
    if (strcmp(buffer, "raw-vulkan-physical-device-count-query-smoke") != 0) {{
        fprintf(stderr, "unexpected parsed raw-vulkan-physical-device-count-query-smoke mode: %s\\n", buffer);
        return 12;
    }}
    if (!parse_orange_gpu_mode_value("raw-vulkan-physical-device-count-smoke", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid raw-vulkan-physical-device-count-smoke mode\\n");
        return 13;
    }}
    if (strcmp(buffer, "raw-vulkan-physical-device-count-smoke") != 0) {{
        fprintf(stderr, "unexpected parsed raw-vulkan-physical-device-count-smoke mode: %s\\n", buffer);
        return 14;
    }}
    if (!parse_orange_gpu_mode_value("vulkan-enumerate-adapters-count-smoke", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid enumerate-adapters-count-smoke mode\\n");
        return 15;
    }}
    if (strcmp(buffer, "vulkan-enumerate-adapters-count-smoke") != 0) {{
        fprintf(stderr, "unexpected parsed enumerate-adapters-count-smoke mode: %s\\n", buffer);
        return 16;
    }}
    if (!parse_orange_gpu_mode_value("vulkan-enumerate-adapters-smoke", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid enumerate-adapters-smoke mode\\n");
        return 17;
    }}
    if (strcmp(buffer, "vulkan-enumerate-adapters-smoke") != 0) {{
        fprintf(stderr, "unexpected parsed enumerate-adapters-smoke mode: %s\\n", buffer);
        return 18;
    }}
    if (!parse_orange_gpu_mode_value("vulkan-adapter-smoke", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid adapter-smoke mode\\n");
        return 19;
    }}
    if (strcmp(buffer, "vulkan-adapter-smoke") != 0) {{
        fprintf(stderr, "unexpected parsed adapter-smoke mode: %s\\n", buffer);
        return 20;
    }}
    if (!parse_orange_gpu_mode_value("vulkan-device-request-smoke", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid device-request-smoke mode\\n");
        return 21;
    }}
    if (strcmp(buffer, "vulkan-device-request-smoke") != 0) {{
        fprintf(stderr, "unexpected parsed device-request-smoke mode: %s\\n", buffer);
        return 22;
    }}
    if (!parse_orange_gpu_mode_value("vulkan-device-smoke", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid device-smoke mode\\n");
        return 23;
    }}
    if (strcmp(buffer, "vulkan-device-smoke") != 0) {{
        fprintf(stderr, "unexpected parsed device-smoke mode: %s\\n", buffer);
        return 24;
    }}
    if (!parse_orange_gpu_mode_value(" vulkan-offscreen ", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse trimmed offscreen mode\\n");
        return 25;
    }}
    if (strcmp(buffer, "vulkan-offscreen") != 0) {{
        fprintf(stderr, "unexpected parsed offscreen mode: %s\\n", buffer);
        return 26;
    }}
    if (parse_orange_gpu_mode_value("nope", buffer, sizeof(buffer))) {{
        fprintf(stderr, "unexpectedly accepted invalid mode\\n");
        return 27;
    }}

    return 0;
}}
""".format(functions="\n\n".join(functions))

output_path.write_text(program, encoding="utf-8")
PY

  cc -std=c99 -Wall -Wextra -Werror "$smoke_c" -o "$smoke_bin"
  "$smoke_bin"
}

assert_shadow_gpu_adapter_helper_shape() {
  python3 - "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "fn select_adapter_info(config: &Config) -> Result<AdapterInfo, String> {"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing select_adapter_info helper")
start += len(marker)
end = source.find("\n}\n\nfn request_device_handle(", start)
if end < 0:
    raise SystemExit("missing end of select_adapter_info helper")
body = source[start:end]
required = [
    "context.create_headless_adapter_info()",
    "validate_adapter(config, &adapter_info)?;",
]
for needle in required:
    if needle not in body:
        raise SystemExit(f"missing select_adapter_info helper needle: {needle}")
PY
}

assert_shadow_gpu_request_device_helper_shape() {
  python3 - "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "fn request_device_handle(config: &Config) -> Result<RequestedDevice, String> {"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing request_device_handle helper")
start += len(marker)
end = source.find("\n}\n\nfn validate_adapter(", start)
if end < 0:
    raise SystemExit("missing end of request_device_handle helper")
body = source[start:end]
required = [
    "context.create_headless_device_handle()",
    "validate_adapter(config, &adapter_info)?;",
]
for needle in required:
    if needle not in body:
        raise SystemExit(f"missing request_device_handle helper needle: {needle}")
PY
}

assert_shadow_gpu_instance_helper_shape() {
  python3 - "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "fn build_instance_smoke_summary(config: &Config) -> InstanceSmokeSummary {"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing build_instance_smoke_summary helper")
start += len(marker)
end = source.find("\n}\n\nfn build_raw_vulkan_instance_smoke_summary(", start)
if end < 0:
    raise SystemExit("missing end of build_instance_smoke_summary helper")
body = source[start:end]
required = [
    "WGPUContext::new()",
    'mode: "instance-smoke"',
    "device_pool_len: context.device_pool.len()",
]
for needle in required:
    if needle not in body:
        raise SystemExit(f"missing build_instance_smoke_summary helper needle: {needle}")
for needle in ["create_headless_adapter_info()", "create_headless_device_handle()"]:
    if needle in body:
        raise SystemExit(f"unexpected build_instance_smoke_summary helper needle: {needle}")
PY
}

assert_shadow_gpu_raw_vulkan_instance_helper_shape() {
  python3 - "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "fn build_raw_vulkan_instance_smoke_summary("
start = source.find(marker)
if start < 0:
    raise SystemExit("missing build_raw_vulkan_instance_smoke_summary helper")
start += len(marker)
end = source.find("\n}\n\nfn build_raw_vulkan_physical_device_count_smoke_summary(", start)
if end < 0:
    raise SystemExit("missing end of build_raw_vulkan_instance_smoke_summary helper")
body = source[start:end]
required = [
    'mode: "raw-vulkan-instance-smoke"',
    "ash::Entry::load()",
    "entry.create_instance(&create_info, None)",
    "instance.destroy_instance(None);",
    "wgpu_adapter_enumeration_attempted: false",
]
for needle in required:
    if needle not in body:
        raise SystemExit(f"missing build_raw_vulkan_instance_smoke_summary helper needle: {needle}")
for needle in ["WGPUContext::new()", "enumerate_physical_devices()", "enumerate_adapters(", ".get_info()", "AdapterSummary::from_info"]:
    if needle in body:
        raise SystemExit(f"unexpected build_raw_vulkan_instance_smoke_summary helper needle: {needle}")
PY
}

assert_shadow_gpu_raw_vulkan_physical_device_count_helper_shape() {
  python3 - "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "fn build_raw_vulkan_physical_device_count_smoke_summary("
start = source.find(marker)
if start < 0:
    raise SystemExit("missing build_raw_vulkan_physical_device_count_smoke_summary helper")
start += len(marker)
end = source.find("\n}\n\nfn build_raw_vulkan_physical_device_count_query_no_destroy_smoke_summary(", start)
if end < 0:
    raise SystemExit("missing end of build_raw_vulkan_physical_device_count_smoke_summary helper")
body = source[start:end]
required = [
    'mode: "raw-vulkan-physical-device-count-smoke"',
    "ash::Entry::load()",
    "entry.create_instance(&create_info, None)",
    "instance.enumerate_physical_devices()",
    "enumerated_physical_device_count: physical_devices.len()",
    "physical_device_properties_read: false",
    "instance.destroy_instance(None);",
]
for needle in required:
    if needle not in body:
        raise SystemExit(f"missing build_raw_vulkan_physical_device_count_smoke_summary helper needle: {needle}")
for needle in ["WGPUContext::new()", "enumerate_adapters(", ".get_info()", "AdapterSummary::from_info", "get_physical_device_properties"]:
    if needle in body:
        raise SystemExit(f"unexpected build_raw_vulkan_physical_device_count_smoke_summary helper needle: {needle}")
PY
}

assert_shadow_gpu_raw_vulkan_physical_device_count_query_no_destroy_helper_shape() {
  python3 - "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "fn build_raw_vulkan_physical_device_count_query_no_destroy_smoke_summary("
start = source.find(marker)
if start < 0:
    raise SystemExit("missing build_raw_vulkan_physical_device_count_query_no_destroy_smoke_summary helper")
start += len(marker)
end = source.find("\n}\n\nfn build_raw_vulkan_physical_device_count_query_smoke_summary(", start)
if end < 0:
    raise SystemExit("missing end of build_raw_vulkan_physical_device_count_query_no_destroy_smoke_summary helper")
body = source[start:end]
required = [
    'mode: "raw-vulkan-physical-device-count-query-no-destroy-smoke"',
    "ash::Entry::load()",
    "entry.create_instance(&create_info, None)",
    "instance.fp_v1_0().enumerate_physical_devices",
    "std::ptr::null_mut::<vk::PhysicalDevice>()",
    "instance_destroyed: false",
    "explicit_instance_destroy_attempted: false",
    "physical_device_count_queried: true",
    "physical_device_handles_fetched: false",
    "physical_device_properties_read: false",
]
for needle in required:
    if needle not in body:
        raise SystemExit(f"missing build_raw_vulkan_physical_device_count_query_no_destroy_smoke_summary helper needle: {needle}")
for needle in ["WGPUContext::new()", "instance.enumerate_physical_devices()", "enumerate_adapters(", ".get_info()", "AdapterSummary::from_info", "get_physical_device_properties", "instance.destroy_instance(None);"]:
    if needle in body:
        raise SystemExit(f"unexpected build_raw_vulkan_physical_device_count_query_no_destroy_smoke_summary helper needle: {needle}")
PY
}

assert_shadow_gpu_raw_vulkan_physical_device_count_query_exit_helper_shape() {
  python3 - "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "fn run_raw_vulkan_physical_device_count_query_exit_smoke()"
start = source.find(marker)
if start < 0:
    raise SystemExit("missing run_raw_vulkan_physical_device_count_query_exit_smoke helper")
start += len(marker)
end = source.find("\n}\n\nfn build_summary(", start)
if end < 0:
    raise SystemExit("missing end of run_raw_vulkan_physical_device_count_query_exit_smoke helper")
body = source[start:end]
required = [
    "ash::Entry::load()",
    "entry.create_instance(&create_info, None)",
    "instance.fp_v1_0().enumerate_physical_devices",
    "std::ptr::null_mut::<vk::PhysicalDevice>()",
    "raw-vulkan-physical-device-count-query-exit-smoke: exit-status=0-before-summary",
    "libc::_exit(0)",
]
for needle in required:
    if needle not in body:
        raise SystemExit(f"missing run_raw_vulkan_physical_device_count_query_exit_smoke helper needle: {needle}")
for needle in ["WGPUContext::new()", "instance.enumerate_physical_devices()", "enumerate_adapters(", ".get_info()", "AdapterSummary::from_info", "get_physical_device_properties", "instance.destroy_instance(None);", "serde_json::to_string_pretty"]:
    if needle in body:
        raise SystemExit(f"unexpected run_raw_vulkan_physical_device_count_query_exit_smoke helper needle: {needle}")
PY
}

assert_shadow_gpu_raw_vulkan_physical_device_count_query_helper_shape() {
  python3 - "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "fn build_raw_vulkan_physical_device_count_query_smoke_summary("
start = source.find(marker)
if start < 0:
    raise SystemExit("missing build_raw_vulkan_physical_device_count_query_smoke_summary helper")
start += len(marker)
end = source.find("\n}\n\nfn build_enumerate_adapters_count_smoke_summary(", start)
if end < 0:
    raise SystemExit("missing end of build_raw_vulkan_physical_device_count_query_smoke_summary helper")
body = source[start:end]
required = [
    'mode: "raw-vulkan-physical-device-count-query-smoke"',
    "ash::Entry::load()",
    "entry.create_instance(&create_info, None)",
    "instance.fp_v1_0().enumerate_physical_devices",
    "std::ptr::null_mut::<vk::PhysicalDevice>()",
    "instance_destroyed: true",
    "explicit_instance_destroy_attempted: true",
    "physical_device_count_queried: true",
    "physical_device_handles_fetched: false",
    "physical_device_properties_read: false",
    "instance.destroy_instance(None);",
]
for needle in required:
    if needle not in body:
        raise SystemExit(f"missing build_raw_vulkan_physical_device_count_query_smoke_summary helper needle: {needle}")
for needle in ["WGPUContext::new()", "instance.enumerate_physical_devices()", "enumerate_adapters(", ".get_info()", "AdapterSummary::from_info", "get_physical_device_properties"]:
    if needle in body:
        raise SystemExit(f"unexpected build_raw_vulkan_physical_device_count_query_smoke_summary helper needle: {needle}")
PY
}

assert_shadow_gpu_enumerate_adapters_count_helper_shape() {
  python3 - "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "fn build_enumerate_adapters_count_smoke_summary("
start = source.find(marker)
if start < 0:
    raise SystemExit("missing build_enumerate_adapters_count_smoke_summary helper")
start += len(marker)
end = source.find("\n}\n\nfn build_enumerate_adapters_smoke_summary(", start)
if end < 0:
    raise SystemExit("missing end of build_enumerate_adapters_count_smoke_summary helper")
body = source[start:end]
required = [
    'mode: "enumerate-adapters-count-smoke"',
    "context.instance.enumerate_adapters(backends)",
    "enumerated_adapter_count: adapters.len()",
    "adapter_info_extracted: false",
    "adapter_selection_attempted: false",
]
for needle in required:
    if needle not in body:
        raise SystemExit(f"missing build_enumerate_adapters_count_smoke_summary helper needle: {needle}")
for needle in ["create_headless_adapter_info()", "create_headless_device_handle()", ".get_info()", "AdapterSummary::from_info"]:
    if needle in body:
        raise SystemExit(f"unexpected build_enumerate_adapters_count_smoke_summary helper needle: {needle}")
PY
}

assert_shadow_gpu_enumerate_adapters_helper_shape() {
  python3 - "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
marker = "fn build_enumerate_adapters_smoke_summary("
start = source.find(marker)
if start < 0:
    raise SystemExit("missing build_enumerate_adapters_smoke_summary helper")
start += len(marker)
end = source.find("\n}\n\nfn build_adapter_smoke_summary(", start)
if end < 0:
    raise SystemExit("missing end of build_enumerate_adapters_smoke_summary helper")
body = source[start:end]
required = [
    'mode: "enumerate-adapters-smoke"',
    "context.instance.enumerate_adapters(backends)",
    "AdapterSummary::from_info(&adapter.get_info())",
    "enumerated_adapter_count: adapters.len()",
    "adapter_info_extracted: true",
    "adapter_selection_attempted: false",
]
for needle in required:
    if needle not in body:
        raise SystemExit(f"missing build_enumerate_adapters_smoke_summary helper needle: {needle}")
for needle in ["create_headless_adapter_info()", "create_headless_device_handle()"]:
    if needle in body:
        raise SystemExit(f"unexpected build_enumerate_adapters_smoke_summary helper needle: {needle}")
PY
}

assert_shadow_gpu_instance_smoke_cli() {
  local summary_path="$TMP_DIR/instance-smoke-summary.json"
  local output

  output="$(
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene instance-smoke \
      --summary-path "$summary_path"
  )"

  assert_contains "$output" '"mode": "instance-smoke"'
  assert_contains "$output" '"scene": "instance-smoke"'
  assert_json_field_equals "$summary_path" mode "instance-smoke"
  assert_json_field_equals "$summary_path" scene "instance-smoke"
  assert_json_field_equals "$summary_path" instance_created "true"
  assert_json_field_equals "$summary_path" adapter_selected "false"
}

assert_shadow_gpu_raw_vulkan_instance_smoke_cli() {
  local summary_path="$TMP_DIR/raw-vulkan-instance-smoke-summary.json"
  local output

  if output="$(
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-instance-smoke \
      --summary-path "$summary_path" 2>&1
  )"; then
    assert_contains "$output" '"mode": "raw-vulkan-instance-smoke"'
    assert_contains "$output" '"scene": "raw-vulkan-instance-smoke"'
    assert_json_field_equals "$summary_path" mode "raw-vulkan-instance-smoke"
    assert_json_field_equals "$summary_path" scene "raw-vulkan-instance-smoke"
    python3 - "$summary_path" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("vulkan_loader_loaded") is not True:
    raise SystemExit("expected vulkan_loader_loaded=true")
if payload.get("instance_created") is not True:
    raise SystemExit("expected instance_created=true")
if payload.get("instance_destroyed") is not True:
    raise SystemExit("expected instance_destroyed=true")
if payload.get("physical_devices_enumerated") is not False:
    raise SystemExit("expected physical_devices_enumerated=false")
if payload.get("wgpu_adapter_enumeration_attempted") is not False:
    raise SystemExit("expected wgpu_adapter_enumeration_attempted=false")
if payload.get("adapter_selection_attempted") is not False:
    raise SystemExit("expected adapter_selection_attempted=false")
PY
    return
  fi

  assert_contains "$output" "shadow-gpu-smoke: load vulkan entry:"
  if [[ -e "$summary_path" ]]; then
    echo "raw-vulkan-instance-smoke unexpectedly wrote a summary on loader failure" >&2
    exit 1
  fi
  printf 'raw-vulkan-instance-smoke cli: explicit host skip because no Vulkan loader is present\n'
}

assert_shadow_gpu_raw_vulkan_physical_device_count_smoke_cli() {
  local summary_path="$TMP_DIR/raw-vulkan-physical-device-count-smoke-summary.json"
  local output

  if output="$(
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-physical-device-count-smoke \
      --summary-path "$summary_path" 2>&1
  )"; then
    assert_contains "$output" '"mode": "raw-vulkan-physical-device-count-smoke"'
    assert_contains "$output" '"scene": "raw-vulkan-physical-device-count-smoke"'
    assert_json_field_equals "$summary_path" mode "raw-vulkan-physical-device-count-smoke"
    assert_json_field_equals "$summary_path" scene "raw-vulkan-physical-device-count-smoke"
    python3 - "$summary_path" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("vulkan_loader_loaded") is not True:
    raise SystemExit("expected vulkan_loader_loaded=true")
if payload.get("instance_created") is not True:
    raise SystemExit("expected instance_created=true")
if payload.get("instance_destroyed") is not True:
    raise SystemExit("expected instance_destroyed=true")
if payload.get("physical_devices_enumerated") is not True:
    raise SystemExit("expected physical_devices_enumerated=true")
count = payload.get("enumerated_physical_device_count")
if not isinstance(count, int):
    raise SystemExit("expected integer enumerated_physical_device_count")
if payload.get("physical_device_properties_read") is not False:
    raise SystemExit("expected physical_device_properties_read=false")
if payload.get("wgpu_adapter_enumeration_attempted") is not False:
    raise SystemExit("expected wgpu_adapter_enumeration_attempted=false")
if payload.get("adapter_selection_attempted") is not False:
    raise SystemExit("expected adapter_selection_attempted=false")
PY
    return
  fi

  assert_contains "$output" "shadow-gpu-smoke: load vulkan entry:"
  if [[ -e "$summary_path" ]]; then
    echo "raw-vulkan-physical-device-count-smoke unexpectedly wrote a summary on loader failure" >&2
    exit 1
  fi
  printf 'raw-vulkan-physical-device-count-smoke cli: explicit host skip because no Vulkan loader is present\n'
}

assert_shadow_gpu_raw_vulkan_physical_device_count_query_no_destroy_smoke_cli() {
  local summary_path="$TMP_DIR/raw-vulkan-physical-device-count-query-no-destroy-smoke-summary.json"
  local output

  if output="$(
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-physical-device-count-query-no-destroy-smoke \
      --summary-path "$summary_path" 2>&1
  )"; then
    assert_contains "$output" '"mode": "raw-vulkan-physical-device-count-query-no-destroy-smoke"'
    assert_contains "$output" '"scene": "raw-vulkan-physical-device-count-query-no-destroy-smoke"'
    assert_json_field_equals "$summary_path" mode "raw-vulkan-physical-device-count-query-no-destroy-smoke"
    assert_json_field_equals "$summary_path" scene "raw-vulkan-physical-device-count-query-no-destroy-smoke"
    python3 - "$summary_path" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("vulkan_loader_loaded") is not True:
    raise SystemExit("expected vulkan_loader_loaded=true")
if payload.get("instance_created") is not True:
    raise SystemExit("expected instance_created=true")
if payload.get("instance_destroyed") is not False:
    raise SystemExit("expected instance_destroyed=false")
if payload.get("explicit_instance_destroy_attempted") is not False:
    raise SystemExit("expected explicit_instance_destroy_attempted=false")
if payload.get("physical_device_count_queried") is not True:
    raise SystemExit("expected physical_device_count_queried=true")
count = payload.get("queried_physical_device_count")
if not isinstance(count, int):
    raise SystemExit("expected integer queried_physical_device_count")
if payload.get("physical_device_handles_fetched") is not False:
    raise SystemExit("expected physical_device_handles_fetched=false")
if payload.get("physical_device_properties_read") is not False:
    raise SystemExit("expected physical_device_properties_read=false")
if payload.get("wgpu_adapter_enumeration_attempted") is not False:
    raise SystemExit("expected wgpu_adapter_enumeration_attempted=false")
if payload.get("adapter_selection_attempted") is not False:
    raise SystemExit("expected adapter_selection_attempted=false")
PY
    return
  fi

  assert_contains "$output" "shadow-gpu-smoke: load vulkan entry:"
  if [[ -e "$summary_path" ]]; then
    echo "raw-vulkan-physical-device-count-query-no-destroy-smoke unexpectedly wrote a summary on loader failure" >&2
    exit 1
  fi
  printf 'raw-vulkan-physical-device-count-query-no-destroy-smoke cli: explicit host skip because no Vulkan loader is present\n'
}

assert_shadow_gpu_raw_vulkan_physical_device_count_query_exit_smoke_cli() {
  local summary_path="$TMP_DIR/raw-vulkan-physical-device-count-query-exit-smoke-summary.json"
  local output

  if output="$(
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-physical-device-count-query-exit-smoke \
      --summary-path "$summary_path" 2>&1
  )"; then
    assert_contains "$output" "raw-vulkan-physical-device-count-query-exit-smoke: exit-status=0-before-summary"
    if [[ -e "$summary_path" ]]; then
      echo "raw-vulkan-physical-device-count-query-exit-smoke unexpectedly wrote a summary on successful exit" >&2
      exit 1
    fi
    return
  fi

  assert_contains "$output" "shadow-gpu-smoke: load vulkan entry:"
  if [[ -e "$summary_path" ]]; then
    echo "raw-vulkan-physical-device-count-query-exit-smoke unexpectedly wrote a summary on loader failure" >&2
    exit 1
  fi
  printf 'raw-vulkan-physical-device-count-query-exit-smoke cli: explicit host skip because no Vulkan loader is present\n'
}

assert_shadow_gpu_raw_vulkan_physical_device_count_query_smoke_cli() {
  local summary_path="$TMP_DIR/raw-vulkan-physical-device-count-query-smoke-summary.json"
  local output

  if output="$(
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-physical-device-count-query-smoke \
      --summary-path "$summary_path" 2>&1
  )"; then
    assert_contains "$output" '"mode": "raw-vulkan-physical-device-count-query-smoke"'
    assert_contains "$output" '"scene": "raw-vulkan-physical-device-count-query-smoke"'
    assert_json_field_equals "$summary_path" mode "raw-vulkan-physical-device-count-query-smoke"
    assert_json_field_equals "$summary_path" scene "raw-vulkan-physical-device-count-query-smoke"
    python3 - "$summary_path" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("vulkan_loader_loaded") is not True:
    raise SystemExit("expected vulkan_loader_loaded=true")
if payload.get("instance_created") is not True:
    raise SystemExit("expected instance_created=true")
if payload.get("instance_destroyed") is not True:
    raise SystemExit("expected instance_destroyed=true")
if payload.get("explicit_instance_destroy_attempted") is not True:
    raise SystemExit("expected explicit_instance_destroy_attempted=true")
if payload.get("physical_device_count_queried") is not True:
    raise SystemExit("expected physical_device_count_queried=true")
count = payload.get("queried_physical_device_count")
if not isinstance(count, int):
    raise SystemExit("expected integer queried_physical_device_count")
if payload.get("physical_device_handles_fetched") is not False:
    raise SystemExit("expected physical_device_handles_fetched=false")
if payload.get("physical_device_properties_read") is not False:
    raise SystemExit("expected physical_device_properties_read=false")
if payload.get("wgpu_adapter_enumeration_attempted") is not False:
    raise SystemExit("expected wgpu_adapter_enumeration_attempted=false")
if payload.get("adapter_selection_attempted") is not False:
    raise SystemExit("expected adapter_selection_attempted=false")
PY
    return
  fi

  assert_contains "$output" "shadow-gpu-smoke: load vulkan entry:"
  if [[ -e "$summary_path" ]]; then
    echo "raw-vulkan-physical-device-count-query-smoke unexpectedly wrote a summary on loader failure" >&2
    exit 1
  fi
  printf 'raw-vulkan-physical-device-count-query-smoke cli: explicit host skip because no Vulkan loader is present\n'
}

assert_shadow_gpu_enumerate_adapters_count_smoke_cli() {
  local summary_path="$TMP_DIR/enumerate-adapters-count-smoke-summary.json"
  local output

  output="$(
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene enumerate-adapters-count-smoke \
      --summary-path "$summary_path"
  )"

  assert_contains "$output" '"mode": "enumerate-adapters-count-smoke"'
  assert_contains "$output" '"scene": "enumerate-adapters-count-smoke"'
  assert_json_field_equals "$summary_path" mode "enumerate-adapters-count-smoke"
  assert_json_field_equals "$summary_path" scene "enumerate-adapters-count-smoke"
  python3 - "$summary_path" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("instance_created") is not True:
    raise SystemExit("expected instance_created=true")
if payload.get("adapters_enumerated") is not True:
    raise SystemExit("expected adapters_enumerated=true")
if payload.get("adapter_info_extracted") is not False:
    raise SystemExit("expected adapter_info_extracted=false")
if payload.get("adapter_selection_attempted") is not False:
    raise SystemExit("expected adapter_selection_attempted=false")
if payload.get("adapter_selected") is not False:
    raise SystemExit("expected adapter_selected=false")
count = payload.get("enumerated_adapter_count")
if not isinstance(count, int):
    raise SystemExit("expected integer enumerated_adapter_count")
if "adapters" in payload:
    raise SystemExit("did not expect adapters list in raw count smoke summary")
PY
}

assert_shadow_gpu_enumerate_adapters_smoke_cli() {
  local summary_path="$TMP_DIR/enumerate-adapters-smoke-summary.json"
  local output

  output="$(
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene enumerate-adapters-smoke \
      --summary-path "$summary_path"
  )"

  assert_contains "$output" '"mode": "enumerate-adapters-smoke"'
  assert_contains "$output" '"scene": "enumerate-adapters-smoke"'
  assert_json_field_equals "$summary_path" mode "enumerate-adapters-smoke"
  assert_json_field_equals "$summary_path" scene "enumerate-adapters-smoke"
  python3 - "$summary_path" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if payload.get("instance_created") is not True:
    raise SystemExit("expected instance_created=true")
if payload.get("adapters_enumerated") is not True:
    raise SystemExit("expected adapters_enumerated=true")
if payload.get("adapter_info_extracted") is not True:
    raise SystemExit("expected adapter_info_extracted=true")
if payload.get("adapter_selection_attempted") is not False:
    raise SystemExit("expected adapter_selection_attempted=false")
if payload.get("adapter_selected") is not False:
    raise SystemExit("expected adapter_selected=false")
count = payload.get("enumerated_adapter_count")
adapters = payload.get("adapters")
if not isinstance(count, int):
    raise SystemExit("expected integer enumerated_adapter_count")
if not isinstance(adapters, list):
    raise SystemExit("expected adapters list")
if count != len(adapters):
    raise SystemExit(
        f"expected enumerated_adapter_count ({count}) to equal len(adapters) ({len(adapters)})"
    )
PY
}

assert_shadow_gpu_instance_smoke_rejects_hold_secs() {
  assert_command_fails_contains "--scene instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --hold-secs" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene instance-smoke \
      --hold-secs 1
}

assert_shadow_gpu_raw_vulkan_instance_smoke_rejects_hold_secs() {
  assert_command_fails_contains "--scene instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --hold-secs" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-instance-smoke \
      --hold-secs 1
}

assert_shadow_gpu_raw_vulkan_physical_device_count_query_exit_smoke_rejects_hold_secs() {
  assert_command_fails_contains "--scene instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --hold-secs" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-physical-device-count-query-exit-smoke \
      --hold-secs 1
}

assert_shadow_gpu_raw_vulkan_physical_device_count_query_no_destroy_smoke_rejects_hold_secs() {
  assert_command_fails_contains "--scene instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --hold-secs" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-physical-device-count-query-no-destroy-smoke \
      --hold-secs 1
}

assert_shadow_gpu_raw_vulkan_physical_device_count_query_smoke_rejects_hold_secs() {
  assert_command_fails_contains "--scene instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --hold-secs" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-physical-device-count-query-smoke \
      --hold-secs 1
}

assert_shadow_gpu_raw_vulkan_physical_device_count_smoke_rejects_hold_secs() {
  assert_command_fails_contains "--scene instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --hold-secs" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-physical-device-count-smoke \
      --hold-secs 1
}

assert_shadow_gpu_enumerate_adapters_count_smoke_rejects_hold_secs() {
  assert_command_fails_contains "--scene instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --hold-secs" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene enumerate-adapters-count-smoke \
      --hold-secs 1
}

assert_shadow_gpu_enumerate_adapters_smoke_rejects_hold_secs() {
  assert_command_fails_contains "--scene instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --hold-secs" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene enumerate-adapters-smoke \
      --hold-secs 1
}

assert_shadow_gpu_instance_smoke_rejects_present_kms() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --present-kms" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene instance-smoke \
      --present-kms
}

assert_shadow_gpu_raw_vulkan_instance_smoke_rejects_present_kms() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --present-kms" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-instance-smoke \
      --present-kms
}

assert_shadow_gpu_raw_vulkan_physical_device_count_query_exit_smoke_rejects_present_kms() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --present-kms" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-physical-device-count-query-exit-smoke \
      --present-kms
}

assert_shadow_gpu_raw_vulkan_physical_device_count_query_no_destroy_smoke_rejects_present_kms() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --present-kms" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-physical-device-count-query-no-destroy-smoke \
      --present-kms
}

assert_shadow_gpu_raw_vulkan_physical_device_count_query_smoke_rejects_present_kms() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --present-kms" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-physical-device-count-query-smoke \
      --present-kms
}

assert_shadow_gpu_raw_vulkan_physical_device_count_smoke_rejects_present_kms() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --present-kms" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-physical-device-count-smoke \
      --present-kms
}

assert_shadow_gpu_enumerate_adapters_count_smoke_rejects_present_kms() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --present-kms" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene enumerate-adapters-count-smoke \
      --present-kms
}

assert_shadow_gpu_enumerate_adapters_smoke_rejects_present_kms() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --present-kms" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene enumerate-adapters-smoke \
      --present-kms
}

assert_shadow_gpu_instance_smoke_rejects_ppm_path() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --ppm-path" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene instance-smoke \
      --ppm-path "$TMP_DIR/instance-smoke.ppm"
}

assert_shadow_gpu_raw_vulkan_instance_smoke_rejects_ppm_path() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --ppm-path" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-instance-smoke \
      --ppm-path "$TMP_DIR/raw-vulkan-instance-smoke.ppm"
}

assert_shadow_gpu_raw_vulkan_physical_device_count_query_exit_smoke_rejects_ppm_path() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --ppm-path" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-physical-device-count-query-exit-smoke \
      --ppm-path "$TMP_DIR/raw-vulkan-physical-device-count-query-exit-smoke.ppm"
}

assert_shadow_gpu_raw_vulkan_physical_device_count_query_no_destroy_smoke_rejects_ppm_path() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --ppm-path" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-physical-device-count-query-no-destroy-smoke \
      --ppm-path "$TMP_DIR/raw-vulkan-physical-device-count-query-no-destroy-smoke.ppm"
}

assert_shadow_gpu_raw_vulkan_physical_device_count_query_smoke_rejects_ppm_path() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --ppm-path" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-physical-device-count-query-smoke \
      --ppm-path "$TMP_DIR/raw-vulkan-physical-device-count-query-smoke.ppm"
}

assert_shadow_gpu_raw_vulkan_physical_device_count_smoke_rejects_ppm_path() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --ppm-path" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene raw-vulkan-physical-device-count-smoke \
      --ppm-path "$TMP_DIR/raw-vulkan-physical-device-count-smoke.ppm"
}

assert_shadow_gpu_enumerate_adapters_count_smoke_rejects_ppm_path() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --ppm-path" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene enumerate-adapters-count-smoke \
      --ppm-path "$TMP_DIR/enumerate-adapters-count-smoke.ppm"
}

assert_shadow_gpu_enumerate_adapters_smoke_rejects_ppm_path() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --ppm-path" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene enumerate-adapters-smoke \
      --ppm-path "$TMP_DIR/enumerate-adapters-smoke.ppm"
}

assert_shadow_gpu_adapter_smoke_cli() {
  local summary_path="$TMP_DIR/adapter-smoke-summary.json"
  local output

  output="$(
    run_shadow_gpu_cli_allow_headless_skip adapter-smoke \
      nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
        --scene adapter-smoke \
        --allow-non-vulkan \
        --allow-software \
        --summary-path "$summary_path"
  )"

  if [[ "$output" == *'explicit host skip because no graphics adapter is present'* ]]; then
    [[ ! -e "$summary_path" ]] || {
      echo "adapter-smoke unexpectedly wrote a summary on adapterless host skip" >&2
      exit 1
    }
    printf '%s\n' "$output"
    return 0
  fi

  assert_contains "$output" '"mode": "adapter-smoke"'
  assert_contains "$output" '"scene": "adapter-smoke"'
  assert_json_field_equals "$summary_path" mode "adapter-smoke"
  assert_json_field_equals "$summary_path" scene "adapter-smoke"
}

assert_shadow_gpu_adapter_smoke_rejects_hold_secs() {
  assert_command_fails_contains "--scene instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --hold-secs" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene adapter-smoke \
      --allow-non-vulkan \
      --allow-software \
      --hold-secs 1
}

assert_shadow_gpu_device_request_smoke_cli() {
  local summary_path="$TMP_DIR/device-request-smoke-summary.json"
  local output

  output="$(
    run_shadow_gpu_cli_allow_headless_skip device-request-smoke \
      nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
        --scene device-request-smoke \
        --allow-non-vulkan \
        --allow-software \
        --summary-path "$summary_path"
  )"

  if [[ "$output" == *'explicit host skip because no graphics adapter is present'* ]]; then
    [[ ! -e "$summary_path" ]] || {
      echo "device-request-smoke unexpectedly wrote a summary on adapterless host skip" >&2
      exit 1
    }
    printf '%s\n' "$output"
    return 0
  fi

  assert_contains "$output" '"mode": "device-request-smoke"'
  assert_contains "$output" '"scene": "device-request-smoke"'
  assert_json_field_equals "$summary_path" mode "device-request-smoke"
  assert_json_field_equals "$summary_path" scene "device-request-smoke"
}

assert_shadow_gpu_device_request_smoke_rejects_hold_secs() {
  assert_command_fails_contains "--scene instance-smoke, raw-vulkan-instance-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --hold-secs" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene device-request-smoke \
      --allow-non-vulkan \
      --allow-software \
      --hold-secs 1
}

assert_shadow_gpu_device_smoke_cli() {
  local summary_path="$TMP_DIR/device-smoke-summary.json"
  local output

  output="$(
    run_shadow_gpu_cli_allow_headless_skip device-smoke \
      nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
        --scene device-smoke \
        --allow-non-vulkan \
        --allow-software \
        --summary-path "$summary_path"
  )"

  if [[ "$output" == *'explicit host skip because no graphics adapter is present'* ]]; then
    [[ ! -e "$summary_path" ]] || {
      echo "device-smoke unexpectedly wrote a summary on adapterless host skip" >&2
      exit 1
    }
    printf '%s\n' "$output"
    return 0
  fi

  assert_contains "$output" '"mode": "device-smoke"'
  assert_contains "$output" '"scene": "device-smoke"'
  assert_json_field_equals "$summary_path" mode "device-smoke"
  assert_json_field_equals "$summary_path" scene "device-smoke"
}

assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'payload_is_orange_gpu'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'prelude_is_orange_init'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"orange-gpu-prelude"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"orange-gpu-postlude"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"orange-gpu-checkpoint"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'SHADOW_HELLO_INIT_ORANGE_GPU_LOADER_PATH'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"bundle-smoke"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"vulkan-instance-smoke"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"raw-vulkan-instance-smoke"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"timeout-control-smoke"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"raw-vulkan-physical-device-count-query-exit-smoke"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"raw-vulkan-physical-device-count-query-no-destroy-smoke"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"raw-vulkan-physical-device-count-query-smoke"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"raw-vulkan-physical-device-count-smoke"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"vulkan-enumerate-adapters-count-smoke"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"vulkan-enumerate-adapters-smoke"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"vulkan-offscreen"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'SHADOW_HELLO_INIT_ORANGE_GPU_OUTPUT_PATH'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"child-watchdog-timeout"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'wait_for_child_with_watchdog'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'write_metadata_probe_report_best_effort'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'continuing to gpu payload'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"--present-kms"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"flat-orange"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'setenv(SHADOW_HELLO_INIT_GPU_BACKEND_ENV, "vulkan", 1)'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'setenv(SHADOW_HELLO_INIT_VK_ICD_FILENAMES_ENV, SHADOW_HELLO_INIT_ORANGE_GPU_ICD_PATH, 1)'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'setenv(SHADOW_HELLO_INIT_MESA_DRIVER_OVERRIDE_ENV, "kgsl", 1)'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_seen'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_launch_delay_secs'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_parent_probe_attempts'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_parent_probe_interval_secs'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_metadata_stage_breadcrumb'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'firmware_bootstrap'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'return "checker-orange";'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'return "solid-red";'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'return "solid-blue";'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'return "solid-yellow";'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'return "solid-cyan";'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'return "solid-magenta";'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'return "success-solid";'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"kgsl-timeout-gmu-hfi"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"kgsl-timeout-gx-oob"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"kgsl-timeout-cp-init"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"kgsl-timeout-control"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'SHADOW_HELLO_INIT_METADATA_DEVICE_PATH'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'prepare_metadata_stage_runtime_best_effort'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'write_metadata_stage_best_effort'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'probe_report_path'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'probe_timeout_class_path'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'metadata_probe_fingerprint_path'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'metadata_probe_report_path'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'metadata_probe_timeout_class_path'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_stage_metadata_payload.sh" 'ORIGINAL_ARGS=("$@")'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_stage_metadata_payload.sh" 'pixel_require_host_lock "$serial" "$0" "${ORIGINAL_ARGS[@]}"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"metadata-stage-write"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"parent-probe-start"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"parent-probe-result=exit-%d"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"parent-probe-result=%s-%d"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'watch_result.timed_out ? "watchdog-signal" : "signal"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"orange-gpu-launch-delay"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"orange-gpu-launch-delay-complete"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"orange-gpu-parent-probe-start"'
assert_file_contains "$REPO_ROOT/rust/init-wrapper/src/bin/hello-init.rs" 'probe-summary.json'
assert_file_contains "$REPO_ROOT/rust/init-wrapper/src/bin/hello-init.rs" 'probe-fingerprint.txt'
assert_file_contains "$REPO_ROOT/rust/init-wrapper/src/bin/hello-init.rs" 'probe-timeout-class.txt'
assert_file_contains "$REPO_ROOT/rust/init-wrapper/src/bin/hello-init.rs" '\"scene\":\"flat-orange\"'
assert_file_contains "$REPO_ROOT/rust/init-wrapper/src/bin/hello-init.rs" '"success-solid"'
assert_file_contains "$REPO_ROOT/rust/init-wrapper/src/bin/hello-init.rs" '"timeout-control-smoke"'
assert_file_contains "$REPO_ROOT/rust/init-wrapper/src/bin/hello-init.rs" '"c-kgsl-open-readonly-smoke"'
assert_file_contains "$REPO_ROOT/rust/init-wrapper/src/bin/hello-init.rs" '"raw-kgsl-getproperties-smoke"'
assert_file_contains "$REPO_ROOT/rust/init-wrapper/src/bin/hello-init.rs" '"function_graph\n"'
assert_file_contains "$REPO_ROOT/rust/init-wrapper/src/bin/hello-init.rs" '"parent-probe-result=skipped"'
assert_file_contains "$REPO_ROOT/rust/init-wrapper/src/bin/hello-init.rs" 'ensure_char_device(Path::new("/dev/ion"), 0o666, 10, 63)'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'ensure_char_device("/dev/ion", 0666, 10U, 63U)'
assert_file_contains "$REPO_ROOT/rust/drm-rect/src/lib.rs" 'code-orange-'
assert_file_contains "$REPO_ROOT/rust/drm-rect/src/lib.rs" '"solid-red"'
assert_file_contains "$REPO_ROOT/rust/drm-rect/src/lib.rs" '"solid-blue"'
assert_file_contains "$REPO_ROOT/rust/drm-rect/src/lib.rs" '"solid-yellow"'
assert_file_contains "$REPO_ROOT/rust/drm-rect/src/lib.rs" '"solid-cyan"'
assert_file_contains "$REPO_ROOT/rust/drm-rect/src/lib.rs" '"solid-magenta"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"orange-gpu-parent-probe-continue"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"orange-gpu-parent-probe-complete"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'validate_orange_gpu_config'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'missing required orange_gpu_mode config for payload=orange-gpu'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'invalid orange_gpu_mode config for payload=orange-gpu'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'SHADOW_HELLO_INIT_ORANGE_GPU_CHECKPOINT_HOLD_SECONDS'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_checkpoint_is_firmware_probe'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_checkpoint_is_timeout_classifier'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'strncmp(checkpoint_name, "kgsl-timeout-", 13U) == 0'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_uses_visible_checkpoints'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'checkpoint=validated'
assert_hello_init_orange_gpu_mode_parser_smoke
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_is_vulkan_instance_smoke'
assert_orange_gpu_instance_branch_shape
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_is_raw_vulkan_instance_smoke'
assert_orange_gpu_raw_vulkan_instance_branch_shape
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_is_firmware_probe_only'
assert_orange_gpu_firmware_probe_only_branch_shape
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_is_raw_vulkan_physical_device_count_query_exit_smoke'
assert_orange_gpu_raw_vulkan_physical_device_count_query_exit_branch_shape
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_is_raw_vulkan_physical_device_count_query_no_destroy_smoke'
assert_orange_gpu_raw_vulkan_physical_device_count_query_no_destroy_branch_shape
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_is_raw_vulkan_physical_device_count_query_smoke'
assert_orange_gpu_raw_vulkan_physical_device_count_query_branch_shape
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_is_raw_vulkan_physical_device_count_smoke'
assert_orange_gpu_raw_vulkan_physical_device_count_branch_shape
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_is_vulkan_enumerate_adapters_count_smoke'
assert_orange_gpu_enumerate_adapters_count_branch_shape
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_is_vulkan_enumerate_adapters_smoke'
assert_orange_gpu_enumerate_adapters_branch_shape
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_is_vulkan_adapter_smoke'
assert_orange_gpu_adapter_branch_shape
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_is_vulkan_device_request_smoke'
assert_orange_gpu_device_request_branch_shape
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_is_vulkan_device_smoke'
assert_orange_gpu_device_branch_shape
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_is_vulkan_offscreen'
assert_orange_gpu_offscreen_branch_shape
assert_orange_gpu_parent_probe_seam_shape
assert_hello_init_metadata_stage_seam_shape
assert_app_direct_present_typescript_manifest_selector_shape
assert_runtime_build_artifacts_timeline_manifest_selector_cli
assert_shadow_gpu_instance_helper_shape
assert_shadow_gpu_instance_smoke_cli
assert_shadow_gpu_instance_smoke_rejects_hold_secs
assert_shadow_gpu_instance_smoke_rejects_present_kms
assert_shadow_gpu_instance_smoke_rejects_ppm_path
assert_shadow_gpu_raw_vulkan_instance_helper_shape
assert_shadow_gpu_raw_vulkan_instance_smoke_cli
assert_shadow_gpu_raw_vulkan_instance_smoke_rejects_hold_secs
assert_shadow_gpu_raw_vulkan_instance_smoke_rejects_present_kms
assert_shadow_gpu_raw_vulkan_instance_smoke_rejects_ppm_path
assert_shadow_gpu_raw_vulkan_physical_device_count_query_exit_helper_shape
assert_shadow_gpu_raw_vulkan_physical_device_count_query_exit_smoke_cli
assert_shadow_gpu_raw_vulkan_physical_device_count_query_exit_smoke_rejects_hold_secs
assert_shadow_gpu_raw_vulkan_physical_device_count_query_exit_smoke_rejects_present_kms
assert_shadow_gpu_raw_vulkan_physical_device_count_query_exit_smoke_rejects_ppm_path
assert_shadow_gpu_raw_vulkan_physical_device_count_query_no_destroy_helper_shape
assert_shadow_gpu_raw_vulkan_physical_device_count_query_no_destroy_smoke_cli
assert_shadow_gpu_raw_vulkan_physical_device_count_query_no_destroy_smoke_rejects_hold_secs
assert_shadow_gpu_raw_vulkan_physical_device_count_query_no_destroy_smoke_rejects_present_kms
assert_shadow_gpu_raw_vulkan_physical_device_count_query_no_destroy_smoke_rejects_ppm_path
assert_shadow_gpu_raw_vulkan_physical_device_count_query_helper_shape
assert_shadow_gpu_raw_vulkan_physical_device_count_query_smoke_cli
assert_shadow_gpu_raw_vulkan_physical_device_count_query_smoke_rejects_hold_secs
assert_shadow_gpu_raw_vulkan_physical_device_count_query_smoke_rejects_present_kms
assert_shadow_gpu_raw_vulkan_physical_device_count_query_smoke_rejects_ppm_path
assert_shadow_gpu_raw_vulkan_physical_device_count_helper_shape
assert_shadow_gpu_raw_vulkan_physical_device_count_smoke_cli
assert_shadow_gpu_raw_vulkan_physical_device_count_smoke_rejects_hold_secs
assert_shadow_gpu_raw_vulkan_physical_device_count_smoke_rejects_present_kms
assert_shadow_gpu_raw_vulkan_physical_device_count_smoke_rejects_ppm_path
assert_shadow_gpu_enumerate_adapters_count_helper_shape
assert_shadow_gpu_enumerate_adapters_count_smoke_cli
assert_shadow_gpu_enumerate_adapters_count_smoke_rejects_hold_secs
assert_shadow_gpu_enumerate_adapters_count_smoke_rejects_present_kms
assert_shadow_gpu_enumerate_adapters_count_smoke_rejects_ppm_path
assert_shadow_gpu_enumerate_adapters_helper_shape
assert_shadow_gpu_enumerate_adapters_smoke_cli
assert_shadow_gpu_enumerate_adapters_smoke_rejects_hold_secs
assert_shadow_gpu_enumerate_adapters_smoke_rejects_present_kms
assert_shadow_gpu_enumerate_adapters_smoke_rejects_ppm_path
assert_shadow_gpu_adapter_helper_shape
assert_shadow_gpu_request_device_helper_shape
assert_shadow_gpu_adapter_smoke_cli
assert_shadow_gpu_adapter_smoke_rejects_hold_secs
assert_shadow_gpu_device_request_smoke_cli
assert_shadow_gpu_device_request_smoke_rejects_hold_secs
assert_shadow_gpu_device_smoke_cli
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" '[--scene smoke|flat-orange|orange-gpu-loop|bundle-smoke|instance-smoke|raw-vulkan-instance-smoke|raw-kgsl-open-readonly-smoke|raw-kgsl-getproperties-smoke|raw-vulkan-physical-device-count-query-exit-smoke|raw-vulkan-physical-device-count-query-no-destroy-smoke|raw-vulkan-physical-device-count-query-smoke|raw-vulkan-physical-device-count-smoke|enumerate-adapters-count-smoke|enumerate-adapters-smoke|adapter-smoke|device-request-smoke|device-smoke]'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'BundleSmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'InstanceSmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'RawVulkanInstanceSmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'RawVulkanPhysicalDeviceCountQuerySmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'RawVulkanPhysicalDeviceCountSmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'EnumerateAdaptersCountSmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'EnumerateAdaptersSmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'AdapterSmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'DeviceRequestSmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'DeviceSmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'mode: "bundle-smoke",'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'mode: "instance-smoke",'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'mode: "raw-vulkan-instance-smoke",'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'raw-vulkan-physical-device-count-query-exit-smoke: exit-status=0-before-summary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'mode: "raw-vulkan-physical-device-count-query-no-destroy-smoke",'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'mode: "raw-vulkan-physical-device-count-query-smoke",'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'mode: "raw-vulkan-physical-device-count-smoke",'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'mode: "enumerate-adapters-count-smoke",'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'mode: "enumerate-adapters-smoke",'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'Self::BundleSmoke => "bundle-smoke"'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'Self::InstanceSmoke => "instance-smoke"'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'Self::RawVulkanInstanceSmoke => "raw-vulkan-instance-smoke"'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'Self::RawVulkanPhysicalDeviceCountQueryExitSmoke => {'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" '"raw-vulkan-physical-device-count-query-exit-smoke"'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'Self::RawVulkanPhysicalDeviceCountQueryNoDestroySmoke => {'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" '"raw-vulkan-physical-device-count-query-no-destroy-smoke"'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'Self::RawVulkanPhysicalDeviceCountQuerySmoke => {'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" '"raw-vulkan-physical-device-count-query-smoke"'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'Self::RawVulkanPhysicalDeviceCountSmoke => "raw-vulkan-physical-device-count-smoke"'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'Self::EnumerateAdaptersCountSmoke => "enumerate-adapters-count-smoke"'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'Self::EnumerateAdaptersSmoke => "enumerate-adapters-smoke"'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'Self::AdapterSmoke => "adapter-smoke"'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'Self::DeviceRequestSmoke => "device-request-smoke"'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'Self::DeviceSmoke => "device-smoke"'
assert_file_contains "$REPO_ROOT/ui/third_party/wgpu_context/src/lib.rs" 'pub async fn create_headless_adapter_info(&self) -> Result<AdapterInfo, WgpuContextError>'
assert_file_contains "$REPO_ROOT/ui/third_party/wgpu_context/src/lib.rs" 'pub async fn create_headless_device_handle(&mut self) -> Result<DeviceHandle, WgpuContextError>'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'stage_gpu_bundle'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'assert_prelude_word'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'assert_orange_gpu_mode_word'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'PIXEL_ORANGE_GPU_LAUNCH_DELAY_SECS:-0'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'PIXEL_ORANGE_GPU_PARENT_PROBE_ATTEMPTS:-0'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'PIXEL_ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS:-0'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'PIXEL_ORANGE_GPU_METADATA_STAGE_BREADCRUMB:-false'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'PIXEL_ORANGE_GPU_FIRMWARE_BOOTSTRAP:-none'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'PIXEL_ORANGE_GPU_FIRMWARE_DIR:-'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" '--orange-gpu-launch-delay-secs'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" '--orange-gpu-parent-probe-attempts'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" '--orange-gpu-parent-probe-interval-secs'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" '--orange-gpu-metadata-stage-breadcrumb'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" '--firmware-bootstrap'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" '--firmware-dir'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'orange_gpu_launch_delay_secs='
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'orange_gpu_parent_probe_attempts='
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'orange_gpu_parent_probe_interval_secs='
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'orange_gpu_metadata_stage_breadcrumb='
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'firmware_bootstrap='
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'PIXEL_ORANGE_GPU_INPUT_MODULE_DIR:-'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" '--input-module-dir'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'input-bootstrap sunfish-touch-event2 requires --mount-dev true'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'input-bootstrap sunfish-touch-event2 requires --dev-mount tmpfs'
assert_file_contains "$REPO_ROOT/rust/init-wrapper/src/bin/hello-init.rs" 'app_direct_present_manual_touch'
assert_file_contains "$REPO_ROOT/rust/init-wrapper/src/bin/hello-init.rs" '"physical-touch"'
assert_file_contains "$REPO_ROOT/rust/init-wrapper/src/bin/hello-init.rs" 'profile.injection'
assert_file_contains "$REPO_ROOT/rust/init-wrapper/src/bin/hello-init.rs" 'sunfish touch input bootstrap requires dev_mount=tmpfs'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Prelude: %s\\n' \"\$PRELUDE\""
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Orange GPU mode: %s\\n' \"\$ORANGE_GPU_MODE\""
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Orange GPU launch delay seconds: %s\\n' \"\$ORANGE_GPU_LAUNCH_DELAY_SECS\""
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Orange GPU parent probe attempts: %s\\n' \"\$ORANGE_GPU_PARENT_PROBE_ATTEMPTS\""
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Orange GPU parent probe interval seconds: %s\\n' \"\$ORANGE_GPU_PARENT_PROBE_INTERVAL_SECS\""
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Orange GPU metadata stage breadcrumb: %s\\n' \"\$ORANGE_GPU_METADATA_STAGE_BREADCRUMB\""
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Firmware bootstrap: %s\\n' \"\$FIRMWARE_BOOTSTRAP\""
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU firmware dir: %s\\n' \"\$GPU_FIRMWARE_DIR\""
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Metadata stage path: %s\\n' \"\$(metadata_stage_path_for_token \"\$RUN_TOKEN\")\""
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Parent readiness probe scene: raw-vulkan-physical-device-count-query-exit-smoke\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Bundle exec mode: bundle-smoke\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict Vulkan instance creation\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict raw Vulkan loader plus vkCreateInstance/vkDestroyInstance\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict raw Vulkan physical-device count query without explicit destroy\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict raw Vulkan physical-device count query plus explicit destroy\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict raw Vulkan physical-device enumeration count\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict Vulkan raw adapter enumeration count\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict Vulkan adapter enumeration\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict Vulkan adapter selection\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict Vulkan device request\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict Vulkan buffer renderer bring-up\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict Vulkan offscreen render\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Derived success postlude: %s\\n' \"\$(success_postlude_value)\""
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Visible checkpoint hold seconds: %s\\n' \"\$(checkpoint_hold_seconds_value)\""
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'PIXEL_ORANGE_GPU_DRI_BOOTSTRAP:-'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'PIXEL_ORANGE_GPU_INPUT_BOOTSTRAP:-none'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" '--app-direct-present-manual-touch'

default_orange_gpu_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$DEFAULT_OUTPUT_IMAGE" \
      --hold-secs 7 \
      --reboot-target bootloader \
      --run-token orange-gpu-default-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$default_orange_gpu_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$default_orange_gpu_boot_output" "Payload contract: hello-init executes the staged shadow-gpu-smoke bundle from /orange-gpu"
assert_contains "$default_orange_gpu_boot_output" "Orange GPU mode: gpu-render"
assert_contains "$default_orange_gpu_boot_output" "GPU scene: flat-orange"
assert_contains "$default_orange_gpu_boot_output" "Prelude: none"
assert_contains "$default_orange_gpu_boot_output" "Prelude hold seconds: 0"
assert_contains "$default_orange_gpu_boot_output" "Derived success postlude: none"
assert_cpio_entry_absent "$DEFAULT_OUTPUT_IMAGE" orange-init
assert_cpio_entry_equals "$DEFAULT_OUTPUT_IMAGE" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=gpu-render\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-default-run-token\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$DEFAULT_OUTPUT_IMAGE.hello-init.json" prelude "none"
assert_json_field_equals "$DEFAULT_OUTPUT_IMAGE.hello-init.json" prelude_hold_seconds "0"
assert_json_field_equals "$DEFAULT_OUTPUT_IMAGE.hello-init.json" orange_gpu_mode "gpu-render"
assert_json_field_equals "$DEFAULT_OUTPUT_IMAGE.hello-init.json" orange_gpu_scene "flat-orange"
assert_json_field_equals "$DEFAULT_OUTPUT_IMAGE.hello-init.json" success_postlude "none"
assert_json_field_equals "$DEFAULT_OUTPUT_IMAGE.hello-init.json" checkpoint_hold_seconds "0"
assert_json_field_equals "$DEFAULT_OUTPUT_IMAGE.hello-init.json" orange_gpu_launch_delay_secs "0"
assert_json_field_equals "$DEFAULT_OUTPUT_IMAGE.hello-init.json" orange_gpu_parent_probe_attempts "0"
assert_json_field_equals "$DEFAULT_OUTPUT_IMAGE.hello-init.json" orange_gpu_parent_probe_interval_secs "0"
assert_json_field_equals "$DEFAULT_OUTPUT_IMAGE.hello-init.json" orange_gpu_watchdog_timeout_secs "0"

launch_delay_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_ORANGE_GPU_LAUNCH_DELAY_SECS=9 \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-launch-delay-boot.img" \
      --hold-secs 7 \
      --orange-gpu-mode raw-vulkan-physical-device-count-query-exit-smoke \
      --reboot-target bootloader \
      --run-token orange-gpu-launch-delay-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$launch_delay_boot_output" "Orange GPU mode: raw-vulkan-physical-device-count-query-exit-smoke"
assert_contains "$launch_delay_boot_output" "Orange GPU launch delay seconds: 9"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-launch-delay-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=raw-vulkan-physical-device-count-query-exit-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-launch-delay-run-token\norange_gpu_launch_delay_secs=9\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-launch-delay-boot.img.hello-init.json" orange_gpu_mode "raw-vulkan-physical-device-count-query-exit-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-launch-delay-boot.img.hello-init.json" orange_gpu_launch_delay_secs "9"
assert_json_field_equals "$TMP_DIR/orange-gpu-launch-delay-boot.img.hello-init.json" checkpoint_hold_seconds "0"

parent_probe_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-parent-probe-boot.img" \
      --hold-secs 7 \
      --orange-gpu-mode raw-vulkan-physical-device-count-query-exit-smoke \
      --orange-gpu-parent-probe-attempts 3 \
      --orange-gpu-parent-probe-interval-secs 2 \
      --reboot-target bootloader \
      --run-token orange-gpu-parent-probe-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$parent_probe_boot_output" "Orange GPU mode: raw-vulkan-physical-device-count-query-exit-smoke"
assert_contains "$parent_probe_boot_output" "Orange GPU parent probe attempts: 3"
assert_contains "$parent_probe_boot_output" "Orange GPU parent probe interval seconds: 2"
assert_contains "$parent_probe_boot_output" "Parent readiness probe scene: raw-vulkan-physical-device-count-query-exit-smoke"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-parent-probe-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=raw-vulkan-physical-device-count-query-exit-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-parent-probe-run-token\norange_gpu_parent_probe_attempts=3\norange_gpu_parent_probe_interval_secs=2\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-parent-probe-boot.img.hello-init.json" orange_gpu_mode "raw-vulkan-physical-device-count-query-exit-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-parent-probe-boot.img.hello-init.json" orange_gpu_parent_probe_attempts "3"
assert_json_field_equals "$TMP_DIR/orange-gpu-parent-probe-boot.img.hello-init.json" orange_gpu_parent_probe_interval_secs "2"

parent_probe_metadata_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-parent-probe-metadata-boot.img" \
      --hold-secs 7 \
      --orange-gpu-mode raw-vulkan-physical-device-count-query-exit-smoke \
      --orange-gpu-parent-probe-attempts 3 \
      --orange-gpu-parent-probe-interval-secs 2 \
      --orange-gpu-metadata-stage-breadcrumb true \
      --reboot-target bootloader \
      --run-token orange-gpu-parent-probe-metadata-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$parent_probe_metadata_boot_output" "Orange GPU metadata stage breadcrumb: true"
assert_contains "$parent_probe_metadata_boot_output" "Metadata stage path: /metadata/shadow-hello-init/by-token/orange-gpu-parent-probe-metadata-run-token/stage.txt"
assert_contains "$parent_probe_metadata_boot_output" "Metadata probe stage path: /metadata/shadow-hello-init/by-token/orange-gpu-parent-probe-metadata-run-token/probe-stage.txt"
assert_contains "$parent_probe_metadata_boot_output" "Metadata probe fingerprint path: /metadata/shadow-hello-init/by-token/orange-gpu-parent-probe-metadata-run-token/probe-fingerprint.txt"
assert_contains "$parent_probe_metadata_boot_output" "Metadata probe timeout class path: /metadata/shadow-hello-init/by-token/orange-gpu-parent-probe-metadata-run-token/probe-timeout-class.txt"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-parent-probe-metadata-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=raw-vulkan-physical-device-count-query-exit-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-parent-probe-metadata-run-token\norange_gpu_parent_probe_attempts=3\norange_gpu_parent_probe_interval_secs=2\norange_gpu_metadata_stage_breadcrumb=true\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-parent-probe-metadata-boot.img.hello-init.json" orange_gpu_metadata_stage_breadcrumb "true"
assert_json_field_equals "$TMP_DIR/orange-gpu-parent-probe-metadata-boot.img.hello-init.json" metadata_stage_path "/metadata/shadow-hello-init/by-token/orange-gpu-parent-probe-metadata-run-token/stage.txt"
assert_json_field_equals "$TMP_DIR/orange-gpu-parent-probe-metadata-boot.img.hello-init.json" metadata_probe_stage_path "/metadata/shadow-hello-init/by-token/orange-gpu-parent-probe-metadata-run-token/probe-stage.txt"
assert_json_field_equals "$TMP_DIR/orange-gpu-parent-probe-metadata-boot.img.hello-init.json" metadata_probe_fingerprint_path "/metadata/shadow-hello-init/by-token/orange-gpu-parent-probe-metadata-run-token/probe-fingerprint.txt"
assert_json_field_equals "$TMP_DIR/orange-gpu-parent-probe-metadata-boot.img.hello-init.json" metadata_probe_timeout_class_path "/metadata/shadow-hello-init/by-token/orange-gpu-parent-probe-metadata-run-token/probe-timeout-class.txt"

parent_probe_metadata_no_probe_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-parent-probe-metadata-no-probe-boot.img" \
      --hold-secs 7 \
      --orange-gpu-mode raw-vulkan-physical-device-count-query-exit-smoke \
      --orange-gpu-metadata-stage-breadcrumb true \
      --reboot-target bootloader \
      --run-token orange-gpu-parent-probe-metadata-no-probe-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$parent_probe_metadata_no_probe_boot_output" "Orange GPU metadata stage breadcrumb: true"
assert_contains "$parent_probe_metadata_no_probe_boot_output" "Orange GPU parent probe attempts: 0"
assert_contains "$parent_probe_metadata_no_probe_boot_output" "Metadata stage path: /metadata/shadow-hello-init/by-token/orange-gpu-parent-probe-metadata-no-probe-run-token/stage.txt"
assert_contains "$parent_probe_metadata_no_probe_boot_output" "Metadata probe stage path: /metadata/shadow-hello-init/by-token/orange-gpu-parent-probe-metadata-no-probe-run-token/probe-stage.txt"
assert_contains "$parent_probe_metadata_no_probe_boot_output" "Metadata probe fingerprint path: /metadata/shadow-hello-init/by-token/orange-gpu-parent-probe-metadata-no-probe-run-token/probe-fingerprint.txt"
assert_contains "$parent_probe_metadata_no_probe_boot_output" "Metadata probe timeout class path: /metadata/shadow-hello-init/by-token/orange-gpu-parent-probe-metadata-no-probe-run-token/probe-timeout-class.txt"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-parent-probe-metadata-no-probe-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=raw-vulkan-physical-device-count-query-exit-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-parent-probe-metadata-no-probe-run-token\norange_gpu_metadata_stage_breadcrumb=true\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-parent-probe-metadata-no-probe-boot.img.hello-init.json" orange_gpu_metadata_stage_breadcrumb "true"
assert_json_field_equals "$TMP_DIR/orange-gpu-parent-probe-metadata-no-probe-boot.img.hello-init.json" metadata_stage_path "/metadata/shadow-hello-init/by-token/orange-gpu-parent-probe-metadata-no-probe-run-token/stage.txt"
assert_json_field_equals "$TMP_DIR/orange-gpu-parent-probe-metadata-no-probe-boot.img.hello-init.json" metadata_probe_stage_path "/metadata/shadow-hello-init/by-token/orange-gpu-parent-probe-metadata-no-probe-run-token/probe-stage.txt"
assert_json_field_equals "$TMP_DIR/orange-gpu-parent-probe-metadata-no-probe-boot.img.hello-init.json" metadata_probe_fingerprint_path "/metadata/shadow-hello-init/by-token/orange-gpu-parent-probe-metadata-no-probe-run-token/probe-fingerprint.txt"
assert_json_field_equals "$TMP_DIR/orange-gpu-parent-probe-metadata-no-probe-boot.img.hello-init.json" metadata_probe_timeout_class_path "/metadata/shadow-hello-init/by-token/orange-gpu-parent-probe-metadata-no-probe-run-token/probe-timeout-class.txt"

payload_partition_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/payload-partition-probe.img" \
      --hello-init-mode rust-bridge \
      --hold-secs 7 \
      --orange-gpu-mode payload-partition-probe \
      --orange-gpu-metadata-stage-breadcrumb true \
      --reboot-target bootloader \
      --run-token payload-partition-probe-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$payload_partition_boot_output" "Payload contract: hello-init mounts /metadata and probes Shadow-owned payload manifest at /metadata/shadow-payload/by-token/payload-partition-probe-run-token/manifest.env"
assert_contains "$payload_partition_boot_output" "Payload root: /metadata/shadow-payload/by-token/payload-partition-probe-run-token"
assert_contains "$payload_partition_boot_output" "Metadata payload strategy: metadata-shadow-payload-v1"
assert_contains "$payload_partition_boot_output" "Payload source: metadata"
assert_contains "$payload_partition_boot_output" "Metadata payload manifest path: /metadata/shadow-payload/by-token/payload-partition-probe-run-token/manifest.env"
assert_contains "$payload_partition_boot_output" "Payload fallback path: /orange-gpu"
assert_contains "$payload_partition_boot_output" "GPU scene: none"
assert_contains "$payload_partition_boot_output" "Orange GPU metadata stage breadcrumb: true"
assert_contains "$payload_partition_boot_output" "Metadata payload root: /metadata/shadow-payload/by-token/payload-partition-probe-run-token"
assert_contains "$payload_partition_boot_output" "Metadata payload manifest path: /metadata/shadow-payload/by-token/payload-partition-probe-run-token/manifest.env"
assert_contains "$payload_partition_boot_output" "DRI bootstrap: none"
assert_contains "$payload_partition_boot_output" "Hello-init mode: rust-bridge"
assert_cpio_entry_equals "$TMP_DIR/payload-partition-probe.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=payload-partition-probe\nhold_seconds=7\nreboot_target=bootloader\nrun_token=payload-partition-probe-run-token\norange_gpu_metadata_stage_breadcrumb=true\npayload_probe_strategy=metadata-shadow-payload-v1\npayload_probe_source=metadata\npayload_probe_root=/metadata/shadow-payload/by-token/payload-partition-probe-run-token\npayload_probe_manifest_path=/metadata/shadow-payload/by-token/payload-partition-probe-run-token/manifest.env\npayload_probe_fallback_path=/orange-gpu\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=none\n'
assert_cpio_entry_equals "$TMP_DIR/payload-partition-probe.img" system/bin/init $'#!/system/bin/sh\n# shadow-owned-init-role:hello-init\n# shadow-owned-init-impl:rust-static\n# shadow-owned-init-config:/shadow-init.cfg\necho hello-init-rust-shim-exec\n'
assert_cpio_entry_equals "$TMP_DIR/payload-partition-probe.img" hello-init-child $'#!/system/bin/sh\n# shadow-owned-init-role:hello-init\n# shadow-owned-init-impl:rust-static\n# shadow-owned-init-config:/shadow-init.cfg\necho hello-init-rust-child\n'
assert_cpio_entry_absent "$TMP_DIR/payload-partition-probe.img" orange-gpu
assert_cpio_entry_absent "$TMP_DIR/payload-partition-probe.img" orange-gpu/shadow-gpu-smoke
assert_cpio_entry_absent "$TMP_DIR/payload-partition-probe.img" orange-gpu/lib/ld-linux-aarch64.so.1
assert_json_field_equals "$TMP_DIR/payload-partition-probe.img.hello-init.json" orange_gpu_mode "payload-partition-probe"
assert_json_field_equals "$TMP_DIR/payload-partition-probe.img.hello-init.json" hello_init_mode "rust-bridge"
assert_json_field_equals "$TMP_DIR/payload-partition-probe.img.hello-init.json" orange_gpu_metadata_stage_breadcrumb "true"
assert_json_field_equals "$TMP_DIR/payload-partition-probe.img.hello-init.json" payload_probe_strategy "metadata-shadow-payload-v1"
assert_json_field_equals "$TMP_DIR/payload-partition-probe.img.hello-init.json" payload_probe_source "metadata"
assert_json_field_equals "$TMP_DIR/payload-partition-probe.img.hello-init.json" payload_probe_root "/metadata/shadow-payload/by-token/payload-partition-probe-run-token"
assert_json_field_equals "$TMP_DIR/payload-partition-probe.img.hello-init.json" payload_probe_manifest_path "/metadata/shadow-payload/by-token/payload-partition-probe-run-token/manifest.env"
assert_json_field_equals "$TMP_DIR/payload-partition-probe.img.hello-init.json" payload_probe_fallback_path "/orange-gpu"
assert_json_field_equals "$TMP_DIR/payload-partition-probe.img.hello-init.json" metadata_probe_summary_path "/metadata/shadow-hello-init/by-token/payload-partition-probe-run-token/probe-summary.json"

PAYLOAD_STAGE_DIR="$TMP_DIR/metadata-payload-stage"
payload_stage_output="$(
  env PATH="$MOCK_BIN:$PATH" PIXEL_HELLO_INIT_RUN_TOKEN=payload-partition-probe-run-token \
    "$REPO_ROOT/scripts/pixel/pixel_boot_stage_metadata_payload.sh" \
      --dry-run \
      --output-dir "$PAYLOAD_STAGE_DIR" \
      --version shadow-payload-probe-v1
)"
assert_contains "$payload_stage_output" "Dry run: true"
assert_contains "$payload_stage_output" "Payload root: /metadata/shadow-payload/by-token/payload-partition-probe-run-token"
assert_contains "$payload_stage_output" "Payload fingerprint: sha256:"
assert_file_contains "$PAYLOAD_STAGE_DIR/manifest.env" "schema=metadata-shadow-payload-v1"
assert_file_contains "$PAYLOAD_STAGE_DIR/manifest.env" "payload_source=metadata"
assert_file_contains "$PAYLOAD_STAGE_DIR/manifest.env" "payload_fingerprint=sha256:"
assert_file_contains "$PAYLOAD_STAGE_DIR/manifest.env" "payload_root=/metadata/shadow-payload/by-token/payload-partition-probe-run-token"
assert_file_contains "$PAYLOAD_STAGE_DIR/manifest.env" "payload_marker=payload.txt"
assert_file_contains "$PAYLOAD_STAGE_DIR/payload.txt" "run_token=payload-partition-probe-run-token"

payload_partition_shadow_logical_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/payload-partition-shadow-logical-probe.img" \
      --hello-init-mode rust-bridge \
      --hold-secs 7 \
      --orange-gpu-mode payload-partition-probe \
      --orange-gpu-metadata-stage-breadcrumb true \
      --payload-probe-source shadow-logical-partition \
      --payload-probe-root /shadow-payload \
      --payload-probe-manifest-path /shadow-payload/manifest.env \
      --reboot-target bootloader \
      --run-token payload-partition-shadow-logical-run-token \
      --dev-mount tmpfs \
      --mount-sys true \
      --log-kmsg false \
      --log-pmsg false
)"
assert_contains "$payload_partition_shadow_logical_boot_output" "Payload root: /shadow-payload"
assert_contains "$payload_partition_shadow_logical_boot_output" "Payload source: shadow-logical-partition"
assert_contains "$payload_partition_shadow_logical_boot_output" "Metadata payload manifest path: /shadow-payload/manifest.env"
assert_cpio_entry_equals "$TMP_DIR/payload-partition-shadow-logical-probe.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=payload-partition-probe\nhold_seconds=7\nreboot_target=bootloader\nrun_token=payload-partition-shadow-logical-run-token\norange_gpu_metadata_stage_breadcrumb=true\npayload_probe_strategy=metadata-shadow-payload-v1\npayload_probe_source=shadow-logical-partition\npayload_probe_root=/shadow-payload\npayload_probe_manifest_path=/shadow-payload/manifest.env\npayload_probe_fallback_path=/orange-gpu\ndev_mount=tmpfs\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=none\n'
assert_json_field_equals "$TMP_DIR/payload-partition-shadow-logical-probe.img.hello-init.json" payload_probe_source "shadow-logical-partition"
assert_json_field_equals "$TMP_DIR/payload-partition-shadow-logical-probe.img.hello-init.json" payload_probe_root "/shadow-payload"
assert_json_field_equals "$TMP_DIR/payload-partition-shadow-logical-probe.img.hello-init.json" payload_probe_manifest_path "/shadow-payload/manifest.env"
assert_json_field_equals "$TMP_DIR/payload-partition-shadow-logical-probe.img.hello-init.json" mount_sys "true"

PAYLOAD_SHADOW_LOGICAL_STAGE_DIR="$TMP_DIR/shadow-logical-payload-stage"
payload_shadow_logical_stage_output="$(
  env PATH="$MOCK_BIN:$PATH" PIXEL_HELLO_INIT_RUN_TOKEN=payload-partition-shadow-logical-run-token \
    "$REPO_ROOT/scripts/pixel/pixel_boot_stage_metadata_payload.sh" \
      --dry-run \
      --source shadow-logical-partition \
      --output-dir "$PAYLOAD_SHADOW_LOGICAL_STAGE_DIR" \
      --version shadow-logical-payload-v1
)"
assert_contains "$payload_shadow_logical_stage_output" "Payload root: /shadow-payload"
assert_contains "$payload_shadow_logical_stage_output" "Manifest root: /shadow-payload"
assert_contains "$payload_shadow_logical_stage_output" "Payload source: shadow-logical-partition"
assert_contains "$payload_shadow_logical_stage_output" "Shadow logical size MiB: 256"
assert_file_contains "$PAYLOAD_SHADOW_LOGICAL_STAGE_DIR/manifest.env" "payload_source=shadow-logical-partition"
assert_file_contains "$PAYLOAD_SHADOW_LOGICAL_STAGE_DIR/manifest.env" "payload_root=/shadow-payload"

assert_command_fails_contains "payload-probe-source shadow-logical-partition requires --mount-sys true" \
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-shadow-logical-mount-sys.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode payload-partition-probe \
      --orange-gpu-metadata-stage-breadcrumb true \
      --payload-probe-source shadow-logical-partition \
      --payload-probe-root /shadow-payload \
      --payload-probe-manifest-path /shadow-payload/manifest.env \
      --run-token should-fail-shadow-logical-mount-sys \
      --mount-sys false

assert_command_fails_contains "/shadow-payload requires --payload-probe-source shadow-logical-partition" \
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-shadow-root-metadata-source.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode payload-partition-probe \
      --orange-gpu-metadata-stage-breadcrumb true \
      --payload-probe-source metadata \
      --payload-probe-root /shadow-payload \
      --payload-probe-manifest-path /shadow-payload/manifest.env \
      --run-token should-fail-shadow-root-metadata-source \
      --mount-sys true

assert_command_fails_contains "payload-partition-probe requires --hello-init-mode rust-bridge" \
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-payload-partition-c-init.img" \
      --orange-gpu-mode payload-partition-probe \
      --orange-gpu-metadata-stage-breadcrumb true \
      --run-token payload-partition-probe-c-init-run-token

bundle_smoke_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$OUTPUT_IMAGE" \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode bundle-smoke \
      --reboot-target bootloader \
      --run-token orange-gpu-smoke-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$bundle_smoke_boot_output" "Build mode: stock-init"
assert_contains "$bundle_smoke_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$bundle_smoke_boot_output" "Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in bundle-smoke mode from /orange-gpu"
assert_contains "$bundle_smoke_boot_output" "Payload root: /orange-gpu"
assert_contains "$bundle_smoke_boot_output" "GPU bundle dir: $GPU_BUNDLE_DIR"
assert_contains "$bundle_smoke_boot_output" "GPU bundle staged dir: "
assert_contains "$bundle_smoke_boot_output" "GPU exec path: /orange-gpu/shadow-gpu-smoke"
assert_contains "$bundle_smoke_boot_output" "GPU loader path: /orange-gpu/lib/ld-linux-aarch64.so.1"
assert_contains "$bundle_smoke_boot_output" "Orange GPU mode: bundle-smoke"
assert_contains "$bundle_smoke_boot_output" "Bundle exec mode: bundle-smoke"
assert_contains "$bundle_smoke_boot_output" "Prelude: orange-init"
assert_contains "$bundle_smoke_boot_output" "Prelude hold seconds: 2"
assert_contains "$bundle_smoke_boot_output" "Prelude payload path: /orange-init"
assert_contains "$bundle_smoke_boot_output" "Derived success postlude: orange-init"
assert_contains "$bundle_smoke_boot_output" "Visible checkpoint hold seconds: 1"
assert_contains "$bundle_smoke_boot_output" "Visible sequence: orange 2s -> orange 1s -> orange 7s on success"
assert_contains "$bundle_smoke_boot_output" "Config path: /shadow-init.cfg"
assert_contains "$bundle_smoke_boot_output" "Configured hold seconds: 7"
assert_contains "$bundle_smoke_boot_output" "Reboot target: bootloader"
assert_contains "$bundle_smoke_boot_output" "Run token: orange-gpu-smoke-run-token"
assert_contains "$bundle_smoke_boot_output" "Dev mount style: tmpfs"
assert_contains "$bundle_smoke_boot_output" "Mount sys: false"
assert_contains "$bundle_smoke_boot_output" "Log kmsg: false"
assert_contains "$bundle_smoke_boot_output" "Log pmsg: false"
assert_contains "$bundle_smoke_boot_output" "DRI bootstrap: sunfish-card0-renderD128"
assert_contains "$bundle_smoke_boot_output" "Metadata path: $OUTPUT_IMAGE.hello-init.json"
assert_cpio_entry_symlink_target "$OUTPUT_IMAGE" init "/system/bin/init"
assert_cpio_entry_equals "$OUTPUT_IMAGE" system/bin/init $'#!/system/bin/sh\n# shadow-owned-init-role:hello-init\n# shadow-owned-init-impl:c-static\n# shadow-owned-init-config:/shadow-init.cfg\n# shadow-owned-init-mounts:dev=true,proc=true,sys=true\necho hello-init\n'
assert_cpio_entry_equals "$OUTPUT_IMAGE" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=bundle-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-smoke-run-token\nprelude=orange-init\nprelude_hold_seconds=2\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128\n'
assert_cpio_entry_equals "$OUTPUT_IMAGE" orange-init $'#!/system/bin/sh\n# shadow-owned-init-role:orange-init\n# shadow-owned-init-impl:drm-rect-device\n# shadow-owned-init-path:/orange-init\necho orange-init\n'
assert_cpio_entry_present "$OUTPUT_IMAGE" orange-gpu
assert_cpio_entry_equals "$OUTPUT_IMAGE" orange-gpu/shadow-gpu-smoke $'ELF_BINARY_AARCH64\n'
assert_cpio_entry_equals "$OUTPUT_IMAGE" orange-gpu/lib/ld-linux-aarch64.so.1 $'ELF_LOADER_AARCH64\n'
assert_cpio_entry_equals "$OUTPUT_IMAGE" orange-gpu/share/vulkan/icd.d/freedreno_icd.aarch64.json $'{\n    "ICD": {\n        "api_version": "1.4.335",\n        "library_arch": "64",\n        "library_path": "/orange-gpu/lib/libvulkan_freedreno.so"\n    },\n    "file_format_version": "1.0.1"\n}\n'
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" kind "orange_gpu_build"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" payload "orange-gpu"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" orange_gpu_mode "bundle-smoke"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" gpu_bundle_dir "$GPU_BUNDLE_DIR"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" hold_seconds "7"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" prelude "orange-init"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" prelude_hold_seconds "2"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" reboot_target "bootloader"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" run_token "orange-gpu-smoke-run-token"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" dev_mount "tmpfs"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" mount_dev "true"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" mount_proc "true"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" mount_sys "false"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" log_kmsg "false"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" log_pmsg "false"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" dri_bootstrap "sunfish-card0-renderD128"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" success_postlude "orange-init"
assert_json_field_equals "$OUTPUT_IMAGE.hello-init.json" checkpoint_hold_seconds "1"

GPU_FIRMWARE_DIR="$TMP_DIR/gpu-firmware"
mkdir -p "$GPU_FIRMWARE_DIR"
printf 'sqe-firmware\n' >"$GPU_FIRMWARE_DIR/a630_sqe.fw"
printf 'gmu-firmware\n' >"$GPU_FIRMWARE_DIR/a618_gmu.bin"
printf 'zap-metadata\n' >"$GPU_FIRMWARE_DIR/a615_zap.mdt"
printf 'zap-segment\n' >"$GPU_FIRMWARE_DIR/a615_zap.b02"
printf 'fts-firmware\n' >"$GPU_FIRMWARE_DIR/ftm5_fw.ftb"
INPUT_MODULE_DIR="$TMP_DIR/input-modules"
mkdir -p "$INPUT_MODULE_DIR"
printf 'heatmap-module\n' >"$INPUT_MODULE_DIR/heatmap.ko"
printf 'ftm5-module\n' >"$INPUT_MODULE_DIR/ftm5.ko"

assert_command_fails_contains \
  "input-bootstrap sunfish-touch-event2 requires --dev-mount tmpfs" \
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-input-bootstrap-devtmpfs-rejected.img" \
      --orange-gpu-mode c-kgsl-open-readonly-smoke \
      --dev-mount devtmpfs \
      --mount-sys true \
      --firmware-bootstrap ramdisk-lib-firmware \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --input-bootstrap sunfish-touch-event2 \
      --input-module-dir "$INPUT_MODULE_DIR"

assert_command_fails_contains \
  "input-bootstrap sunfish-touch-event2 requires --mount-dev true" \
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-input-bootstrap-mount-dev-rejected.img" \
      --orange-gpu-mode c-kgsl-open-readonly-smoke \
      --dev-mount tmpfs \
      --mount-dev false \
      --mount-sys true \
      --firmware-bootstrap ramdisk-lib-firmware \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --input-bootstrap sunfish-touch-event2 \
      --input-module-dir "$INPUT_MODULE_DIR"

c_kgsl_firmware_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-c-kgsl-firmware-boot.img" \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode c-kgsl-open-readonly-smoke \
      --orange-gpu-watchdog-timeout-secs 12 \
      --reboot-target bootloader \
      --run-token orange-gpu-c-kgsl-firmware-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false \
      --firmware-bootstrap ramdisk-lib-firmware \
      --firmware-dir "$GPU_FIRMWARE_DIR"
)"

assert_contains "$c_kgsl_firmware_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$c_kgsl_firmware_boot_output" "Payload contract: hello-init directly opens /dev/kgsl-3d0 read-only in the owned child process before any staged Rust bundle exec"
assert_contains "$c_kgsl_firmware_boot_output" "GPU proof: direct C-owned read-only open of /dev/kgsl-3d0 before any staged Rust bundle exec"
assert_contains "$c_kgsl_firmware_boot_output" "Firmware bootstrap: ramdisk-lib-firmware"
assert_contains "$c_kgsl_firmware_boot_output" "GPU firmware dir: $GPU_FIRMWARE_DIR"
assert_contains "$c_kgsl_firmware_boot_output" "Orange GPU watchdog timeout seconds: 12"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-c-kgsl-firmware-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=c-kgsl-open-readonly-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-c-kgsl-firmware-run-token\norange_gpu_watchdog_timeout_secs=12\nprelude=orange-init\nprelude_hold_seconds=2\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\nfirmware_bootstrap=ramdisk-lib-firmware\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_cpio_entry_present "$TMP_DIR/orange-gpu-c-kgsl-firmware-boot.img" lib
assert_cpio_entry_present "$TMP_DIR/orange-gpu-c-kgsl-firmware-boot.img" lib/firmware
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-c-kgsl-firmware-boot.img" lib/firmware/a630_sqe.fw $'sqe-firmware\n'
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-c-kgsl-firmware-boot.img" lib/firmware/a618_gmu.bin $'gmu-firmware\n'
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-c-kgsl-firmware-boot.img" lib/firmware/a615_zap.mdt $'zap-metadata\n'
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-c-kgsl-firmware-boot.img" lib/firmware/a615_zap.b02 $'zap-segment\n'
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-c-kgsl-firmware-boot.img" lib/firmware/ftm5_fw.ftb $'fts-firmware\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-c-kgsl-firmware-boot.img.hello-init.json" orange_gpu_mode "c-kgsl-open-readonly-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-c-kgsl-firmware-boot.img.hello-init.json" firmware_bootstrap "ramdisk-lib-firmware"
assert_json_field_equals "$TMP_DIR/orange-gpu-c-kgsl-firmware-boot.img.hello-init.json" gpu_firmware_dir "$GPU_FIRMWARE_DIR"
assert_json_field_equals "$TMP_DIR/orange-gpu-c-kgsl-firmware-boot.img.hello-init.json" success_postlude "none"
assert_json_field_equals "$TMP_DIR/orange-gpu-c-kgsl-firmware-boot.img.hello-init.json" checkpoint_hold_seconds "1"
assert_json_field_equals "$TMP_DIR/orange-gpu-c-kgsl-firmware-boot.img.hello-init.json" orange_gpu_watchdog_timeout_secs "12"

input_bootstrap_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-input-bootstrap-boot.img" \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode c-kgsl-open-readonly-smoke \
      --orange-gpu-watchdog-timeout-secs 12 \
      --reboot-target bootloader \
      --run-token orange-gpu-input-bootstrap-run-token \
      --dev-mount tmpfs \
      --log-kmsg false \
      --log-pmsg false \
      --firmware-bootstrap ramdisk-lib-firmware \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --input-bootstrap sunfish-touch-event2 \
      --input-module-dir "$INPUT_MODULE_DIR"
)"

assert_contains "$input_bootstrap_output" "Input bootstrap: sunfish-touch-event2"
assert_contains "$input_bootstrap_output" "Input module dir: $INPUT_MODULE_DIR"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-input-bootstrap-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=c-kgsl-open-readonly-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-input-bootstrap-run-token\norange_gpu_watchdog_timeout_secs=12\nprelude=orange-init\nprelude_hold_seconds=2\ndev_mount=tmpfs\nlog_kmsg=false\nlog_pmsg=false\nfirmware_bootstrap=ramdisk-lib-firmware\ninput_bootstrap=sunfish-touch-event2\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-input-bootstrap-boot.img" lib/modules/heatmap.ko $'heatmap-module\n'
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-input-bootstrap-boot.img" lib/modules/ftm5.ko $'ftm5-module\n'
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-input-bootstrap-boot.img" lib/firmware/ftm5_fw.ftb $'fts-firmware\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-input-bootstrap-boot.img.hello-init.json" input_bootstrap "sunfish-touch-event2"
assert_json_field_equals "$TMP_DIR/orange-gpu-input-bootstrap-boot.img.hello-init.json" input_module_dir "$INPUT_MODULE_DIR"

firmware_probe_only_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-firmware-probe-only-boot.img" \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode firmware-probe-only \
      --reboot-target bootloader \
      --run-token orange-gpu-firmware-probe-only-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false \
      --firmware-bootstrap ramdisk-lib-firmware \
      --firmware-dir "$GPU_FIRMWARE_DIR"
)"

assert_contains "$firmware_probe_only_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$firmware_probe_only_boot_output" "Payload contract: hello-init runs the owned userspace firmware preflight only, paints a firmware checkpoint pattern, and exits before any KGSL open"
assert_contains "$firmware_probe_only_boot_output" "GPU proof: owned userspace firmware preflight without any KGSL open"
assert_contains "$firmware_probe_only_boot_output" "Derived success postlude: none"
assert_contains "$firmware_probe_only_boot_output" "Visible checkpoint hold seconds: 1"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-firmware-probe-only-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=firmware-probe-only\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-firmware-probe-only-run-token\nprelude=orange-init\nprelude_hold_seconds=2\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\nfirmware_bootstrap=ramdisk-lib-firmware\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-firmware-probe-only-boot.img.hello-init.json" orange_gpu_mode "firmware-probe-only"
assert_json_field_equals "$TMP_DIR/orange-gpu-firmware-probe-only-boot.img.hello-init.json" firmware_bootstrap "ramdisk-lib-firmware"
assert_json_field_equals "$TMP_DIR/orange-gpu-firmware-probe-only-boot.img.hello-init.json" success_postlude "none"
assert_json_field_equals "$TMP_DIR/orange-gpu-firmware-probe-only-boot.img.hello-init.json" checkpoint_hold_seconds "1"

instance_smoke_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-instance-boot.img" \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode vulkan-instance-smoke \
      --reboot-target bootloader \
      --run-token orange-gpu-instance-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$instance_smoke_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$instance_smoke_boot_output" "Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict Vulkan instance mode from /orange-gpu"
assert_contains "$instance_smoke_boot_output" "Orange GPU mode: vulkan-instance-smoke"
assert_contains "$instance_smoke_boot_output" "GPU proof: strict Vulkan instance creation"
assert_contains "$instance_smoke_boot_output" "Prelude: orange-init"
assert_contains "$instance_smoke_boot_output" "Derived success postlude: orange-init"
assert_contains "$instance_smoke_boot_output" "Visible checkpoint hold seconds: 1"
assert_contains "$instance_smoke_boot_output" "DRI bootstrap: sunfish-card0-renderD128-kgsl3d0"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-instance-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=vulkan-instance-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-instance-run-token\nprelude=orange-init\nprelude_hold_seconds=2\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-instance-boot.img.hello-init.json" orange_gpu_mode "vulkan-instance-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-instance-boot.img.hello-init.json" success_postlude "orange-init"
assert_json_field_equals "$TMP_DIR/orange-gpu-instance-boot.img.hello-init.json" checkpoint_hold_seconds "1"
assert_json_field_equals "$TMP_DIR/orange-gpu-instance-boot.img.hello-init.json" dri_bootstrap "sunfish-card0-renderD128-kgsl3d0"

raw_vulkan_instance_smoke_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-raw-vulkan-instance-boot.img" \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode raw-vulkan-instance-smoke \
      --reboot-target bootloader \
      --run-token orange-gpu-raw-vulkan-instance-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$raw_vulkan_instance_smoke_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$raw_vulkan_instance_smoke_boot_output" "Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict raw Vulkan instance-lifecycle mode from /orange-gpu"
assert_contains "$raw_vulkan_instance_smoke_boot_output" "Orange GPU mode: raw-vulkan-instance-smoke"
assert_contains "$raw_vulkan_instance_smoke_boot_output" "GPU proof: strict raw Vulkan loader plus vkCreateInstance/vkDestroyInstance"
assert_contains "$raw_vulkan_instance_smoke_boot_output" "Prelude: orange-init"
assert_contains "$raw_vulkan_instance_smoke_boot_output" "Derived success postlude: orange-init"
assert_contains "$raw_vulkan_instance_smoke_boot_output" "Visible checkpoint hold seconds: 1"
assert_contains "$raw_vulkan_instance_smoke_boot_output" "DRI bootstrap: sunfish-card0-renderD128-kgsl3d0"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-raw-vulkan-instance-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=raw-vulkan-instance-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-raw-vulkan-instance-run-token\nprelude=orange-init\nprelude_hold_seconds=2\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-instance-boot.img.hello-init.json" orange_gpu_mode "raw-vulkan-instance-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-instance-boot.img.hello-init.json" success_postlude "orange-init"
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-instance-boot.img.hello-init.json" checkpoint_hold_seconds "1"
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-instance-boot.img.hello-init.json" dri_bootstrap "sunfish-card0-renderD128-kgsl3d0"

raw_vulkan_physical_device_count_query_no_destroy_smoke_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-no-destroy-boot.img" \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode raw-vulkan-physical-device-count-query-no-destroy-smoke \
      --reboot-target bootloader \
      --run-token orange-gpu-raw-vk-query-no-destroy-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$raw_vulkan_physical_device_count_query_no_destroy_smoke_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$raw_vulkan_physical_device_count_query_no_destroy_smoke_boot_output" "Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict raw Vulkan physical-device-count-query-no-destroy mode from /orange-gpu"
assert_contains "$raw_vulkan_physical_device_count_query_no_destroy_smoke_boot_output" "Orange GPU mode: raw-vulkan-physical-device-count-query-no-destroy-smoke"
assert_contains "$raw_vulkan_physical_device_count_query_no_destroy_smoke_boot_output" "GPU proof: strict raw Vulkan physical-device count query without explicit destroy"
assert_contains "$raw_vulkan_physical_device_count_query_no_destroy_smoke_boot_output" "Prelude: orange-init"
assert_contains "$raw_vulkan_physical_device_count_query_no_destroy_smoke_boot_output" "Derived success postlude: orange-init"
assert_contains "$raw_vulkan_physical_device_count_query_no_destroy_smoke_boot_output" "Visible checkpoint hold seconds: 1"
assert_contains "$raw_vulkan_physical_device_count_query_no_destroy_smoke_boot_output" "DRI bootstrap: sunfish-card0-renderD128-kgsl3d0"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-no-destroy-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=raw-vulkan-physical-device-count-query-no-destroy-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-raw-vk-query-no-destroy-token\nprelude=orange-init\nprelude_hold_seconds=2\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-no-destroy-boot.img.hello-init.json" orange_gpu_mode "raw-vulkan-physical-device-count-query-no-destroy-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-no-destroy-boot.img.hello-init.json" success_postlude "orange-init"
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-no-destroy-boot.img.hello-init.json" checkpoint_hold_seconds "1"
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-no-destroy-boot.img.hello-init.json" dri_bootstrap "sunfish-card0-renderD128-kgsl3d0"

raw_vulkan_physical_device_count_query_exit_smoke_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-exit-boot.img" \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode raw-vulkan-physical-device-count-query-exit-smoke \
      --reboot-target bootloader \
      --run-token orange-gpu-raw-vk-query-exit-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$raw_vulkan_physical_device_count_query_exit_smoke_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$raw_vulkan_physical_device_count_query_exit_smoke_boot_output" "Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict raw Vulkan physical-device-count-query-exit mode from /orange-gpu"
assert_contains "$raw_vulkan_physical_device_count_query_exit_smoke_boot_output" "Orange GPU mode: raw-vulkan-physical-device-count-query-exit-smoke"
assert_contains "$raw_vulkan_physical_device_count_query_exit_smoke_boot_output" "GPU proof: strict raw Vulkan physical-device count query plus immediate exit 0 before summary"
assert_contains "$raw_vulkan_physical_device_count_query_exit_smoke_boot_output" "Prelude: orange-init"
assert_contains "$raw_vulkan_physical_device_count_query_exit_smoke_boot_output" "Derived success postlude: orange-init"
assert_contains "$raw_vulkan_physical_device_count_query_exit_smoke_boot_output" "Visible checkpoint hold seconds: 1"
assert_contains "$raw_vulkan_physical_device_count_query_exit_smoke_boot_output" "DRI bootstrap: sunfish-card0-renderD128-kgsl3d0"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-exit-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=raw-vulkan-physical-device-count-query-exit-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-raw-vk-query-exit-token\nprelude=orange-init\nprelude_hold_seconds=2\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-exit-boot.img.hello-init.json" orange_gpu_mode "raw-vulkan-physical-device-count-query-exit-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-exit-boot.img.hello-init.json" success_postlude "orange-init"
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-exit-boot.img.hello-init.json" checkpoint_hold_seconds "1"
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-exit-boot.img.hello-init.json" dri_bootstrap "sunfish-card0-renderD128-kgsl3d0"

raw_vulkan_physical_device_count_query_smoke_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-boot.img" \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode raw-vulkan-physical-device-count-query-smoke \
      --reboot-target bootloader \
      --run-token orange-gpu-raw-vulkan-physical-device-count-query-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$raw_vulkan_physical_device_count_query_smoke_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$raw_vulkan_physical_device_count_query_smoke_boot_output" "Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict raw Vulkan physical-device-count-query mode from /orange-gpu"
assert_contains "$raw_vulkan_physical_device_count_query_smoke_boot_output" "Orange GPU mode: raw-vulkan-physical-device-count-query-smoke"
assert_contains "$raw_vulkan_physical_device_count_query_smoke_boot_output" "GPU proof: strict raw Vulkan physical-device count query plus explicit destroy"
assert_contains "$raw_vulkan_physical_device_count_query_smoke_boot_output" "Prelude: orange-init"
assert_contains "$raw_vulkan_physical_device_count_query_smoke_boot_output" "Derived success postlude: orange-init"
assert_contains "$raw_vulkan_physical_device_count_query_smoke_boot_output" "Visible checkpoint hold seconds: 1"
assert_contains "$raw_vulkan_physical_device_count_query_smoke_boot_output" "DRI bootstrap: sunfish-card0-renderD128-kgsl3d0"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=raw-vulkan-physical-device-count-query-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-raw-vulkan-physical-device-count-query-run-token\nprelude=orange-init\nprelude_hold_seconds=2\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-boot.img.hello-init.json" orange_gpu_mode "raw-vulkan-physical-device-count-query-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-boot.img.hello-init.json" success_postlude "orange-init"
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-boot.img.hello-init.json" checkpoint_hold_seconds "1"
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-query-boot.img.hello-init.json" dri_bootstrap "sunfish-card0-renderD128-kgsl3d0"

raw_vulkan_physical_device_count_smoke_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-boot.img" \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode raw-vulkan-physical-device-count-smoke \
      --reboot-target bootloader \
      --run-token orange-gpu-raw-vulkan-physical-device-count-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$raw_vulkan_physical_device_count_smoke_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$raw_vulkan_physical_device_count_smoke_boot_output" "Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict raw Vulkan physical-device-count mode from /orange-gpu"
assert_contains "$raw_vulkan_physical_device_count_smoke_boot_output" "Orange GPU mode: raw-vulkan-physical-device-count-smoke"
assert_contains "$raw_vulkan_physical_device_count_smoke_boot_output" "GPU proof: strict raw Vulkan physical-device enumeration count"
assert_contains "$raw_vulkan_physical_device_count_smoke_boot_output" "Prelude: orange-init"
assert_contains "$raw_vulkan_physical_device_count_smoke_boot_output" "Derived success postlude: orange-init"
assert_contains "$raw_vulkan_physical_device_count_smoke_boot_output" "Visible checkpoint hold seconds: 1"
assert_contains "$raw_vulkan_physical_device_count_smoke_boot_output" "DRI bootstrap: sunfish-card0-renderD128-kgsl3d0"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=raw-vulkan-physical-device-count-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-raw-vulkan-physical-device-count-run-token\nprelude=orange-init\nprelude_hold_seconds=2\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-boot.img.hello-init.json" orange_gpu_mode "raw-vulkan-physical-device-count-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-boot.img.hello-init.json" success_postlude "orange-init"
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-boot.img.hello-init.json" checkpoint_hold_seconds "1"
assert_json_field_equals "$TMP_DIR/orange-gpu-raw-vulkan-physical-device-count-boot.img.hello-init.json" dri_bootstrap "sunfish-card0-renderD128-kgsl3d0"

enumerate_adapters_count_smoke_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-enumerate-adapters-count-boot.img" \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode vulkan-enumerate-adapters-count-smoke \
      --reboot-target bootloader \
      --run-token orange-gpu-enumerate-adapters-count-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$enumerate_adapters_count_smoke_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$enumerate_adapters_count_smoke_boot_output" "Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict Vulkan raw adapter-enumeration-count mode from /orange-gpu"
assert_contains "$enumerate_adapters_count_smoke_boot_output" "Orange GPU mode: vulkan-enumerate-adapters-count-smoke"
assert_contains "$enumerate_adapters_count_smoke_boot_output" "GPU proof: strict Vulkan raw adapter enumeration count"
assert_contains "$enumerate_adapters_count_smoke_boot_output" "Prelude: orange-init"
assert_contains "$enumerate_adapters_count_smoke_boot_output" "Derived success postlude: orange-init"
assert_contains "$enumerate_adapters_count_smoke_boot_output" "Visible checkpoint hold seconds: 1"
assert_contains "$enumerate_adapters_count_smoke_boot_output" "DRI bootstrap: sunfish-card0-renderD128-kgsl3d0"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-enumerate-adapters-count-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=vulkan-enumerate-adapters-count-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-enumerate-adapters-count-run-token\nprelude=orange-init\nprelude_hold_seconds=2\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-enumerate-adapters-count-boot.img.hello-init.json" orange_gpu_mode "vulkan-enumerate-adapters-count-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-enumerate-adapters-count-boot.img.hello-init.json" success_postlude "orange-init"
assert_json_field_equals "$TMP_DIR/orange-gpu-enumerate-adapters-count-boot.img.hello-init.json" checkpoint_hold_seconds "1"
assert_json_field_equals "$TMP_DIR/orange-gpu-enumerate-adapters-count-boot.img.hello-init.json" dri_bootstrap "sunfish-card0-renderD128-kgsl3d0"

enumerate_adapters_smoke_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-enumerate-adapters-boot.img" \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode vulkan-enumerate-adapters-smoke \
      --reboot-target bootloader \
      --run-token orange-gpu-enumerate-adapters-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$enumerate_adapters_smoke_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$enumerate_adapters_smoke_boot_output" "Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict Vulkan adapter-enumeration mode from /orange-gpu"
assert_contains "$enumerate_adapters_smoke_boot_output" "Orange GPU mode: vulkan-enumerate-adapters-smoke"
assert_contains "$enumerate_adapters_smoke_boot_output" "GPU proof: strict Vulkan adapter enumeration"
assert_contains "$enumerate_adapters_smoke_boot_output" "Prelude: orange-init"
assert_contains "$enumerate_adapters_smoke_boot_output" "Derived success postlude: orange-init"
assert_contains "$enumerate_adapters_smoke_boot_output" "Visible checkpoint hold seconds: 1"
assert_contains "$enumerate_adapters_smoke_boot_output" "DRI bootstrap: sunfish-card0-renderD128-kgsl3d0"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-enumerate-adapters-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=vulkan-enumerate-adapters-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-enumerate-adapters-run-token\nprelude=orange-init\nprelude_hold_seconds=2\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-enumerate-adapters-boot.img.hello-init.json" orange_gpu_mode "vulkan-enumerate-adapters-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-enumerate-adapters-boot.img.hello-init.json" success_postlude "orange-init"
assert_json_field_equals "$TMP_DIR/orange-gpu-enumerate-adapters-boot.img.hello-init.json" checkpoint_hold_seconds "1"
assert_json_field_equals "$TMP_DIR/orange-gpu-enumerate-adapters-boot.img.hello-init.json" dri_bootstrap "sunfish-card0-renderD128-kgsl3d0"

adapter_smoke_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-adapter-boot.img" \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode vulkan-adapter-smoke \
      --reboot-target bootloader \
      --run-token orange-gpu-adapter-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$adapter_smoke_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$adapter_smoke_boot_output" "Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict Vulkan adapter mode from /orange-gpu"
assert_contains "$adapter_smoke_boot_output" "Orange GPU mode: vulkan-adapter-smoke"
assert_contains "$adapter_smoke_boot_output" "GPU proof: strict Vulkan adapter selection"
assert_contains "$adapter_smoke_boot_output" "Prelude: orange-init"
assert_contains "$adapter_smoke_boot_output" "Derived success postlude: orange-init"
assert_contains "$adapter_smoke_boot_output" "Visible checkpoint hold seconds: 1"
assert_contains "$adapter_smoke_boot_output" "DRI bootstrap: sunfish-card0-renderD128-kgsl3d0"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-adapter-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=vulkan-adapter-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-adapter-run-token\nprelude=orange-init\nprelude_hold_seconds=2\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-adapter-boot.img.hello-init.json" orange_gpu_mode "vulkan-adapter-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-adapter-boot.img.hello-init.json" success_postlude "orange-init"
assert_json_field_equals "$TMP_DIR/orange-gpu-adapter-boot.img.hello-init.json" checkpoint_hold_seconds "1"
assert_json_field_equals "$TMP_DIR/orange-gpu-adapter-boot.img.hello-init.json" dri_bootstrap "sunfish-card0-renderD128-kgsl3d0"

device_request_smoke_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-device-request-boot.img" \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode vulkan-device-request-smoke \
      --reboot-target bootloader \
      --run-token orange-gpu-device-request-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$device_request_smoke_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$device_request_smoke_boot_output" "Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict Vulkan device-request mode from /orange-gpu"
assert_contains "$device_request_smoke_boot_output" "Orange GPU mode: vulkan-device-request-smoke"
assert_contains "$device_request_smoke_boot_output" "GPU proof: strict Vulkan device request"
assert_contains "$device_request_smoke_boot_output" "Prelude: orange-init"
assert_contains "$device_request_smoke_boot_output" "Derived success postlude: orange-init"
assert_contains "$device_request_smoke_boot_output" "Visible checkpoint hold seconds: 1"
assert_contains "$device_request_smoke_boot_output" "DRI bootstrap: sunfish-card0-renderD128-kgsl3d0"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-device-request-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=vulkan-device-request-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-device-request-run-token\nprelude=orange-init\nprelude_hold_seconds=2\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-device-request-boot.img.hello-init.json" orange_gpu_mode "vulkan-device-request-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-device-request-boot.img.hello-init.json" success_postlude "orange-init"
assert_json_field_equals "$TMP_DIR/orange-gpu-device-request-boot.img.hello-init.json" checkpoint_hold_seconds "1"
assert_json_field_equals "$TMP_DIR/orange-gpu-device-request-boot.img.hello-init.json" dri_bootstrap "sunfish-card0-renderD128-kgsl3d0"

device_smoke_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-device-boot.img" \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode vulkan-device-smoke \
      --reboot-target bootloader \
      --run-token orange-gpu-device-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$device_smoke_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$device_smoke_boot_output" "Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict Vulkan device/buffer mode from /orange-gpu"
assert_contains "$device_smoke_boot_output" "Orange GPU mode: vulkan-device-smoke"
assert_contains "$device_smoke_boot_output" "GPU proof: strict Vulkan buffer renderer bring-up"
assert_contains "$device_smoke_boot_output" "Prelude: orange-init"
assert_contains "$device_smoke_boot_output" "Derived success postlude: orange-init"
assert_contains "$device_smoke_boot_output" "Visible checkpoint hold seconds: 1"
assert_contains "$device_smoke_boot_output" "DRI bootstrap: sunfish-card0-renderD128-kgsl3d0"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-device-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=vulkan-device-smoke\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-device-run-token\nprelude=orange-init\nprelude_hold_seconds=2\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-device-boot.img.hello-init.json" orange_gpu_mode "vulkan-device-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-device-boot.img.hello-init.json" success_postlude "orange-init"
assert_json_field_equals "$TMP_DIR/orange-gpu-device-boot.img.hello-init.json" checkpoint_hold_seconds "1"
assert_json_field_equals "$TMP_DIR/orange-gpu-device-boot.img.hello-init.json" dri_bootstrap "sunfish-card0-renderD128-kgsl3d0"

offscreen_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-offscreen-boot.img" \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode vulkan-offscreen \
      --reboot-target bootloader \
      --run-token orange-gpu-offscreen-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false
)"

assert_contains "$offscreen_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$offscreen_boot_output" "Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in strict Vulkan offscreen mode from /orange-gpu"
assert_contains "$offscreen_boot_output" "Orange GPU mode: vulkan-offscreen"
assert_contains "$offscreen_boot_output" "GPU proof: strict Vulkan offscreen render"
assert_contains "$offscreen_boot_output" "Prelude: orange-init"
assert_contains "$offscreen_boot_output" "Derived success postlude: orange-init"
assert_contains "$offscreen_boot_output" "Visible checkpoint hold seconds: 1"
assert_contains "$offscreen_boot_output" "DRI bootstrap: sunfish-card0-renderD128-kgsl3d0"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-offscreen-boot.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=vulkan-offscreen\nhold_seconds=7\nreboot_target=bootloader\nrun_token=orange-gpu-offscreen-run-token\nprelude=orange-init\nprelude_hold_seconds=2\ndev_mount=tmpfs\nmount_sys=false\nlog_kmsg=false\nlog_pmsg=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-offscreen-boot.img.hello-init.json" orange_gpu_mode "vulkan-offscreen"
assert_json_field_equals "$TMP_DIR/orange-gpu-offscreen-boot.img.hello-init.json" success_postlude "orange-init"
assert_json_field_equals "$TMP_DIR/orange-gpu-offscreen-boot.img.hello-init.json" checkpoint_hold_seconds "1"
assert_json_field_equals "$TMP_DIR/orange-gpu-offscreen-boot.img.hello-init.json" dri_bootstrap "sunfish-card0-renderD128-kgsl3d0"

rust_bridge_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-boot.img" \
      --hello-init-mode rust-bridge \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode gpu-render \
      --reboot-target bootloader \
      --run-token orange-gpu-rust-bridge-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false \
      --orange-gpu-metadata-stage-breadcrumb true
)"

assert_contains "$rust_bridge_boot_output" "Owned userspace mode: orange-gpu"
assert_contains "$rust_bridge_boot_output" "Hello-init mode: rust-bridge"
assert_contains "$rust_bridge_boot_output" "System init mutation: replace system/bin/init with rust no_std PID1 shim"
assert_contains "$rust_bridge_boot_output" "Rust shim path: /system/bin/init"
assert_contains "$rust_bridge_boot_output" "Rust shim binary: $HELLO_INIT_RUST_EXEC_SHIM_OUTPUT"
assert_contains "$rust_bridge_boot_output" "Rust child path: /hello-init-child"
assert_contains "$rust_bridge_boot_output" "Rust child binary: $HELLO_INIT_RUST_CHILD_OUTPUT"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-boot.img" system/bin/init $'#!/system/bin/sh\n# shadow-owned-init-role:hello-init\n# shadow-owned-init-impl:rust-static\n# shadow-owned-init-config:/shadow-init.cfg\necho hello-init-rust-shim-exec\n'
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-boot.img" hello-init-child $'#!/system/bin/sh\n# shadow-owned-init-role:hello-init\n# shadow-owned-init-impl:rust-static\n# shadow-owned-init-config:/shadow-init.cfg\necho hello-init-rust-child\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-boot.img.hello-init.json" hello_init_mode "rust-bridge"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-boot.img.hello-init.json" hello_init_impl "rust-bridge"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-boot.img.hello-init.json" hello_init_child_path "/hello-init-child"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-boot.img.hello-init.json" hello_init_child_profile "hello"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-boot.img.hello-init.json" hello_init_shim_mode "exec"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-boot.img.hello-init.json" metadata_probe_stage_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-run-token/probe-stage.txt"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-boot.img.hello-init.json" metadata_probe_report_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-run-token/probe-report.txt"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-boot.img.hello-init.json" metadata_probe_summary_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-run-token/probe-summary.json"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-boot.img.hello-init.json" metadata_probe_fingerprint_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-run-token/probe-fingerprint.txt"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-boot.img.hello-init.json" metadata_probe_timeout_class_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-run-token/probe-timeout-class.txt"

rust_bridge_exec_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --rust-shim-mode exec \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-exec-boot.img" \
      --hello-init-mode rust-bridge \
      --hold-secs 7 \
      --prelude orange-init \
      --prelude-hold-secs 2 \
      --orange-gpu-mode gpu-render \
      --reboot-target bootloader \
      --run-token orange-gpu-rust-bridge-exec-run-token \
      --dev-mount tmpfs \
      --mount-sys false \
      --log-kmsg false \
      --log-pmsg false \
      --orange-gpu-metadata-stage-breadcrumb true
)"

assert_contains "$rust_bridge_exec_boot_output" "Hello-init mode: rust-bridge"
assert_contains "$rust_bridge_exec_boot_output" "Rust shim mode: exec"
assert_contains "$rust_bridge_exec_boot_output" "Rust shim binary: $HELLO_INIT_RUST_EXEC_SHIM_OUTPUT"
assert_contains "$rust_bridge_exec_boot_output" "Rust child profile: hello"
assert_contains "$rust_bridge_exec_boot_output" "Rust child path: /hello-init-child"
assert_contains "$rust_bridge_exec_boot_output" "Rust child binary: $HELLO_INIT_RUST_CHILD_OUTPUT"
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-exec-boot.img" system/bin/init $'#!/system/bin/sh\n# shadow-owned-init-role:hello-init\n# shadow-owned-init-impl:rust-static\n# shadow-owned-init-config:/shadow-init.cfg\necho hello-init-rust-shim-exec\n'
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-exec-boot.img" hello-init-child $'#!/system/bin/sh\n# shadow-owned-init-role:hello-init\n# shadow-owned-init-impl:rust-static\n# shadow-owned-init-config:/shadow-init.cfg\necho hello-init-rust-child\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-exec-boot.img.hello-init.json" hello_init_mode "rust-bridge"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-exec-boot.img.hello-init.json" hello_init_impl "rust-bridge"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-exec-boot.img.hello-init.json" hello_init_child_path "/hello-init-child"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-exec-boot.img.hello-init.json" hello_init_child_profile "hello"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-exec-boot.img.hello-init.json" hello_init_shim_mode "exec"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-exec-boot.img.hello-init.json" metadata_probe_fingerprint_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-exec-run-token/probe-fingerprint.txt"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-exec-boot.img.hello-init.json" metadata_probe_timeout_class_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-exec-run-token/probe-timeout-class.txt"

rust_bridge_raw_kgsl_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-raw-kgsl.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode raw-kgsl-getproperties-smoke \
      --run-token orange-gpu-rust-bridge-raw-kgsl-run-token \
      --orange-gpu-metadata-stage-breadcrumb true
)"

assert_contains "$rust_bridge_raw_kgsl_boot_output" "Orange GPU mode: raw-kgsl-getproperties-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-raw-kgsl.img.hello-init.json" orange_gpu_mode "raw-kgsl-getproperties-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-raw-kgsl.img.hello-init.json" metadata_probe_fingerprint_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-raw-kgsl-run-token/probe-fingerprint.txt"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-raw-kgsl.img.hello-init.json" metadata_probe_timeout_class_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-raw-kgsl-run-token/probe-timeout-class.txt"

rust_bridge_c_kgsl_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-c-kgsl.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode c-kgsl-open-readonly-smoke \
      --run-token orange-gpu-rust-bridge-c-kgsl-run-token \
      --orange-gpu-metadata-stage-breadcrumb true \
      --firmware-bootstrap ramdisk-lib-firmware
)"

assert_contains "$rust_bridge_c_kgsl_boot_output" "Orange GPU mode: c-kgsl-open-readonly-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-c-kgsl.img.hello-init.json" orange_gpu_mode "c-kgsl-open-readonly-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-c-kgsl.img.hello-init.json" metadata_probe_timeout_class_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-c-kgsl-run-token/probe-timeout-class.txt"

rust_bridge_c_kgsl_pid1_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-c-kgsl-pid1.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode c-kgsl-open-readonly-pid1-smoke \
      --run-token orange-gpu-rust-bridge-c-kgsl-pid1-run-token \
      --orange-gpu-metadata-stage-breadcrumb true \
      --firmware-bootstrap ramdisk-lib-firmware
)"

assert_contains "$rust_bridge_c_kgsl_pid1_boot_output" "Orange GPU mode: c-kgsl-open-readonly-pid1-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-c-kgsl-pid1.img.hello-init.json" orange_gpu_mode "c-kgsl-open-readonly-pid1-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-c-kgsl-pid1.img.hello-init.json" metadata_probe_timeout_class_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-c-kgsl-pid1-run-token/probe-timeout-class.txt"

camera_hal_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/camera-hal-link-probe.img" \
      --orange-gpu-mode camera-hal-link-probe \
      --run-token camera-hal-link-probe-run-token \
      --dev-mount tmpfs \
      --orange-gpu-metadata-stage-breadcrumb true \
      --camera-linker-capsule "$CAMERA_LINKER_CAPSULE_DIR" \
      --camera-hal-bionic-probe "$CAMERA_HAL_BIONIC_PROBE_BINARY"
)"

assert_contains "$camera_hal_boot_output" "Orange GPU mode: camera-hal-link-probe"
assert_contains "$camera_hal_boot_output" "Payload contract: rust hello-init directly probes /vendor/lib64/hw/camera.sm6150.so"
assert_contains "$camera_hal_boot_output" "Camera linker capsule dir: $CAMERA_LINKER_CAPSULE_DIR"
assert_contains "$camera_hal_boot_output" "Camera HAL bionic probe: $CAMERA_HAL_BIONIC_PROBE_BINARY"
assert_contains "$camera_hal_boot_output" "Camera HAL camera id: 0"
assert_contains "$camera_hal_boot_output" "Camera HAL call open: false"
assert_cpio_entry_equals "$TMP_DIR/camera-hal-link-probe.img" shadow-init.cfg $'# Generated by pixel_boot_build_orange_gpu.sh\npayload=orange-gpu\norange_gpu_mode=camera-hal-link-probe\nhold_seconds=3\nreboot_target=bootloader\nrun_token=camera-hal-link-probe-run-token\norange_gpu_metadata_stage_breadcrumb=true\ndev_mount=tmpfs\ncamera_hal_camera_id=0\ncamera_hal_call_open=false\ndri_bootstrap=sunfish-card0-renderD128-kgsl3d0\n'
assert_cpio_entry_equals "$TMP_DIR/camera-hal-link-probe.img" orange-gpu/camera-hal-bionic-probe $'ELF_CAMERA_HAL_BIONIC_PROBE\n'
assert_cpio_entry_equals "$TMP_DIR/camera-hal-link-probe.img" vendor/lib64/hw/camera.sm6150.so $'ELF_CAMERA_HAL_SM6150\n'
assert_cpio_entry_equals "$TMP_DIR/camera-hal-link-probe.img" system/lib64/libcamera_metadata.so $'ELF_LIBCAMERA_METADATA\n'
assert_cpio_entry_equals "$TMP_DIR/camera-hal-link-probe.img" apex/com.android.runtime/bin/linker64 $'ELF_ANDROID_RUNTIME_LINKER64\n'
assert_cpio_entry_equals "$TMP_DIR/camera-hal-link-probe.img" linkerconfig/ld.config.txt $'dir.system = /system\n'
assert_json_field_equals "$TMP_DIR/camera-hal-link-probe.img.hello-init.json" orange_gpu_mode "camera-hal-link-probe"
assert_json_field_equals "$TMP_DIR/camera-hal-link-probe.img.hello-init.json" metadata_probe_summary_path "/metadata/shadow-hello-init/by-token/camera-hal-link-probe-run-token/probe-summary.json"

camera_hal_default_boot_output="$(
  env PATH="$MOCK_NIX_BIN:$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/camera-hal-link-probe-default.img" \
      --orange-gpu-mode camera-hal-link-probe \
      --run-token camera-hal-link-probe-default-token \
      --dev-mount tmpfs \
      --orange-gpu-metadata-stage-breadcrumb true
)"

assert_contains "$camera_hal_default_boot_output" "Hello-init mode: direct"
assert_contains "$camera_hal_default_boot_output" "Orange GPU mode: camera-hal-link-probe"
assert_cpio_entry_symlink_target "$TMP_DIR/camera-hal-link-probe-default.img" init "/system/bin/init"
assert_cpio_entry_equals "$TMP_DIR/camera-hal-link-probe-default.img" system/bin/init $'#!/system/bin/sh\n# shadow-owned-init-role:hello-init\n# shadow-owned-init-impl:rust-static\n# shadow-owned-init-config:/shadow-init.cfg\necho hello-init-rust-child\n'
assert_json_field_equals "$TMP_DIR/camera-hal-link-probe-default.img.hello-init.json" orange_gpu_mode "camera-hal-link-probe"
assert_json_field_equals "$TMP_DIR/camera-hal-link-probe-default.img.hello-init.json" metadata_probe_summary_path "/metadata/shadow-hello-init/by-token/camera-hal-link-probe-default-token/probe-summary.json"

rust_bridge_parent_probe_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-parent-probe.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode gpu-render \
      --orange-gpu-parent-probe-attempts 2 \
      --orange-gpu-parent-probe-interval-secs 3 \
      --run-token orange-gpu-rust-bridge-parent-probe-run-token \
      --orange-gpu-metadata-stage-breadcrumb true
)"

assert_contains "$rust_bridge_parent_probe_boot_output" "Orange GPU parent probe attempts: 2"
assert_contains "$rust_bridge_parent_probe_boot_output" "Orange GPU parent probe interval seconds: 3"
assert_contains "$rust_bridge_parent_probe_boot_output" "Parent readiness probe scene: raw-vulkan-physical-device-count-query-exit-smoke"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-parent-probe.img.hello-init.json" orange_gpu_parent_probe_attempts "2"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-parent-probe.img.hello-init.json" orange_gpu_parent_probe_interval_secs "3"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-parent-probe.img.hello-init.json" metadata_probe_fingerprint_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-parent-probe-run-token/probe-fingerprint.txt"

rust_bridge_loop_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-loop.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode orange-gpu-loop \
      --orange-gpu-firmware-helper true \
      --orange-gpu-metadata-stage-breadcrumb true \
      --firmware-bootstrap ramdisk-lib-firmware \
      --run-token orange-gpu-rust-bridge-loop-run-token \
      --hold-secs 3 \
      --mount-sys true
)"

assert_contains "$rust_bridge_loop_boot_output" "Orange GPU mode: orange-gpu-loop"
assert_contains "$rust_bridge_loop_boot_output" "Payload contract: hello-init executes the staged shadow-gpu-smoke bundle in repeated Vulkan render/present loop mode"
assert_contains "$rust_bridge_loop_boot_output" "GPU proof: repeated Vulkan render/present updates with durable loop summary evidence"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-loop.img.hello-init.json" orange_gpu_mode "orange-gpu-loop"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-loop.img.hello-init.json" orange_gpu_scene "orange-gpu-loop"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-loop.img.hello-init.json" metadata_probe_summary_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-loop-run-token/probe-summary.json"

rust_bridge_compositor_scene_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_SHADOW_SESSION_BIN="$SHADOW_SESSION_OUTPUT" \
    PIXEL_SHADOW_COMPOSITOR_GUEST_BIN="$SHADOW_COMPOSITOR_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-compositor-scene.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode compositor-scene \
      --orange-gpu-firmware-helper true \
      --orange-gpu-metadata-stage-breadcrumb true \
      --firmware-bootstrap ramdisk-lib-firmware \
      --run-token orange-gpu-rust-bridge-compositor-scene-run-token \
      --hold-secs 9 \
      --mount-sys true
)"

assert_contains "$rust_bridge_compositor_scene_boot_output" "Orange GPU mode: compositor-scene"
assert_contains "$rust_bridge_compositor_scene_boot_output" "Payload contract: hello-init launches /orange-gpu/shadow-session in shell-only compositor mode"
assert_contains "$rust_bridge_compositor_scene_boot_output" "GPU proof: compositor-owned shell home frame captured durably through the Rust boot seam"
assert_contains "$rust_bridge_compositor_scene_boot_output" "Metadata compositor frame path: /metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-compositor-scene-run-token/compositor-frame.ppm"
assert_cpio_entry_present "$TMP_DIR/orange-gpu-rust-bridge-compositor-scene.img" orange-gpu/shadow-session
assert_cpio_entry_present "$TMP_DIR/orange-gpu-rust-bridge-compositor-scene.img" orange-gpu/shadow-compositor-guest
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-compositor-scene.img" orange-gpu/shadow-shell-dummy-client $'#!/system/bin/sh\nexit 0\n'
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-compositor-scene.img" orange-gpu/compositor-scene-startup.json $'{\n  "schemaVersion": 1,\n  "startup": {\n    "mode": "shell"\n  },\n  "client": {\n    "appClientPath": "/orange-gpu/shadow-shell-dummy-client",\n    "runtimeDir": "/shadow-runtime",\n    "lingerMs": 500\n  },\n  "compositor": {\n    "transport": "direct",\n    "enableDrm": true,\n    "exitOnFirstFrame": true,\n    "frameCapture": {\n      "mode": "first-frame",\n      "artifactPath": "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-compositor-scene-run-token/compositor-frame.ppm",\n      "checksum": true\n    }\n  }\n}\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-compositor-scene.img.hello-init.json" orange_gpu_mode "compositor-scene"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-compositor-scene.img.hello-init.json" metadata_compositor_frame_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-compositor-scene-run-token/compositor-frame.ppm"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-compositor-scene.img.hello-init.json" metadata_probe_summary_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-compositor-scene-run-token/probe-summary.json"

rust_bridge_app_direct_present_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_BUNDLE_DIR="$APP_DIRECT_PRESENT_BUNDLE_DIR" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_LAUNCHER_BIN="$APP_DIRECT_PRESENT_LAUNCHER_OUTPUT" \
    PIXEL_SHADOW_SESSION_BIN="$SHADOW_SESSION_OUTPUT" \
    PIXEL_SHADOW_COMPOSITOR_GUEST_BIN="$SHADOW_COMPOSITOR_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode app-direct-present \
      --orange-gpu-firmware-helper true \
      --orange-gpu-metadata-stage-breadcrumb true \
      --firmware-bootstrap ramdisk-lib-firmware \
      --run-token orange-gpu-rust-bridge-app-direct-present-run-token \
      --hold-secs 9 \
      --mount-sys true
)"

assert_contains "$rust_bridge_app_direct_present_boot_output" "Orange GPU mode: app-direct-present"
assert_contains "$rust_bridge_app_direct_present_boot_output" "Payload contract: hello-init launches /orange-gpu/shadow-session in app-only direct-present mode for rust-demo"
assert_contains "$rust_bridge_app_direct_present_boot_output" "GPU proof: app-owned rust-demo surface imported and presented with no shell through the Rust boot seam"
assert_contains "$rust_bridge_app_direct_present_boot_output" "Metadata compositor frame path: /metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-app-direct-present-run-token/compositor-frame.ppm"
assert_contains "$rust_bridge_app_direct_present_boot_output" "GPU bundle archive path: /orange-gpu.tar.xz"
assert_cpio_entry_present "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img" orange-gpu.tar.xz
assert_cpio_entry_absent "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img" orange-gpu/shadow-session
assert_cpio_tar_xz_entry_absent "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img" orange-gpu.tar.xz shadow-gpu-smoke
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img" orange-gpu.tar.xz shadow-session
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img" orange-gpu.tar.xz shadow-compositor-guest
assert_cpio_tar_xz_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img" orange-gpu.tar.xz app-direct-present/run-shadow-rust-demo $'MOCK_AARCH64_STATIC_APP_DIRECT_PRESENT_LAUNCHER\nshadow-app-direct-present-launcher-role:static-loader-exec\n'
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img" orange-gpu.tar.xz app-direct-present/shadow-rust-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img" orange-gpu.tar.xz app-direct-present/lib/ld-linux-aarch64.so.1
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img" orange-gpu.tar.xz app-direct-present/lib/libc.so.6
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img" orange-gpu.tar.xz app-direct-present/lib/libm.so.6
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img" orange-gpu.tar.xz app-direct-present/lib/libgcc_s.so.1
assert_cpio_tar_xz_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img" orange-gpu.tar.xz app-direct-present-startup.json $'{\n  "schemaVersion": 1,\n  "startup": {\n    "mode": "app",\n    "startAppId": "rust-demo"\n  },\n  "client": {\n    "appClientPath": "/orange-gpu/app-direct-present/run-shadow-rust-demo",\n    "runtimeDir": "/shadow-runtime",\n    "envAssignments": [\n      {\n        "key": "SHADOW_RUNTIME_CAMERA_ALLOW_MOCK",\n        "value": "1"\n      }\n    ],\n    "lingerMs": 500\n  },\n  "compositor": {\n    "transport": "direct",\n    "enableDrm": true,\n    "exitOnFirstFrame": true,\n    "frameCapture": {\n      "mode": "first-frame",\n      "artifactPath": "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-app-direct-present-run-token/compositor-frame.ppm",\n      "checksum": true\n    }\n  }\n}\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img.hello-init.json" orange_gpu_mode "app-direct-present"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img.hello-init.json" metadata_compositor_frame_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-app-direct-present-run-token/compositor-frame.ppm"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img.hello-init.json" metadata_probe_summary_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-app-direct-present-run-token/probe-summary.json"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img.hello-init.json" app_direct_present_app_id rust-demo
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img.hello-init.json" app_direct_present_client_kind rust
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-app-direct-present.img.hello-init.json" gpu_bundle_archive_path /orange-gpu.tar.xz

ts_app_direct_present_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_APP_ID=counter \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_BUNDLE_DIR="$TS_APP_DIRECT_PRESENT_BUNDLE_DIR" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_LAUNCHER_BIN="$APP_DIRECT_PRESENT_LAUNCHER_OUTPUT" \
    PIXEL_SHADOW_SESSION_BIN="$SHADOW_SESSION_OUTPUT" \
    PIXEL_SHADOW_COMPOSITOR_GUEST_BIN="$SHADOW_COMPOSITOR_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode app-direct-present \
      --orange-gpu-firmware-helper true \
      --orange-gpu-metadata-stage-breadcrumb true \
      --firmware-bootstrap ramdisk-lib-firmware \
      --run-token orange-gpu-rust-bridge-ts-app-direct-present-run-token \
      --hold-secs 9 \
      --mount-sys true
)"

assert_contains "$ts_app_direct_present_boot_output" "Orange GPU mode: app-direct-present"
assert_contains "$ts_app_direct_present_boot_output" "Payload contract: hello-init launches /orange-gpu/shadow-session in app-only direct-present mode for counter"
assert_contains "$ts_app_direct_present_boot_output" "GPU proof: app-owned counter surface imported and presented with no shell through the Rust boot seam"
assert_contains "$ts_app_direct_present_boot_output" "App direct present id: counter"
assert_contains "$ts_app_direct_present_boot_output" "App direct present client kind: typescript"
assert_contains "$ts_app_direct_present_boot_output" "App TypeScript renderer: gpu"
assert_contains "$ts_app_direct_present_boot_output" "GPU bundle archive path: /orange-gpu.tar.xz"
assert_contains "$ts_app_direct_present_boot_output" "App runtime bundle env: SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH"
assert_cpio_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img" orange-gpu.tar.xz
assert_cpio_entry_absent "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img" orange-gpu/app-direct-present/run-shadow-blitz-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img" orange-gpu.tar.xz app-direct-present/run-shadow-blitz-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img" orange-gpu.tar.xz app-direct-present/shadow-blitz-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img" orange-gpu.tar.xz app-direct-present/shadow-system
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img" orange-gpu.tar.xz app-direct-present/runtime-app-counter-bundle.js
assert_cpio_tar_xz_entry_absent "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img" orange-gpu.tar.xz shadow-gpu-smoke
assert_cpio_tar_xz_entry_absent "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img" orange-gpu.tar.xz app-direct-present/lib/ld-linux-aarch64.so.1
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img" orange-gpu.tar.xz lib/ld-linux-aarch64.so.1
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img" orange-gpu.tar.xz lib/libc.so.6
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img" orange-gpu.tar.xz lib/libm.so.6
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img" orange-gpu.tar.xz lib/libgcc_s.so.1
assert_cpio_tar_xz_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img" orange-gpu.tar.xz app-direct-present-startup.json $'{\n  "schemaVersion": 1,\n  "startup": {\n    "mode": "app",\n    "startAppId": "counter"\n  },\n  "client": {\n    "appClientPath": "/orange-gpu/app-direct-present/run-shadow-blitz-demo",\n    "runtimeDir": "/shadow-runtime",\n    "systemBinaryPath": "/orange-gpu/app-direct-present/shadow-system",\n    "envAssignments": [\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_BINARY_PATH",\n        "value": "/orange-gpu/app-direct-present/shadow-blitz-demo"\n      },\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_LOADER_PATH",\n        "value": "/orange-gpu/lib/ld-linux-aarch64.so.1"\n      },\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_LIBRARY_PATH",\n        "value": "/orange-gpu/lib"\n      },\n      {\n        "key": "SHADOW_SYSTEM_STAGE_LOADER_PATH",\n        "value": "/orange-gpu/lib/ld-linux-aarch64.so.1"\n      },\n      {\n        "key": "SHADOW_SYSTEM_STAGE_LIBRARY_PATH",\n        "value": "/orange-gpu/lib"\n      }\n    ],\n    "lingerMs": 500\n  },\n  "compositor": {\n    "transport": "direct",\n    "enableDrm": true,\n    "exitOnFirstFrame": true,\n    "frameCapture": {\n      "mode": "first-frame",\n      "artifactPath": "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-ts-app-direct-present-run-token/compositor-frame.ppm",\n      "checksum": true\n    }\n  }\n}\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img.hello-init.json" orange_gpu_mode "app-direct-present"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img.hello-init.json" app_direct_present_app_id counter
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img.hello-init.json" app_direct_present_client_kind typescript
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img.hello-init.json" app_direct_present_typescript_renderer gpu
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img.hello-init.json" gpu_bundle_archive_path /orange-gpu.tar.xz
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img.hello-init.json" app_direct_present_runtime_bundle_env SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-ts-app-direct-present.img.hello-init.json" app_direct_present_runtime_bundle_path /orange-gpu/app-direct-present/runtime-app-counter-bundle.js

shell_session_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_ORANGE_GPU_SHELL_START_APP_ID=counter \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_BUNDLE_DIR="$TS_APP_DIRECT_PRESENT_BUNDLE_DIR" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_LAUNCHER_BIN="$APP_DIRECT_PRESENT_LAUNCHER_OUTPUT" \
    PIXEL_SHADOW_SESSION_BIN="$SHADOW_SESSION_OUTPUT" \
    PIXEL_SHADOW_COMPOSITOR_GUEST_DYNAMIC_BIN="$SHADOW_COMPOSITOR_DYNAMIC_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode shell-session \
      --orange-gpu-firmware-helper true \
      --orange-gpu-metadata-stage-breadcrumb true \
      --firmware-bootstrap ramdisk-lib-firmware \
      --run-token orange-gpu-rust-bridge-shell-session-run-token \
      --hold-secs 9 \
      --mount-sys true
)"

assert_contains "$shell_session_boot_output" "Orange GPU mode: shell-session"
assert_contains "$shell_session_boot_output" "Payload contract: hello-init launches /orange-gpu/shadow-session in shell-session mode, starts counter from the shell"
assert_contains "$shell_session_boot_output" "GPU proof: shell-owned counter app launch frame captured durably through the Rust boot seam"
assert_contains "$shell_session_boot_output" "Compositor startup config path: /orange-gpu/shell-session-startup.json"
assert_contains "$shell_session_boot_output" "Shell session start app id: counter"
assert_contains "$shell_session_boot_output" "App direct present client kind: typescript"
assert_contains "$shell_session_boot_output" "App runtime bundle env: SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH"
assert_contains "$shell_session_boot_output" "GPU bundle archive path: /orange-gpu.tar.xz"
assert_cpio_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img" orange-gpu.tar.xz
assert_cpio_entry_absent "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img" orange-gpu/shadow-session
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img" orange-gpu.tar.xz shadow-session
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img" orange-gpu.tar.xz shadow-compositor-guest
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img" orange-gpu.tar.xz app-direct-present/run-shadow-blitz-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img" orange-gpu.tar.xz app-direct-present/shadow-blitz-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img" orange-gpu.tar.xz app-direct-present/shadow-system
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img" orange-gpu.tar.xz app-direct-present/runtime-app-counter-bundle.js
assert_cpio_tar_xz_entry_absent "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img" orange-gpu.tar.xz shadow-gpu-smoke
assert_cpio_tar_xz_entry_absent "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img" orange-gpu.tar.xz app-direct-present/lib/ld-linux-aarch64.so.1
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img" orange-gpu.tar.xz lib/ld-linux-aarch64.so.1
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img" orange-gpu.tar.xz lib/libc.so.6
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img" orange-gpu.tar.xz lib/libm.so.6
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img" orange-gpu.tar.xz lib/libgcc_s.so.1
assert_cpio_tar_xz_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img" orange-gpu.tar.xz shell-session-startup.json $'{\n  "schemaVersion": 1,\n  "startup": {\n    "mode": "shell",\n    "shellStartAppId": "counter"\n  },\n  "client": {\n    "appClientPath": "/orange-gpu/app-direct-present/run-shadow-blitz-demo",\n    "runtimeDir": "/shadow-runtime",\n    "systemBinaryPath": "/orange-gpu/app-direct-present/shadow-system",\n    "envAssignments": [\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_BINARY_PATH",\n        "value": "/orange-gpu/app-direct-present/shadow-blitz-demo"\n      },\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_LOADER_PATH",\n        "value": "/orange-gpu/lib/ld-linux-aarch64.so.1"\n      },\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_LIBRARY_PATH",\n        "value": "/orange-gpu/lib"\n      },\n      {\n        "key": "SHADOW_SYSTEM_STAGE_LOADER_PATH",\n        "value": "/orange-gpu/lib/ld-linux-aarch64.so.1"\n      },\n      {\n        "key": "SHADOW_SYSTEM_STAGE_LIBRARY_PATH",\n        "value": "/orange-gpu/lib"\n      }\n    ],\n    "lingerMs": 500\n  },\n  "compositor": {\n    "transport": "direct",\n    "enableDrm": true,\n    "gpuShell": true,\n    "strictGpuResident": true,\n    "dmabufGlobalEnabled": false,\n    "dmabufFeedbackEnabled": true,\n    "exitOnFirstFrame": true,\n    "frameCapture": {\n      "mode": "every-frame",\n      "artifactPath": "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-shell-session-run-token/compositor-frame.ppm",\n      "checksum": true\n    }\n  }\n}\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img.hello-init.json" orange_gpu_mode "shell-session"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img.hello-init.json" shell_session_start_app_id counter
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img.hello-init.json" app_direct_present_app_id counter
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img.hello-init.json" app_direct_present_client_kind typescript
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img.hello-init.json" app_direct_present_typescript_renderer gpu
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img.hello-init.json" gpu_bundle_archive_path /orange-gpu.tar.xz
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img.hello-init.json" app_direct_present_runtime_bundle_env SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img.hello-init.json" app_direct_present_runtime_bundle_path /orange-gpu/app-direct-present/runtime-app-counter-bundle.js
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session.img.hello-init.json" metadata_compositor_frame_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-shell-session-run-token/compositor-frame.ppm"

shell_session_shadow_logical_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_ORANGE_GPU_SHELL_START_APP_ID=counter \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_BUNDLE_DIR="$TS_APP_DIRECT_PRESENT_BUNDLE_DIR" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_LAUNCHER_BIN="$APP_DIRECT_PRESENT_LAUNCHER_OUTPUT" \
    PIXEL_SHADOW_SESSION_BIN="$SHADOW_SESSION_OUTPUT" \
    PIXEL_SHADOW_COMPOSITOR_GUEST_DYNAMIC_BIN="$SHADOW_COMPOSITOR_DYNAMIC_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-shell-session-shadow-logical.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode shell-session \
      --orange-gpu-bundle-archive-source shadow-logical-partition \
      --orange-gpu-firmware-helper true \
      --orange-gpu-metadata-stage-breadcrumb true \
      --firmware-bootstrap ramdisk-lib-firmware \
      --run-token orange-gpu-rust-bridge-shell-session-shadow-logical-run-token \
      --hold-secs 9 \
      --mount-sys true
)"

assert_contains "$shell_session_shadow_logical_boot_output" "GPU bundle archive source: shadow-logical-partition"
assert_contains "$shell_session_shadow_logical_boot_output" "GPU bundle archive path: /shadow-payload/extra-payloads/orange-gpu.tar.xz"
assert_contains "$shell_session_shadow_logical_boot_output" "GPU bundle external archive: $TMP_DIR/orange-gpu-rust-bridge-shell-session-shadow-logical.img.orange-gpu.tar.xz"
assert_contains "$shell_session_shadow_logical_boot_output" "Metadata payload root: /shadow-payload"
assert_contains "$shell_session_shadow_logical_boot_output" "Metadata payload manifest path: /shadow-payload/manifest.env"
assert_cpio_entry_absent "$TMP_DIR/orange-gpu-rust-bridge-shell-session-shadow-logical.img" orange-gpu.tar.xz
assert_cpio_entry_absent "$TMP_DIR/orange-gpu-rust-bridge-shell-session-shadow-logical.img" orange-gpu/shadow-session
assert_cpio_entry_contains "$TMP_DIR/orange-gpu-rust-bridge-shell-session-shadow-logical.img" shadow-init.cfg "payload_probe_source=shadow-logical-partition"
assert_cpio_entry_contains "$TMP_DIR/orange-gpu-rust-bridge-shell-session-shadow-logical.img" shadow-init.cfg "payload_probe_root=/shadow-payload"
assert_cpio_entry_contains "$TMP_DIR/orange-gpu-rust-bridge-shell-session-shadow-logical.img" shadow-init.cfg "orange_gpu_bundle_archive_path=/shadow-payload/extra-payloads/orange-gpu.tar.xz"
[[ -f "$TMP_DIR/orange-gpu-rust-bridge-shell-session-shadow-logical.img.orange-gpu.tar.xz" ]] || {
  echo "pixel_boot_orange_gpu_smoke: expected external gpu bundle archive" >&2
  exit 1
}
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-shadow-logical.img.hello-init.json" orange_gpu_mode "shell-session"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-shadow-logical.img.hello-init.json" gpu_bundle_archive_source "shadow-logical-partition"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-shadow-logical.img.hello-init.json" gpu_bundle_archive_path /shadow-payload/extra-payloads/orange-gpu.tar.xz
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-shadow-logical.img.hello-init.json" gpu_bundle_archive_host_path "$TMP_DIR/orange-gpu-rust-bridge-shell-session-shadow-logical.img.orange-gpu.tar.xz"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-shadow-logical.img.hello-init.json" payload_probe_source "shadow-logical-partition"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-shadow-logical.img.hello-init.json" payload_probe_root "/shadow-payload"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-shadow-logical.img.hello-init.json" payload_probe_manifest_path "/shadow-payload/manifest.env"

shell_session_held_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_ORANGE_GPU_SHELL_START_APP_ID=counter \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_BUNDLE_DIR="$TS_APP_DIRECT_PRESENT_BUNDLE_DIR" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_LAUNCHER_BIN="$APP_DIRECT_PRESENT_LAUNCHER_OUTPUT" \
    PIXEL_SHADOW_SESSION_BIN="$SHADOW_SESSION_OUTPUT" \
    PIXEL_SHADOW_COMPOSITOR_GUEST_DYNAMIC_BIN="$SHADOW_COMPOSITOR_DYNAMIC_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-shell-session-held.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode shell-session-held \
      --orange-gpu-firmware-helper true \
      --orange-gpu-metadata-stage-breadcrumb true \
      --orange-gpu-timeout-action hold \
      --orange-gpu-watchdog-timeout-secs 12 \
      --firmware-bootstrap ramdisk-lib-firmware \
      --run-token orange-gpu-rust-bridge-shell-session-held-run-token \
      --hold-secs 9 \
      --mount-sys true
)"

assert_contains "$shell_session_held_boot_output" "Orange GPU mode: shell-session-held"
assert_contains "$shell_session_held_boot_output" "Payload contract: hello-init launches /orange-gpu/shadow-session in held shell-session mode, starts counter from the shell"
assert_contains "$shell_session_held_boot_output" "GPU proof: shell-owned counter app launch remains live after watchdog proof for the configured observation window"
assert_contains "$shell_session_held_boot_output" "Orange GPU timeout action: hold"
assert_contains "$shell_session_held_boot_output" "Orange GPU watchdog timeout seconds: 12"
assert_contains "$shell_session_held_boot_output" "Compositor startup config path: /orange-gpu/shell-session-startup.json"
assert_contains "$shell_session_held_boot_output" "Shell session start app id: counter"
assert_contains "$shell_session_held_boot_output" "App direct present client kind: typescript"
assert_cpio_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-held.img" orange-gpu.tar.xz
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-held.img" orange-gpu.tar.xz shadow-session
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-held.img" orange-gpu.tar.xz shadow-compositor-guest
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-held.img" orange-gpu.tar.xz app-direct-present/run-shadow-blitz-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-held.img" orange-gpu.tar.xz app-direct-present/runtime-app-counter-bundle.js
assert_cpio_tar_xz_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-held.img" orange-gpu.tar.xz shell-session-startup.json $'{\n  "schemaVersion": 1,\n  "startup": {\n    "mode": "shell",\n    "shellStartAppId": "counter"\n  },\n  "client": {\n    "appClientPath": "/orange-gpu/app-direct-present/run-shadow-blitz-demo",\n    "runtimeDir": "/shadow-runtime",\n    "systemBinaryPath": "/orange-gpu/app-direct-present/shadow-system",\n    "envAssignments": [\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_BINARY_PATH",\n        "value": "/orange-gpu/app-direct-present/shadow-blitz-demo"\n      },\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_LOADER_PATH",\n        "value": "/orange-gpu/lib/ld-linux-aarch64.so.1"\n      },\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_LIBRARY_PATH",\n        "value": "/orange-gpu/lib"\n      },\n      {\n        "key": "SHADOW_SYSTEM_STAGE_LOADER_PATH",\n        "value": "/orange-gpu/lib/ld-linux-aarch64.so.1"\n      },\n      {\n        "key": "SHADOW_SYSTEM_STAGE_LIBRARY_PATH",\n        "value": "/orange-gpu/lib"\n      }\n    ],\n    "lingerMs": 500\n  },\n  "compositor": {\n    "transport": "direct",\n    "enableDrm": true,\n    "gpuShell": true,\n    "strictGpuResident": true,\n    "dmabufGlobalEnabled": false,\n    "dmabufFeedbackEnabled": true,\n    "exitOnFirstFrame": false,\n    "frameCapture": {\n      "mode": "every-frame",\n      "artifactPath": "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-shell-session-held-run-token/compositor-frame.ppm",\n      "checksum": true\n    }\n  }\n}\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-held.img.hello-init.json" orange_gpu_mode "shell-session-held"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-held.img.hello-init.json" orange_gpu_timeout_action hold
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-held.img.hello-init.json" orange_gpu_watchdog_timeout_secs 12
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-held.img.hello-init.json" shell_session_start_app_id counter
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-held.img.hello-init.json" app_direct_present_app_id counter
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-held.img.hello-init.json" app_direct_present_client_kind typescript
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-held.img.hello-init.json" app_direct_present_runtime_bundle_env SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-held.img.hello-init.json" app_direct_present_runtime_bundle_path /orange-gpu/app-direct-present/runtime-app-counter-bundle.js
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-held.img.hello-init.json" metadata_compositor_frame_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-shell-session-held-run-token/compositor-frame.ppm"

shell_session_timeline_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_ORANGE_GPU_SHELL_START_APP_ID=timeline \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_BUNDLE_DIR="$TS_TIMELINE_APP_DIRECT_PRESENT_BUNDLE_DIR" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_LAUNCHER_BIN="$APP_DIRECT_PRESENT_LAUNCHER_OUTPUT" \
    PIXEL_SHADOW_SESSION_BIN="$SHADOW_SESSION_OUTPUT" \
    PIXEL_SHADOW_COMPOSITOR_GUEST_DYNAMIC_BIN="$SHADOW_COMPOSITOR_DYNAMIC_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-shell-session-timeline.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode shell-session \
      --orange-gpu-firmware-helper true \
      --orange-gpu-metadata-stage-breadcrumb true \
      --firmware-bootstrap ramdisk-lib-firmware \
      --run-token orange-gpu-rust-bridge-shell-session-timeline-run-token \
      --hold-secs 9 \
      --mount-sys true
)"

assert_contains "$shell_session_timeline_boot_output" "Orange GPU mode: shell-session"
assert_contains "$shell_session_timeline_boot_output" "Payload contract: hello-init launches /orange-gpu/shadow-session in shell-session mode, starts timeline from the shell"
assert_contains "$shell_session_timeline_boot_output" "GPU proof: shell-owned timeline app launch frame captured durably through the Rust boot seam"
assert_contains "$shell_session_timeline_boot_output" "Shell session start app id: timeline"
assert_contains "$shell_session_timeline_boot_output" "App direct present client kind: typescript"
assert_contains "$shell_session_timeline_boot_output" "App runtime bundle env: SHADOW_RUNTIME_APP_TIMELINE_BUNDLE_PATH"
assert_cpio_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-timeline.img" orange-gpu.tar.xz
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-timeline.img" orange-gpu.tar.xz shadow-session
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-timeline.img" orange-gpu.tar.xz shadow-compositor-guest
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-timeline.img" orange-gpu.tar.xz app-direct-present/run-shadow-blitz-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-timeline.img" orange-gpu.tar.xz app-direct-present/shadow-blitz-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-timeline.img" orange-gpu.tar.xz app-direct-present/shadow-system
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-timeline.img" orange-gpu.tar.xz app-direct-present/runtime-app-timeline-bundle.js
assert_cpio_tar_xz_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-timeline.img" orange-gpu.tar.xz shell-session-startup.json $'{\n  "schemaVersion": 1,\n  "startup": {\n    "mode": "shell",\n    "shellStartAppId": "timeline"\n  },\n  "client": {\n    "appClientPath": "/orange-gpu/app-direct-present/run-shadow-blitz-demo",\n    "runtimeDir": "/shadow-runtime",\n    "systemBinaryPath": "/orange-gpu/app-direct-present/shadow-system",\n    "envAssignments": [\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_BINARY_PATH",\n        "value": "/orange-gpu/app-direct-present/shadow-blitz-demo"\n      },\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_LOADER_PATH",\n        "value": "/orange-gpu/lib/ld-linux-aarch64.so.1"\n      },\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_LIBRARY_PATH",\n        "value": "/orange-gpu/lib"\n      },\n      {\n        "key": "SHADOW_SYSTEM_STAGE_LOADER_PATH",\n        "value": "/orange-gpu/lib/ld-linux-aarch64.so.1"\n      },\n      {\n        "key": "SHADOW_SYSTEM_STAGE_LIBRARY_PATH",\n        "value": "/orange-gpu/lib"\n      }\n    ],\n    "lingerMs": 500\n  },\n  "compositor": {\n    "transport": "direct",\n    "enableDrm": true,\n    "gpuShell": true,\n    "strictGpuResident": true,\n    "dmabufGlobalEnabled": false,\n    "dmabufFeedbackEnabled": true,\n    "exitOnFirstFrame": true,\n    "frameCapture": {\n      "mode": "every-frame",\n      "artifactPath": "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-shell-session-timeline-run-token/compositor-frame.ppm",\n      "checksum": true\n    }\n  }\n}\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-timeline.img.hello-init.json" orange_gpu_mode "shell-session"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-timeline.img.hello-init.json" shell_session_start_app_id timeline
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-timeline.img.hello-init.json" app_direct_present_app_id timeline
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-timeline.img.hello-init.json" app_direct_present_client_kind typescript
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-timeline.img.hello-init.json" app_direct_present_runtime_bundle_env SHADOW_RUNTIME_APP_TIMELINE_BUNDLE_PATH
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-timeline.img.hello-init.json" app_direct_present_runtime_bundle_path /orange-gpu/app-direct-present/runtime-app-timeline-bundle.js
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-timeline.img.hello-init.json" metadata_compositor_frame_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-shell-session-timeline-run-token/compositor-frame.ppm"

shell_session_touch_counter_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_ORANGE_GPU_SHELL_START_APP_ID=counter \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_BUNDLE_DIR="$TS_APP_DIRECT_PRESENT_BUNDLE_DIR" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_LAUNCHER_BIN="$APP_DIRECT_PRESENT_LAUNCHER_OUTPUT" \
    PIXEL_SHADOW_SESSION_BIN="$SHADOW_SESSION_OUTPUT" \
    PIXEL_SHADOW_COMPOSITOR_GUEST_DYNAMIC_BIN="$SHADOW_COMPOSITOR_DYNAMIC_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-shell-session-touch-counter.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode shell-session-runtime-touch-counter \
      --orange-gpu-firmware-helper true \
      --orange-gpu-metadata-stage-breadcrumb true \
      --firmware-bootstrap ramdisk-lib-firmware \
      --run-token orange-gpu-rust-bridge-shell-session-touch-counter-run-token \
      --hold-secs 9 \
      --mount-sys true
)"

assert_contains "$shell_session_touch_counter_boot_output" "Orange GPU mode: shell-session-runtime-touch-counter"
assert_contains "$shell_session_touch_counter_boot_output" "Payload contract: hello-init launches /orange-gpu/shadow-session in shell-session runtime touch-counter mode for counter"
assert_contains "$shell_session_touch_counter_boot_output" "GPU proof: shell-owned TypeScript counter launch increments from injected touch and presents a post-touch frame through the Rust boot seam"
assert_contains "$shell_session_touch_counter_boot_output" "Compositor startup config path: /orange-gpu/shell-session-startup.json"
assert_contains "$shell_session_touch_counter_boot_output" "Shell session start app id: counter"
assert_contains "$shell_session_touch_counter_boot_output" "App direct present manual touch: false"
assert_cpio_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-touch-counter.img" orange-gpu.tar.xz
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-touch-counter.img" orange-gpu.tar.xz shadow-session
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-touch-counter.img" orange-gpu.tar.xz shadow-compositor-guest
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-touch-counter.img" orange-gpu.tar.xz app-direct-present/run-shadow-blitz-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-touch-counter.img" orange-gpu.tar.xz app-direct-present/runtime-app-counter-bundle.js
assert_cpio_tar_xz_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-touch-counter.img" orange-gpu.tar.xz shell-session-startup.json $'{\n  "schemaVersion": 1,\n  "startup": {\n    "mode": "shell",\n    "shellStartAppId": "counter"\n  },\n  "client": {\n    "appClientPath": "/orange-gpu/app-direct-present/run-shadow-blitz-demo",\n    "runtimeDir": "/shadow-runtime",\n    "systemBinaryPath": "/orange-gpu/app-direct-present/shadow-system",\n    "envAssignments": [\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_BINARY_PATH",\n        "value": "/orange-gpu/app-direct-present/shadow-blitz-demo"\n      },\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_LOADER_PATH",\n        "value": "/orange-gpu/lib/ld-linux-aarch64.so.1"\n      },\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_LIBRARY_PATH",\n        "value": "/orange-gpu/lib"\n      },\n      {\n        "key": "SHADOW_SYSTEM_STAGE_LOADER_PATH",\n        "value": "/orange-gpu/lib/ld-linux-aarch64.so.1"\n      },\n      {\n        "key": "SHADOW_SYSTEM_STAGE_LIBRARY_PATH",\n        "value": "/orange-gpu/lib"\n      },\n      {\n        "key": "SHADOW_BLITZ_TOUCH_ANYWHERE_TARGET",\n        "value": "counter"\n      }\n    ],\n    "lingerMs": 500\n  },\n  "compositor": {\n    "transport": "direct",\n    "enableDrm": true,\n    "gpuShell": true,\n    "strictGpuResident": true,\n    "dmabufGlobalEnabled": false,\n    "dmabufFeedbackEnabled": true,\n    "exitOnFirstFrame": false,\n    "frameCapture": {\n      "mode": "every-frame",\n      "artifactPath": "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-shell-session-touch-counter-run-token/compositor-frame.ppm",\n      "checksum": true\n    }\n  },\n  "touch": {\n    "latencyTrace": true,\n    "syntheticTap": {\n      "normalizedXMillis": 500,\n      "normalizedYMillis": 500,\n      "afterFirstFrameDelayMs": 250,\n      "holdMs": 50,\n      "afterAppId": "counter"\n    },\n    "exitAfterPresent": true\n  }\n}\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-touch-counter.img.hello-init.json" orange_gpu_mode "shell-session-runtime-touch-counter"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-touch-counter.img.hello-init.json" shell_session_start_app_id counter
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-touch-counter.img.hello-init.json" app_direct_present_app_id counter
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-touch-counter.img.hello-init.json" app_direct_present_client_kind typescript
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-touch-counter.img.hello-init.json" app_direct_present_runtime_bundle_env SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-touch-counter.img.hello-init.json" app_direct_present_runtime_bundle_path /orange-gpu/app-direct-present/runtime-app-counter-bundle.js
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-touch-counter.img.hello-init.json" metadata_compositor_frame_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-shell-session-touch-counter-run-token/compositor-frame.ppm"

shell_session_rust_demo_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_ORANGE_GPU_SHELL_START_APP_ID=rust-demo \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_BUNDLE_DIR="$APP_DIRECT_PRESENT_BUNDLE_DIR" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_LAUNCHER_BIN="$APP_DIRECT_PRESENT_LAUNCHER_OUTPUT" \
    PIXEL_SHADOW_SESSION_BIN="$SHADOW_SESSION_OUTPUT" \
    PIXEL_SHADOW_COMPOSITOR_GUEST_DYNAMIC_BIN="$SHADOW_COMPOSITOR_DYNAMIC_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-shell-session-rust-demo.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode shell-session \
      --orange-gpu-firmware-helper true \
      --orange-gpu-metadata-stage-breadcrumb true \
      --firmware-bootstrap ramdisk-lib-firmware \
      --run-token orange-gpu-rust-bridge-shell-session-rust-demo-run-token \
      --hold-secs 9 \
      --mount-sys true
)"

assert_contains "$shell_session_rust_demo_boot_output" "Orange GPU mode: shell-session"
assert_contains "$shell_session_rust_demo_boot_output" "Payload contract: hello-init launches /orange-gpu/shadow-session in shell-session mode, starts rust-demo from the shell"
assert_contains "$shell_session_rust_demo_boot_output" "GPU proof: shell-owned rust-demo app launch frame captured durably through the Rust boot seam"
assert_contains "$shell_session_rust_demo_boot_output" "Shell session start app id: rust-demo"
assert_contains "$shell_session_rust_demo_boot_output" "App direct present client kind: rust"
assert_cpio_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-rust-demo.img" orange-gpu.tar.xz
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-rust-demo.img" orange-gpu.tar.xz shadow-session
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-rust-demo.img" orange-gpu.tar.xz shadow-compositor-guest
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-rust-demo.img" orange-gpu.tar.xz app-direct-present/run-shadow-rust-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-rust-demo.img" orange-gpu.tar.xz app-direct-present/shadow-rust-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-shell-session-rust-demo.img" orange-gpu.tar.xz app-direct-present/lib/ld-linux-aarch64.so.1
assert_cpio_tar_xz_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-rust-demo.img" orange-gpu.tar.xz shell-session-startup.json $'{\n  "schemaVersion": 1,\n  "startup": {\n    "mode": "shell",\n    "shellStartAppId": "rust-demo"\n  },\n  "client": {\n    "appClientPath": "/orange-gpu/app-direct-present/run-shadow-rust-demo",\n    "runtimeDir": "/shadow-runtime",\n    "envAssignments": [\n      {\n        "key": "SHADOW_RUNTIME_CAMERA_ALLOW_MOCK",\n        "value": "1"\n      }\n    ],\n    "lingerMs": 500\n  },\n  "compositor": {\n    "transport": "direct",\n    "enableDrm": true,\n    "gpuShell": true,\n    "strictGpuResident": true,\n    "dmabufGlobalEnabled": false,\n    "dmabufFeedbackEnabled": true,\n    "exitOnFirstFrame": true,\n    "frameCapture": {\n      "mode": "every-frame",\n      "artifactPath": "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-shell-session-rust-demo-run-token/compositor-frame.ppm",\n      "checksum": true\n    }\n  }\n}\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-rust-demo.img.hello-init.json" orange_gpu_mode "shell-session"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-rust-demo.img.hello-init.json" shell_session_start_app_id rust-demo
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-rust-demo.img.hello-init.json" app_direct_present_app_id rust-demo
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-rust-demo.img.hello-init.json" app_direct_present_client_kind rust
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-rust-demo.img.hello-init.json" app_direct_present_runtime_bundle_env ""
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-rust-demo.img.hello-init.json" app_direct_present_runtime_bundle_path ""
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-rust-demo.img.hello-init.json" gpu_bundle_archive_path /orange-gpu.tar.xz
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-shell-session-rust-demo.img.hello-init.json" metadata_compositor_frame_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-shell-session-rust-demo-run-token/compositor-frame.ppm"

runtime_touch_counter_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_BUNDLE_DIR="$TS_APP_DIRECT_PRESENT_BUNDLE_DIR" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_LAUNCHER_BIN="$APP_DIRECT_PRESENT_LAUNCHER_OUTPUT" \
    PIXEL_SHADOW_SESSION_BIN="$SHADOW_SESSION_OUTPUT" \
    PIXEL_SHADOW_COMPOSITOR_GUEST_BIN="$SHADOW_COMPOSITOR_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode app-direct-present-runtime-touch-counter \
      --orange-gpu-firmware-helper true \
      --orange-gpu-metadata-stage-breadcrumb true \
      --firmware-bootstrap ramdisk-lib-firmware \
      --run-token orange-gpu-rust-bridge-runtime-touch-counter-run-token \
      --hold-secs 9 \
      --mount-sys true
)"

assert_contains "$runtime_touch_counter_boot_output" "Orange GPU mode: app-direct-present-runtime-touch-counter"
assert_contains "$runtime_touch_counter_boot_output" "Payload contract: hello-init launches /orange-gpu/shadow-session in app-only direct-present runtime touch-counter mode for counter"
assert_contains "$runtime_touch_counter_boot_output" "GPU proof: app-owned TypeScript counter surface increments from injected touch and presents a post-touch frame through the Rust boot seam"
assert_contains "$runtime_touch_counter_boot_output" "App direct present id: counter"
assert_contains "$runtime_touch_counter_boot_output" "App direct present client kind: typescript"
assert_contains "$runtime_touch_counter_boot_output" "App TypeScript renderer: gpu"
assert_contains "$runtime_touch_counter_boot_output" "App runtime bundle env: SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH"
assert_contains "$runtime_touch_counter_boot_output" "GPU bundle archive path: /orange-gpu.tar.xz"
assert_cpio_entry_present "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img" orange-gpu.tar.xz
assert_cpio_entry_absent "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img" orange-gpu/app-direct-present/run-shadow-blitz-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img" orange-gpu.tar.xz app-direct-present/run-shadow-blitz-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img" orange-gpu.tar.xz app-direct-present/shadow-blitz-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img" orange-gpu.tar.xz app-direct-present/shadow-system
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img" orange-gpu.tar.xz app-direct-present/runtime-app-counter-bundle.js
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img" orange-gpu.tar.xz shadow-session
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img" orange-gpu.tar.xz shadow-compositor-guest
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img" orange-gpu.tar.xz lib/ld-linux-aarch64.so.1
assert_cpio_tar_xz_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img" orange-gpu.tar.xz app-direct-present-startup.json $'{\n  "schemaVersion": 1,\n  "startup": {\n    "mode": "app",\n    "startAppId": "counter"\n  },\n  "client": {\n    "appClientPath": "/orange-gpu/app-direct-present/run-shadow-blitz-demo",\n    "runtimeDir": "/shadow-runtime",\n    "systemBinaryPath": "/orange-gpu/app-direct-present/shadow-system",\n    "envAssignments": [\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_BINARY_PATH",\n        "value": "/orange-gpu/app-direct-present/shadow-blitz-demo"\n      },\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_LOADER_PATH",\n        "value": "/orange-gpu/lib/ld-linux-aarch64.so.1"\n      },\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_LIBRARY_PATH",\n        "value": "/orange-gpu/lib"\n      },\n      {\n        "key": "SHADOW_SYSTEM_STAGE_LOADER_PATH",\n        "value": "/orange-gpu/lib/ld-linux-aarch64.so.1"\n      },\n      {\n        "key": "SHADOW_SYSTEM_STAGE_LIBRARY_PATH",\n        "value": "/orange-gpu/lib"\n      },\n      {\n        "key": "SHADOW_BLITZ_TOUCH_ANYWHERE_TARGET",\n        "value": "counter"\n      }\n    ],\n    "lingerMs": 500\n  },\n  "compositor": {\n    "transport": "direct",\n    "enableDrm": true,\n    "exitOnFirstFrame": false,\n    "frameCapture": {\n      "mode": "every-frame",\n      "artifactPath": "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-runtime-touch-counter-run-token/compositor-frame.ppm",\n      "checksum": true\n    }\n  },\n  "touch": {\n    "latencyTrace": true,\n    "syntheticTap": {\n      "normalizedXMillis": 500,\n      "normalizedYMillis": 500,\n      "afterFirstFrameDelayMs": 250,\n      "holdMs": 50\n    },\n    "exitAfterPresent": true\n  }\n}\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img.hello-init.json" orange_gpu_mode "app-direct-present-runtime-touch-counter"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img.hello-init.json" app_direct_present_app_id counter
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img.hello-init.json" app_direct_present_client_kind typescript
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img.hello-init.json" app_direct_present_typescript_renderer gpu
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img.hello-init.json" gpu_bundle_archive_path /orange-gpu.tar.xz
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img.hello-init.json" app_direct_present_runtime_bundle_env SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img.hello-init.json" app_direct_present_runtime_bundle_path /orange-gpu/app-direct-present/runtime-app-counter-bundle.js
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter.img.hello-init.json" metadata_compositor_frame_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-runtime-touch-counter-run-token/compositor-frame.ppm"

manual_runtime_touch_counter_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_BUNDLE_DIR="$TS_APP_DIRECT_PRESENT_BUNDLE_DIR" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_LAUNCHER_BIN="$APP_DIRECT_PRESENT_LAUNCHER_OUTPUT" \
    PIXEL_SHADOW_SESSION_BIN="$SHADOW_SESSION_OUTPUT" \
    PIXEL_SHADOW_COMPOSITOR_GUEST_BIN="$SHADOW_COMPOSITOR_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter-manual.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode app-direct-present-runtime-touch-counter \
      --app-direct-present-manual-touch true \
      --orange-gpu-firmware-helper true \
      --orange-gpu-metadata-stage-breadcrumb true \
      --firmware-bootstrap ramdisk-lib-firmware \
      --run-token orange-gpu-rust-bridge-runtime-touch-counter-manual-run-token \
      --hold-secs 9 \
      --mount-sys true
)"

assert_contains "$manual_runtime_touch_counter_boot_output" "GPU proof: app-owned TypeScript counter surface increments from physical touch and presents a post-touch frame through the Rust boot seam"
assert_cpio_entry_contains "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter-manual.img" shadow-init.cfg $'app_direct_present_manual_touch=true\n'
assert_cpio_tar_xz_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter-manual.img" orange-gpu.tar.xz app-direct-present-startup.json $'{\n  "schemaVersion": 1,\n  "startup": {\n    "mode": "app",\n    "startAppId": "counter"\n  },\n  "client": {\n    "appClientPath": "/orange-gpu/app-direct-present/run-shadow-blitz-demo",\n    "runtimeDir": "/shadow-runtime",\n    "systemBinaryPath": "/orange-gpu/app-direct-present/shadow-system",\n    "envAssignments": [\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_BINARY_PATH",\n        "value": "/orange-gpu/app-direct-present/shadow-blitz-demo"\n      },\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_LOADER_PATH",\n        "value": "/orange-gpu/lib/ld-linux-aarch64.so.1"\n      },\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_LIBRARY_PATH",\n        "value": "/orange-gpu/lib"\n      },\n      {\n        "key": "SHADOW_SYSTEM_STAGE_LOADER_PATH",\n        "value": "/orange-gpu/lib/ld-linux-aarch64.so.1"\n      },\n      {\n        "key": "SHADOW_SYSTEM_STAGE_LIBRARY_PATH",\n        "value": "/orange-gpu/lib"\n      },\n      {\n        "key": "SHADOW_BLITZ_TOUCH_ANYWHERE_TARGET",\n        "value": "counter"\n      }\n    ],\n    "lingerMs": 500\n  },\n  "compositor": {\n    "transport": "direct",\n    "enableDrm": true,\n    "exitOnFirstFrame": false,\n    "frameCapture": {\n      "mode": "every-frame",\n      "artifactPath": "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-runtime-touch-counter-manual-run-token/compositor-frame.ppm",\n      "checksum": true\n    }\n  },\n  "touch": {\n    "latencyTrace": true,\n    "exitAfterPresent": true\n  }\n}\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-runtime-touch-counter-manual.img.hello-init.json" app_direct_present_manual_touch "true"

ts_timeline_app_direct_present_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_APP_ID=timeline \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_BUNDLE_DIR="$TS_TIMELINE_APP_DIRECT_PRESENT_BUNDLE_DIR" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_LAUNCHER_BIN="$APP_DIRECT_PRESENT_LAUNCHER_OUTPUT" \
    PIXEL_SHADOW_SESSION_BIN="$SHADOW_SESSION_OUTPUT" \
    PIXEL_SHADOW_COMPOSITOR_GUEST_BIN="$SHADOW_COMPOSITOR_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode app-direct-present \
      --orange-gpu-firmware-helper true \
      --orange-gpu-metadata-stage-breadcrumb true \
      --firmware-bootstrap ramdisk-lib-firmware \
      --run-token orange-gpu-rust-bridge-ts-timeline-app-direct-present-run-token \
      --hold-secs 9 \
      --mount-sys true
)"

assert_contains "$ts_timeline_app_direct_present_boot_output" "Orange GPU mode: app-direct-present"
assert_contains "$ts_timeline_app_direct_present_boot_output" "Payload contract: hello-init launches /orange-gpu/shadow-session in app-only direct-present mode for timeline"
assert_contains "$ts_timeline_app_direct_present_boot_output" "GPU proof: app-owned timeline surface imported and presented with no shell through the Rust boot seam"
assert_contains "$ts_timeline_app_direct_present_boot_output" "App direct present id: timeline"
assert_contains "$ts_timeline_app_direct_present_boot_output" "App direct present client kind: typescript"
assert_contains "$ts_timeline_app_direct_present_boot_output" "App TypeScript renderer: gpu"
assert_contains "$ts_timeline_app_direct_present_boot_output" "GPU bundle archive path: /orange-gpu.tar.xz"
assert_contains "$ts_timeline_app_direct_present_boot_output" "App runtime bundle env: SHADOW_RUNTIME_APP_TIMELINE_BUNDLE_PATH"
assert_contains "$ts_timeline_app_direct_present_boot_output" "App runtime bundle path: /orange-gpu/app-direct-present/runtime-app-timeline-bundle.js"
assert_cpio_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img" orange-gpu.tar.xz
assert_cpio_entry_absent "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img" orange-gpu/app-direct-present/run-shadow-blitz-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img" orange-gpu.tar.xz app-direct-present/run-shadow-blitz-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img" orange-gpu.tar.xz app-direct-present/shadow-blitz-demo
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img" orange-gpu.tar.xz app-direct-present/shadow-system
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img" orange-gpu.tar.xz app-direct-present/runtime-app-timeline-bundle.js
assert_cpio_tar_xz_entry_absent "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img" orange-gpu.tar.xz app-direct-present/runtime-app-counter-bundle.js
assert_cpio_tar_xz_entry_absent "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img" orange-gpu.tar.xz shadow-gpu-smoke
assert_cpio_tar_xz_entry_absent "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img" orange-gpu.tar.xz app-direct-present/lib/ld-linux-aarch64.so.1
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img" orange-gpu.tar.xz lib/ld-linux-aarch64.so.1
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img" orange-gpu.tar.xz lib/libc.so.6
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img" orange-gpu.tar.xz lib/libm.so.6
assert_cpio_tar_xz_entry_present "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img" orange-gpu.tar.xz lib/libgcc_s.so.1
assert_cpio_tar_xz_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img" orange-gpu.tar.xz app-direct-present-startup.json $'{\n  "schemaVersion": 1,\n  "startup": {\n    "mode": "app",\n    "startAppId": "timeline"\n  },\n  "client": {\n    "appClientPath": "/orange-gpu/app-direct-present/run-shadow-blitz-demo",\n    "runtimeDir": "/shadow-runtime",\n    "systemBinaryPath": "/orange-gpu/app-direct-present/shadow-system",\n    "envAssignments": [\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_BINARY_PATH",\n        "value": "/orange-gpu/app-direct-present/shadow-blitz-demo"\n      },\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_LOADER_PATH",\n        "value": "/orange-gpu/lib/ld-linux-aarch64.so.1"\n      },\n      {\n        "key": "SHADOW_APP_DIRECT_PRESENT_LIBRARY_PATH",\n        "value": "/orange-gpu/lib"\n      },\n      {\n        "key": "SHADOW_SYSTEM_STAGE_LOADER_PATH",\n        "value": "/orange-gpu/lib/ld-linux-aarch64.so.1"\n      },\n      {\n        "key": "SHADOW_SYSTEM_STAGE_LIBRARY_PATH",\n        "value": "/orange-gpu/lib"\n      }\n    ],\n    "lingerMs": 500\n  },\n  "compositor": {\n    "transport": "direct",\n    "enableDrm": true,\n    "exitOnFirstFrame": true,\n    "frameCapture": {\n      "mode": "first-frame",\n      "artifactPath": "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-ts-timeline-app-direct-present-run-token/compositor-frame.ppm",\n      "checksum": true\n    }\n  }\n}\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img.hello-init.json" orange_gpu_mode "app-direct-present"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img.hello-init.json" app_direct_present_app_id timeline
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img.hello-init.json" app_direct_present_client_kind typescript
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img.hello-init.json" app_direct_present_typescript_renderer gpu
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img.hello-init.json" gpu_bundle_archive_path /orange-gpu.tar.xz
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img.hello-init.json" app_direct_present_runtime_bundle_env SHADOW_RUNTIME_APP_TIMELINE_BUNDLE_PATH
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-ts-timeline-app-direct-present.img.hello-init.json" app_direct_present_runtime_bundle_path /orange-gpu/app-direct-present/runtime-app-timeline-bundle.js

rust_bridge_app_direct_touch_boot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_BUNDLE_DIR="$APP_DIRECT_PRESENT_BUNDLE_DIR" \
    PIXEL_ORANGE_GPU_APP_DIRECT_PRESENT_LAUNCHER_BIN="$APP_DIRECT_PRESENT_LAUNCHER_OUTPUT" \
    PIXEL_SHADOW_SESSION_BIN="$SHADOW_SESSION_OUTPUT" \
    PIXEL_SHADOW_COMPOSITOR_GUEST_BIN="$SHADOW_COMPOSITOR_OUTPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --firmware-dir "$GPU_FIRMWARE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-app-direct-touch.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode app-direct-present-touch-counter \
      --orange-gpu-firmware-helper true \
      --orange-gpu-metadata-stage-breadcrumb true \
      --firmware-bootstrap ramdisk-lib-firmware \
      --run-token orange-gpu-rust-bridge-app-direct-touch-run-token \
      --hold-secs 9 \
      --mount-sys true
)"

assert_contains "$rust_bridge_app_direct_touch_boot_output" "Orange GPU mode: app-direct-present-touch-counter"
assert_contains "$rust_bridge_app_direct_touch_boot_output" "Payload contract: hello-init launches /orange-gpu/shadow-session in app-only direct-present touch-counter mode for rust-demo"
assert_contains "$rust_bridge_app_direct_touch_boot_output" "GPU proof: app-owned rust-demo surface increments from injected touch and presents a post-touch frame through the Rust boot seam"
assert_cpio_entry_present "$TMP_DIR/orange-gpu-rust-bridge-app-direct-touch.img" orange-gpu/shadow-session
assert_cpio_entry_present "$TMP_DIR/orange-gpu-rust-bridge-app-direct-touch.img" orange-gpu/shadow-compositor-guest
assert_cpio_entry_present "$TMP_DIR/orange-gpu-rust-bridge-app-direct-touch.img" orange-gpu/app-direct-present/run-shadow-rust-demo
assert_cpio_entry_present "$TMP_DIR/orange-gpu-rust-bridge-app-direct-touch.img" orange-gpu/app-direct-present/shadow-rust-demo
assert_cpio_entry_equals "$TMP_DIR/orange-gpu-rust-bridge-app-direct-touch.img" orange-gpu/app-direct-present-startup.json $'{\n  "schemaVersion": 1,\n  "startup": {\n    "mode": "app",\n    "startAppId": "rust-demo"\n  },\n  "client": {\n    "appClientPath": "/orange-gpu/app-direct-present/run-shadow-rust-demo",\n    "runtimeDir": "/shadow-runtime",\n    "envAssignments": [\n      {\n        "key": "SHADOW_RUNTIME_CAMERA_ALLOW_MOCK",\n        "value": "1"\n      }\n    ],\n    "lingerMs": 500\n  },\n  "compositor": {\n    "transport": "direct",\n    "enableDrm": true,\n    "exitOnFirstFrame": false,\n    "frameCapture": {\n      "mode": "every-frame",\n      "artifactPath": "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-app-direct-touch-run-token/compositor-frame.ppm",\n      "checksum": true\n    }\n  },\n  "touch": {\n    "latencyTrace": true,\n    "syntheticTap": {\n      "normalizedXMillis": 500,\n      "normalizedYMillis": 500,\n      "afterFirstFrameDelayMs": 250,\n      "holdMs": 50\n    },\n    "exitAfterPresent": true\n  }\n}\n'
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-app-direct-touch.img.hello-init.json" orange_gpu_mode "app-direct-present-touch-counter"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-app-direct-touch.img.hello-init.json" metadata_compositor_frame_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-app-direct-touch-run-token/compositor-frame.ppm"
assert_json_field_equals "$TMP_DIR/orange-gpu-rust-bridge-app-direct-touch.img.hello-init.json" metadata_probe_summary_path "/metadata/shadow-hello-init/by-token/orange-gpu-rust-bridge-app-direct-touch-run-token/probe-summary.json"

assert_command_fails_contains "rust-bridge orange-gpu images currently require --rust-child-profile hello" \
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_RUST_CHILD_OUTPUT" \
      --rust-shim "$HELLO_INIT_RUST_EXEC_SHIM_OUTPUT" \
      --rust-shim-mode exec \
      --rust-child-profile std-probe \
      --orange-init "$ORANGE_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/orange-gpu-rust-bridge-should-fail-std-probe.img" \
      --hello-init-mode rust-bridge \
      --orange-gpu-mode gpu-render

assert_command_fails_contains "expected an aarch64 ELF loader" \
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --gpu-bundle "$BAD_LOADER_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-bad-loader.img"

assert_command_fails_contains "expected an aarch64 ELF gpu binary" \
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --gpu-bundle "$BAD_BINARY_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-bad-binary.img"

assert_command_fails_contains "orange gpu mode must be gpu-render, orange-gpu-loop, bundle-smoke, vulkan-instance-smoke, raw-vulkan-instance-smoke, firmware-probe-only, timeout-control-smoke, camera-hal-link-probe, c-kgsl-open-readonly-smoke, c-kgsl-open-readonly-firmware-helper-smoke, c-kgsl-open-readonly-pid1-smoke, raw-kgsl-open-readonly-smoke, raw-kgsl-getproperties-smoke, raw-vulkan-physical-device-count-query-exit-smoke, raw-vulkan-physical-device-count-query-no-destroy-smoke, raw-vulkan-physical-device-count-query-smoke, raw-vulkan-physical-device-count-smoke, vulkan-enumerate-adapters-count-smoke, vulkan-enumerate-adapters-smoke, vulkan-adapter-smoke, vulkan-device-request-smoke, vulkan-device-smoke, vulkan-offscreen, compositor-scene, shell-session, shell-session-held, shell-session-runtime-touch-counter, app-direct-present, app-direct-present-touch-counter, app-direct-present-runtime-touch-counter, or payload-partition-probe" \
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-invalid-mode.img" \
      --orange-gpu-mode nope

assert_command_fails_contains "c-kgsl-open-readonly-firmware-helper-smoke requires --mount-sys true" \
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-firmware-helper-no-sys.img" \
      --orange-gpu-mode c-kgsl-open-readonly-firmware-helper-smoke \
      --mount-sys false

assert_command_fails_contains "c-kgsl-open-readonly-firmware-helper-smoke requires --orange-gpu-metadata-stage-breadcrumb true" \
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-firmware-helper-no-breadcrumb.img" \
      --orange-gpu-mode c-kgsl-open-readonly-firmware-helper-smoke \
      --mount-sys true \
      --orange-gpu-metadata-stage-breadcrumb false

assert_command_fails_contains "orange-gpu-firmware-helper requires --mount-sys true" \
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-generic-helper-no-sys.img" \
      --orange-gpu-mode raw-kgsl-getproperties-smoke \
      --orange-gpu-firmware-helper true \
      --mount-sys false

assert_command_fails_contains "orange-gpu-firmware-helper requires --firmware-bootstrap ramdisk-lib-firmware" \
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-generic-helper-no-firmware-bootstrap.img" \
      --orange-gpu-mode raw-kgsl-getproperties-smoke \
      --orange-gpu-firmware-helper true \
      --mount-sys true

echo "pixel_boot_orange_gpu_smoke: ok"
