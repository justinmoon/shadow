#!/usr/bin/env python3
"""
Utility for editing Android ramdisk archives (cpio newc format) without losing
special files like device nodes.
"""

from __future__ import annotations

import argparse
import os
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Sequence


CPIO_MAGIC = b"070701"
ALIGNMENT = 4


def _align(length: int) -> int:
    remainder = length % ALIGNMENT
    return (ALIGNMENT - remainder) % ALIGNMENT


@dataclass
class CpioEntry:
    name: str
    ino: int
    mode: int
    uid: int
    gid: int
    nlink: int
    mtime: int
    filesize: int
    devmajor: int
    devminor: int
    rdevmajor: int
    rdevminor: int
    check: int
    data: bytes

    def clone(self) -> "CpioEntry":
        return CpioEntry(
            name=self.name,
            ino=self.ino,
            mode=self.mode,
            uid=self.uid,
            gid=self.gid,
            nlink=self.nlink,
            mtime=self.mtime,
            filesize=self.filesize,
            devmajor=self.devmajor,
            devminor=self.devminor,
            rdevmajor=self.rdevmajor,
            rdevminor=self.rdevminor,
            check=self.check,
            data=self.data,
        )


class CpioArchive:
    def __init__(self, entries: Sequence[CpioEntry], trailing_padding: bytes):
        if not entries or entries[-1].name != "TRAILER!!!":
            raise ValueError("cpio archive must end with TRAILER!!! entry")
        self._entries: List[CpioEntry] = list(entries)
        self._trailing_padding = trailing_padding

    @property
    def entries(self) -> List[CpioEntry]:
        return self._entries

    @property
    def trailer(self) -> CpioEntry:
        return self._entries[-1]

    def without_trailer(self) -> Sequence[CpioEntry]:
        return self._entries[:-1]

    def next_inode(self) -> int:
        max_ino = max((entry.ino for entry in self.without_trailer()), default=0)
        return max_ino + 1

    @property
    def trailing_padding(self) -> bytes:
        return self._trailing_padding


def _read_exact(fp, size: int) -> bytes:
    data = fp.read(size)
    if len(data) != size:
        raise EOFError("unexpected end of cpio stream")
    return data


def read_cpio(path: Path) -> CpioArchive:
    entries: List[CpioEntry] = []
    with path.open("rb") as fp:
        while True:
            header = fp.read(110)
            if not header:
                if entries:
                    raise EOFError("missing TRAILER!!! entry in cpio archive")
                break
            if len(header) != 110:
                raise EOFError("truncated cpio header")
            if header[:6] != CPIO_MAGIC:
                raise ValueError("unsupported cpio format (expected newc)")

            fields = [
                int(header[6 + i * 8 : 6 + (i + 1) * 8], 16) for i in range(13)
            ]
            (
                c_ino,
                c_mode,
                c_uid,
                c_gid,
                c_nlink,
                c_mtime,
                c_filesize,
                c_devmajor,
                c_devminor,
                c_rdevmajor,
                c_rdevminor,
                c_namesize,
                c_check,
            ) = fields

            name_bytes = _read_exact(fp, c_namesize)
            name = name_bytes[:-1].decode("utf-8", errors="surrogateescape")
            fp.seek(_align(110 + c_namesize), os.SEEK_CUR)

            data = _read_exact(fp, c_filesize)
            fp.seek(_align(c_filesize), os.SEEK_CUR)

            entry = CpioEntry(
                name=name,
                ino=c_ino,
                mode=c_mode,
                uid=c_uid,
                gid=c_gid,
                nlink=c_nlink,
                mtime=c_mtime,
                filesize=c_filesize,
                devmajor=c_devmajor,
                devminor=c_devminor,
                rdevmajor=c_rdevmajor,
                rdevminor=c_rdevminor,
                check=c_check,
                data=data,
            )
            entries.append(entry)

            if name == "TRAILER!!!":
                break
        trailing_padding = fp.read()
    if not entries:
        raise ValueError("empty cpio archive")
    return CpioArchive(entries, trailing_padding)


def write_cpio(archive: CpioArchive, path: Path) -> None:
    with path.open("wb") as fp:
        for entry in archive.entries:
            name_bytes = entry.name.encode("utf-8") + b"\x00"
            header = bytearray()
            header.extend(CPIO_MAGIC)
            values = (
                entry.ino,
                entry.mode,
                entry.uid,
                entry.gid,
                entry.nlink,
                entry.mtime,
                len(entry.data),
                entry.devmajor,
                entry.devminor,
                entry.rdevmajor,
                entry.rdevminor,
                len(name_bytes),
                entry.check,
            )
            header.extend("".join(f"{value:08x}" for value in values).encode("ascii"))

            fp.write(header)
            fp.write(name_bytes)
            fp.write(b"\x00" * _align(110 + len(name_bytes)))
            fp.write(entry.data)
            fp.write(b"\x00" * _align(len(entry.data)))
        fp.write(archive.trailing_padding)


def parse_mapping(raw_items: Sequence[str], separator: str = "=") -> Dict[str, str]:
    mapping: Dict[str, str] = {}
    for item in raw_items:
        if separator not in item:
            raise ValueError(f"invalid mapping '{item}', expected KEY{separator}VALUE")
        key, value = item.split(separator, 1)
        key = key.strip()
        value = value.strip()
        if not key or not value:
            raise ValueError(f"invalid mapping '{item}', empty key or value")
        mapping[key] = value
    return mapping


def build_entry_from_path(name: str, path: Path, ino: int) -> CpioEntry:
    st = path.lstat()
    mode = st.st_mode

    if stat.S_ISLNK(mode):
        data = os.readlink(path).encode("utf-8")
        mode_flags = stat.S_IFLNK | stat.S_IMODE(mode)
    elif stat.S_ISREG(mode):
        data = path.read_bytes()
        mode_flags = stat.S_IFREG | stat.S_IMODE(mode)
    elif stat.S_ISDIR(mode):
        data = b""
        mode_flags = stat.S_IFDIR | stat.S_IMODE(mode)
    elif stat.S_ISCHR(mode) or stat.S_ISBLK(mode):
        data = b""
        mode_flags = mode
    else:
        raise ValueError(f"unsupported file type for {path}")

    return CpioEntry(
        name=name,
        ino=ino,
        mode=mode_flags,
        uid=0,
        gid=0,
        nlink=1,
        mtime=int(st.st_mtime),
        filesize=len(data),
        devmajor=0,
        devminor=0,
        rdevmajor=os.major(st.st_rdev) if stat.S_ISCHR(mode) or stat.S_ISBLK(mode) else 0,
        rdevminor=os.minor(st.st_rdev) if stat.S_ISCHR(mode) or stat.S_ISBLK(mode) else 0,
        check=0,
        data=data,
    )


def process_archive(
    archive: CpioArchive,
    rename_map: Dict[str, str],
    replace_map: Dict[str, Path],
    remove_set: Sequence[str],
    add_map: Dict[str, Path],
) -> CpioArchive:
    remove_lookup = set(remove_set)
    updated_entries: List[CpioEntry] = []

    for entry in archive.without_trailer():
        if entry.name in remove_lookup:
            continue

        new_entry = entry.clone()

        if entry.name in rename_map:
            new_entry.name = rename_map[entry.name]

        target_name = new_entry.name
        if target_name in replace_map:
            source_path = replace_map[target_name]
            replacement = build_entry_from_path(target_name, source_path, new_entry.ino)
            replacement.uid = new_entry.uid
            replacement.gid = new_entry.gid
            replacement.nlink = new_entry.nlink
            replacement.devmajor = new_entry.devmajor
            replacement.devminor = new_entry.devminor
            new_entry = replacement

        updated_entries.append(new_entry)

    next_ino = archive.next_inode()
    for name, path in add_map.items():
        entry = build_entry_from_path(name, path, next_ino)
        next_ino += 1
        updated_entries.append(entry)

    updated_entries.append(archive.trailer.clone())
    return CpioArchive(updated_entries, archive.trailing_padding)


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Edit cpio newc archives without extracting to disk.",
    )
    parser.add_argument("-i", "--input", type=Path, required=True, help="input cpio path")
    parser.add_argument("-o", "--output", type=Path, required=True, help="output cpio path")
    parser.add_argument(
        "--rename",
        action="append",
        default=[],
        help="rename entry, e.g. old=new",
    )
    parser.add_argument(
        "--replace",
        action="append",
        default=[],
        help="replace entry contents with file, e.g. init=new_init.bin",
    )
    parser.add_argument(
        "--remove",
        action="append",
        default=[],
        help="remove entry from archive",
    )
    parser.add_argument(
        "--add",
        action="append",
        default=[],
        help="add new entry from file, e.g. path/in/archive=local/path.bin",
    )

    args = parser.parse_args(argv)

    rename_map = parse_mapping(args.rename) if args.rename else {}
    replace_map = (
        {key: Path(value) for key, value in parse_mapping(args.replace).items()}
        if args.replace
        else {}
    )
    add_map = (
        {key: Path(value) for key, value in parse_mapping(args.add).items()}
        if args.add
        else {}
    )

    archive = read_cpio(args.input)
    processed = process_archive(
        archive=archive,
        rename_map=rename_map,
        replace_map=replace_map,
        remove_set=args.remove,
        add_map=add_map,
    )
    write_cpio(processed, args.output)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except Exception as exc:  # noqa: BLE001
        print(f"cpio_edit error: {exc}", file=sys.stderr)
        raise
