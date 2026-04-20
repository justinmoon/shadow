#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-pixel-boot-orange-gpu.XXXXXX")"
MOCK_BIN="$TMP_DIR/bin"
BOOT_BUILD_INPUT="$TMP_DIR/build-input.img"
BOOT_BUILD_RAMDISK="$TMP_DIR/build-ramdisk.cpio"
HELLO_INIT_OUTPUT="$TMP_DIR/hello-init"
ORANGE_INIT_OUTPUT="$TMP_DIR/orange-init"
GPU_BUNDLE_DIR="$TMP_DIR/gpu-bundle"
BAD_LOADER_BUNDLE_DIR="$TMP_DIR/bad-loader-bundle"
BAD_BINARY_BUNDLE_DIR="$TMP_DIR/bad-binary-bundle"
OUTPUT_IMAGE="$TMP_DIR/orange-gpu-boot.img"
DEFAULT_OUTPUT_IMAGE="$TMP_DIR/orange-gpu-default-boot.img"
AVB_KEY_PATH="$TMP_DIR/avb-testkey.pem"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p \
  "$MOCK_BIN" \
  "$GPU_BUNDLE_DIR/lib" \
  "$GPU_BUNDLE_DIR/share/vulkan/icd.d" \
  "$BAD_LOADER_BUNDLE_DIR/lib" \
  "$BAD_LOADER_BUNDLE_DIR/share/vulkan/icd.d" \
  "$BAD_BINARY_BUNDLE_DIR/lib" \
  "$BAD_BINARY_BUNDLE_DIR/share/vulkan/icd.d"
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

cat >"$ORANGE_INIT_OUTPUT" <<'EOF'
#!/system/bin/sh
# shadow-owned-init-role:orange-init
# shadow-owned-init-impl:drm-rect-device
# shadow-owned-init-path:/orange-init
echo orange-init
EOF
chmod 0755 "$ORANGE_INIT_OUTPUT"

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
target="$1"
contents="$(cat "$target" 2>/dev/null || true)"
case "$contents" in
  *ELF_LOADER_AARCH64*)
    printf '%s: ELF 64-bit LSB shared object, ARM aarch64, version 1 (SYSV), static-pie linked, not stripped\n' "$target"
    ;;
  *ELF_BINARY_AARCH64*)
    printf '%s: ELF 64-bit LSB pie executable, ARM aarch64, version 1 (SYSV), dynamically linked, interpreter /orange-gpu/lib/ld-linux-aarch64.so.1, not stripped\n' "$target"
    ;;
  *shadow-owned-init-role:orange-init*)
    printf '%s: ELF 64-bit LSB executable, ARM aarch64, statically linked\n' "$target"
    ;;
  *shadow-owned-init-role:hello-init*)
    printf '%s: ELF 64-bit LSB executable, ARM aarch64, statically linked\n' "$target"
    ;;
  *ELF_VULKAN_LOADER_AARCH64*|*ELF_TURNIP_AARCH64*)
    printf '%s: ELF 64-bit LSB shared object, ARM aarch64, version 1 (SYSV), dynamically linked, not stripped\n' "$target"
    ;;
  "#!"*)
    printf '%s: POSIX shell script, ASCII text executable\n' "$target"
    ;;
  *)
    printf '%s: ASCII text\n' "$target"
    ;;
esac
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
end = source.find("\n        } else if (orange_gpu_mode_is_vulkan_enumerate_adapters_count_smoke(config)) {", start)
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
    extract("static char *trim_whitespace("),
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
    if (!parse_orange_gpu_mode_value("vulkan-enumerate-adapters-count-smoke", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid enumerate-adapters-count-smoke mode\\n");
        return 3;
    }}
    if (strcmp(buffer, "vulkan-enumerate-adapters-count-smoke") != 0) {{
        fprintf(stderr, "unexpected parsed enumerate-adapters-count-smoke mode: %s\\n", buffer);
        return 4;
    }}
    if (!parse_orange_gpu_mode_value("vulkan-enumerate-adapters-smoke", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid enumerate-adapters-smoke mode\\n");
        return 5;
    }}
    if (strcmp(buffer, "vulkan-enumerate-adapters-smoke") != 0) {{
        fprintf(stderr, "unexpected parsed enumerate-adapters-smoke mode: %s\\n", buffer);
        return 6;
    }}
    if (!parse_orange_gpu_mode_value("vulkan-adapter-smoke", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid adapter-smoke mode\\n");
        return 7;
    }}
    if (strcmp(buffer, "vulkan-adapter-smoke") != 0) {{
        fprintf(stderr, "unexpected parsed adapter-smoke mode: %s\\n", buffer);
        return 8;
    }}
    if (!parse_orange_gpu_mode_value("vulkan-device-request-smoke", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid device-request-smoke mode\\n");
        return 9;
    }}
    if (strcmp(buffer, "vulkan-device-request-smoke") != 0) {{
        fprintf(stderr, "unexpected parsed device-request-smoke mode: %s\\n", buffer);
        return 10;
    }}
    if (!parse_orange_gpu_mode_value("vulkan-device-smoke", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse valid device-smoke mode\\n");
        return 11;
    }}
    if (strcmp(buffer, "vulkan-device-smoke") != 0) {{
        fprintf(stderr, "unexpected parsed device-smoke mode: %s\\n", buffer);
        return 12;
    }}
    if (!parse_orange_gpu_mode_value(" vulkan-offscreen ", buffer, sizeof(buffer))) {{
        fprintf(stderr, "failed to parse trimmed offscreen mode\\n");
        return 13;
    }}
    if (strcmp(buffer, "vulkan-offscreen") != 0) {{
        fprintf(stderr, "unexpected parsed offscreen mode: %s\\n", buffer);
        return 14;
    }}
    if (parse_orange_gpu_mode_value("nope", buffer, sizeof(buffer))) {{
        fprintf(stderr, "unexpectedly accepted invalid mode\\n");
        return 15;
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
end = source.find("\n}\n\nfn build_enumerate_adapters_count_smoke_summary(", start)
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
  assert_command_fails_contains "--scene instance-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --hold-secs" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene instance-smoke \
      --hold-secs 1
}

assert_shadow_gpu_enumerate_adapters_count_smoke_rejects_hold_secs() {
  assert_command_fails_contains "--scene instance-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --hold-secs" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene enumerate-adapters-count-smoke \
      --hold-secs 1
}

assert_shadow_gpu_enumerate_adapters_smoke_rejects_hold_secs() {
  assert_command_fails_contains "--scene instance-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --hold-secs" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene enumerate-adapters-smoke \
      --hold-secs 1
}

assert_shadow_gpu_instance_smoke_rejects_present_kms() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --present-kms" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene instance-smoke \
      --present-kms
}

assert_shadow_gpu_enumerate_adapters_count_smoke_rejects_present_kms() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --present-kms" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene enumerate-adapters-count-smoke \
      --present-kms
}

assert_shadow_gpu_enumerate_adapters_smoke_rejects_present_kms() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --present-kms" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene enumerate-adapters-smoke \
      --present-kms
}

assert_shadow_gpu_instance_smoke_rejects_ppm_path() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --ppm-path" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene instance-smoke \
      --ppm-path "$TMP_DIR/instance-smoke.ppm"
}

assert_shadow_gpu_enumerate_adapters_count_smoke_rejects_ppm_path() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --ppm-path" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene enumerate-adapters-count-smoke \
      --ppm-path "$TMP_DIR/enumerate-adapters-count-smoke.ppm"
}

assert_shadow_gpu_enumerate_adapters_smoke_rejects_ppm_path() {
  assert_command_fails_contains "--scene bundle-smoke, instance-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --ppm-path" \
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene enumerate-adapters-smoke \
      --ppm-path "$TMP_DIR/enumerate-adapters-smoke.ppm"
}

assert_shadow_gpu_adapter_smoke_cli() {
  local summary_path="$TMP_DIR/adapter-smoke-summary.json"
  local output

  output="$(
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene adapter-smoke \
      --allow-non-vulkan \
      --allow-software \
      --summary-path "$summary_path"
  )"

  assert_contains "$output" '"mode": "adapter-smoke"'
  assert_contains "$output" '"scene": "adapter-smoke"'
  assert_json_field_equals "$summary_path" mode "adapter-smoke"
  assert_json_field_equals "$summary_path" scene "adapter-smoke"
}

assert_shadow_gpu_adapter_smoke_rejects_hold_secs() {
  assert_command_fails_contains "--scene instance-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --hold-secs" \
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
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene device-request-smoke \
      --allow-non-vulkan \
      --allow-software \
      --summary-path "$summary_path"
  )"

  assert_contains "$output" '"mode": "device-request-smoke"'
  assert_contains "$output" '"scene": "device-request-smoke"'
  assert_json_field_equals "$summary_path" mode "device-request-smoke"
  assert_json_field_equals "$summary_path" scene "device-request-smoke"
}

assert_shadow_gpu_device_request_smoke_rejects_hold_secs() {
  assert_command_fails_contains "--scene instance-smoke, enumerate-adapters-count-smoke, enumerate-adapters-smoke, adapter-smoke, device-request-smoke, and device-smoke do not support --hold-secs" \
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
    nix develop "$REPO_ROOT#runtime" -c cargo run --quiet --manifest-path "$REPO_ROOT/ui/Cargo.toml" -p shadow-gpu-smoke -- \
      --scene device-smoke \
      --allow-non-vulkan \
      --allow-software \
      --summary-path "$summary_path"
  )"

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
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"vulkan-enumerate-adapters-count-smoke"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"vulkan-enumerate-adapters-smoke"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"vulkan-offscreen"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'SHADOW_HELLO_INIT_ORANGE_GPU_SUMMARY_PATH'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'SHADOW_HELLO_INIT_ORANGE_GPU_OUTPUT_PATH'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"orange-gpu-watchdog-timeout"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'continuing to gpu payload'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"--present-kms"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" '"flat-orange"'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'setenv(SHADOW_HELLO_INIT_GPU_BACKEND_ENV, "vulkan", 1)'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'setenv(SHADOW_HELLO_INIT_VK_ICD_FILENAMES_ENV, SHADOW_HELLO_INIT_ORANGE_GPU_ICD_PATH, 1)'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'setenv(SHADOW_HELLO_INIT_MESA_DRIVER_OVERRIDE_ENV, "kgsl", 1)'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_seen'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'validate_orange_gpu_config'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'missing required orange_gpu_mode config for payload=orange-gpu'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'invalid orange_gpu_mode config for payload=orange-gpu'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'SHADOW_HELLO_INIT_ORANGE_GPU_CHECKPOINT_HOLD_SECONDS'
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'checkpoint=validated'
assert_hello_init_orange_gpu_mode_parser_smoke
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_hello_init.c" 'orange_gpu_mode_is_vulkan_instance_smoke'
assert_orange_gpu_instance_branch_shape
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
assert_shadow_gpu_instance_helper_shape
assert_shadow_gpu_instance_smoke_cli
assert_shadow_gpu_instance_smoke_rejects_hold_secs
assert_shadow_gpu_instance_smoke_rejects_present_kms
assert_shadow_gpu_instance_smoke_rejects_ppm_path
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
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" '[--scene smoke|flat-orange|bundle-smoke|instance-smoke|enumerate-adapters-count-smoke|enumerate-adapters-smoke|adapter-smoke|device-request-smoke|device-smoke]'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'BundleSmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'InstanceSmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'EnumerateAdaptersCountSmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'EnumerateAdaptersSmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'AdapterSmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'DeviceRequestSmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'DeviceSmokeSummary'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'mode: "bundle-smoke",'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'mode: "instance-smoke",'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'mode: "enumerate-adapters-count-smoke",'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'mode: "enumerate-adapters-smoke",'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'Self::BundleSmoke => "bundle-smoke"'
assert_file_contains "$REPO_ROOT/ui/crates/shadow-gpu-smoke/src/main.rs" 'Self::InstanceSmoke => "instance-smoke"'
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
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Prelude: %s\\n' \"\$PRELUDE\""
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Orange GPU mode: %s\\n' \"\$ORANGE_GPU_MODE\""
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Bundle exec mode: bundle-smoke\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict Vulkan instance creation\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict Vulkan raw adapter enumeration count\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict Vulkan adapter enumeration\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict Vulkan adapter selection\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict Vulkan device request\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict Vulkan buffer renderer bring-up\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'GPU proof: strict Vulkan offscreen render\\n'"
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Derived success postlude: %s\\n' \"\$(success_postlude_value)\""
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" "printf 'Visible checkpoint hold seconds: %s\\n' \"\$(checkpoint_hold_seconds_value)\""
assert_file_contains "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" 'PIXEL_ORANGE_GPU_DRI_BOOTSTRAP:-'

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
assert_json_field_equals "$DEFAULT_OUTPUT_IMAGE.hello-init.json" success_postlude "none"
assert_json_field_equals "$DEFAULT_OUTPUT_IMAGE.hello-init.json" checkpoint_hold_seconds "0"

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

assert_command_fails_contains "orange gpu mode must be gpu-render, bundle-smoke, vulkan-instance-smoke, vulkan-enumerate-adapters-count-smoke, vulkan-enumerate-adapters-smoke, vulkan-adapter-smoke, vulkan-device-request-smoke, vulkan-device-smoke, or vulkan-offscreen" \
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 MOCK_BOOT_RAMDISK="$BOOT_BUILD_RAMDISK" \
    PIXEL_ROOT_STOCK_BOOT_IMG="$BOOT_BUILD_INPUT" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_build_orange_gpu.sh" \
      --input "$BOOT_BUILD_INPUT" \
      --init "$HELLO_INIT_OUTPUT" \
      --gpu-bundle "$GPU_BUNDLE_DIR" \
      --key "$AVB_KEY_PATH" \
      --output "$TMP_DIR/should-fail-invalid-mode.img" \
      --orange-gpu-mode nope

echo "pixel_boot_orange_gpu_smoke: ok"
