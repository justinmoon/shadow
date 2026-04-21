#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-pixel-kgsl-matrix.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

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
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value[part]

rendered = str(value).lower() if isinstance(value, bool) else str(value)
if rendered != expected:
    raise SystemExit(f"{key_path}: expected {expected!r}, got {rendered!r}")
PY
}

cd "$REPO_ROOT"
PIXEL_SERIAL=TESTSERIAL \
  scripts/pixel/pixel_kgsl_matrix.sh \
  --dry-run \
  --output-dir "$TMP_DIR/matrix" >/dev/null

[[ -f "$TMP_DIR/matrix/cases.tsv" ]]
[[ -f "$TMP_DIR/matrix/matrix-summary.json" ]]
[[ -f "$TMP_DIR/matrix/matrix.tsv" ]]

assert_json_field "$TMP_DIR/matrix/matrix-summary.json" "kind" "kgsl_matrix"
assert_json_field "$TMP_DIR/matrix/matrix-summary.json" "case_count" "3"
assert_json_field "$TMP_DIR/matrix/matrix-summary.json" "success_count" "3"
assert_json_field "$TMP_DIR/matrix/matrix-summary.json" "cases/0/dry_run" "true"
assert_json_field "$TMP_DIR/matrix/matrix-summary.json" "cases/0/before_holder_scan/holder_count" "0"
assert_json_field "$TMP_DIR/matrix/matrix-summary.json" "cases/1/service_mode" "display-stopped"
assert_json_field "$TMP_DIR/matrix/matrix-summary.json" "cases/2/service_mode" "display-stopped-keep-allocator"

grep -Fq $'case\tserial\tservice_mode\tscene\tprofile\texit_status\tsuccess\tkgsl_device_opened\tbefore_holders\tafter_holders' \
  "$TMP_DIR/matrix/matrix.tsv"
