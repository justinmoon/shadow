#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-cpio-edit.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TMP_DIR/input" "$TMP_DIR/output"
printf 'stock-init\n' >"$TMP_DIR/input/init"
chmod 0755 "$TMP_DIR/input/init"
printf 'import /init.recovery.sunfish.rc\n' >"$TMP_DIR/input/init.rc"
printf '#!/system/bin/sh\necho wrapper\n' >"$TMP_DIR/input/init-wrapper"
chmod 0755 "$TMP_DIR/input/init-wrapper"
printf 'import /init.shadow.rc\n' >"$TMP_DIR/input/init.shadow.rc"
printf 'import /init.shadow.rc\n\nimport /init.recovery.sunfish.rc\n' >"$TMP_DIR/input/init.rc.patched"

PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$TMP_DIR" <<'PY'
from pathlib import Path
import sys

from cpio_edit import CpioArchive, CpioEntry, build_entry_from_path, write_cpio

tmp_dir = Path(sys.argv[1])
entries = [
    build_entry_from_path("init", tmp_dir / "input/init", 1),
    build_entry_from_path("system/etc/init/hw/init.rc", tmp_dir / "input/init.rc", 2),
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
write_cpio(CpioArchive(entries + [trailer], b""), tmp_dir / "input/ramdisk.cpio")
PY

python3 "$REPO_ROOT/scripts/lib/cpio_edit.py" \
  --input "$TMP_DIR/input/ramdisk.cpio" \
  --extract "system/etc/init/hw/init.rc=$TMP_DIR/output/init.rc"

grep -Fq 'import /init.recovery.sunfish.rc' "$TMP_DIR/output/init.rc"

python3 "$REPO_ROOT/scripts/lib/cpio_edit.py" \
  --input "$TMP_DIR/input/ramdisk.cpio" \
  --output "$TMP_DIR/output/ramdisk.modified.cpio" \
  --rename init=init.stock \
  --add "init=$TMP_DIR/input/init-wrapper" \
  --add "init.shadow.rc=$TMP_DIR/input/init.shadow.rc" \
  --replace "system/etc/init/hw/init.rc=$TMP_DIR/input/init.rc.patched"

PYTHONPATH="$REPO_ROOT/scripts/lib" python3 - "$TMP_DIR" <<'PY'
from pathlib import Path
import stat
import sys

from cpio_edit import read_cpio

tmp_dir = Path(sys.argv[1])
archive = read_cpio(tmp_dir / "output/ramdisk.modified.cpio")
entries = {entry.name: entry for entry in archive.without_trailer()}

assert "init" in entries
assert "init.stock" in entries
assert "init.shadow.rc" in entries
assert entries["init.stock"].data == b"stock-init\n"
assert entries["init"].data.startswith(b"#!/system/bin/sh")
assert entries["system/etc/init/hw/init.rc"].data.startswith(b"import /init.shadow.rc\n")
assert stat.S_IMODE(entries["init"].mode) == 0o755
PY

set +e
duplicate_output="$(
  python3 "$REPO_ROOT/scripts/lib/cpio_edit.py" \
    --input "$TMP_DIR/input/ramdisk.cpio" \
    --output "$TMP_DIR/output/duplicate.cpio" \
    --add "init=$TMP_DIR/input/init-wrapper" 2>&1
)"
duplicate_status="$?"
set -e
if [[ "$duplicate_status" -eq 0 ]]; then
  echo "cpio_edit_smoke: expected duplicate add to fail" >&2
  exit 1
fi
grep -Fq "duplicate archive entry 'init'" <<<"$duplicate_output"

echo "cpio_edit_smoke: ok"
