#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path


VALID_BUCKETS = {
    "ci",
    "data",
    "debug",
    "lib",
    "pixel",
    "public",
    "runtime",
    "vm",
}

PUBLIC_ALLOWLIST = {
    "scripts/agent-brief",
    "scripts/land.sh",
    "scripts/pre_commit.sh",
    "scripts/pre_merge.sh",
    "scripts/runtime_build_artifacts.sh",
    "scripts/sc",
    "scripts/shadowctl",
    "scripts/ui_check.sh",
}


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def manifest_path() -> Path:
    return repo_root() / "scripts" / "script_inventory.tsv"


def read_manifest() -> dict[str, tuple[str, str]]:
    rows: dict[str, tuple[str, str]] = {}
    for line_number, raw_line in enumerate(manifest_path().read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            raise SystemExit(
                f"check_script_inventory: {manifest_path()}:{line_number}: "
                "expected path<TAB>bucket<TAB>note"
            )
        path, bucket, note = parts
        if not path.startswith("scripts/"):
            raise SystemExit(
                f"check_script_inventory: {manifest_path()}:{line_number}: "
                f"path must start with scripts/: {path}"
            )
        if bucket not in VALID_BUCKETS:
            valid = ", ".join(sorted(VALID_BUCKETS))
            raise SystemExit(
                f"check_script_inventory: {manifest_path()}:{line_number}: "
                f"invalid bucket {bucket!r}; expected one of {valid}"
            )
        if path in rows:
            raise SystemExit(f"check_script_inventory: duplicate inventory path: {path}")
        rows[path] = (bucket, note)
    return rows


def current_script_files() -> set[str]:
    scripts_dir = repo_root() / "scripts"
    files: set[str] = set()
    for path in scripts_dir.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(repo_root())
        if "__pycache__" in relative.parts:
            continue
        if path.name == ".DS_Store":
            continue
        files.add(relative.as_posix())
    return files


def main() -> int:
    rows = read_manifest()
    actual = current_script_files()
    listed = set(rows)
    errors: list[str] = []

    for path in sorted(actual - listed):
        errors.append(f"unclassified script file: {path}")
    for path in sorted(listed - actual):
        errors.append(f"inventory references missing file: {path}")

    public = {path for path, (bucket, _) in rows.items() if bucket == "public"}
    for path in sorted(public - PUBLIC_ALLOWLIST):
        errors.append(f"public script is not in allowlist: {path}")
    for path in sorted((PUBLIC_ALLOWLIST & actual) - public):
        errors.append(f"allowlisted public script is not bucketed public: {path}")

    for path, (bucket, note) in sorted(rows.items()):
        if bucket != "debug":
            continue
        if "shadowctl" not in note and "docs/" not in note:
            errors.append(f"debug script must name a shadowctl or docs entrypoint: {path}")

    if errors:
        print("check_script_inventory: failed", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    print(f"check_script_inventory: ok ({len(actual)} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
