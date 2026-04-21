#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-pixel-kgsl-cold-matrix.XXXXXX")"

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

assert_case_field() {
  local json_path case_name key expected
  json_path="$1"
  case_name="$2"
  key="$3"
  expected="$4"
  python3 - "$json_path" "$case_name" "$key" "$expected" <<'PY'
import json
import sys

path, case_name, key, expected = sys.argv[1:5]
with open(path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

for case in payload["cases"]:
    if case["case"] == case_name:
        value = case
        for part in key.split("/"):
            if isinstance(value, list):
                value = value[int(part)]
            else:
                value = value[part]
        rendered = str(value).lower() if isinstance(value, bool) else str(value)
        if rendered != expected:
            raise SystemExit(f"{case_name}/{key}: expected {expected!r}, got {rendered!r}")
        raise SystemExit(0)

raise SystemExit(f"missing case {case_name!r}")
PY
}

cd "$REPO_ROOT"

PIXEL_SERIAL=TESTSERIAL \
  scripts/pixel/pixel_kgsl_cold_matrix.sh \
  --dry-run \
  --output-dir "$TMP_DIR/matrix" >/dev/null

[[ -f "$TMP_DIR/matrix/cases.tsv" ]]
[[ -f "$TMP_DIR/matrix/matrix-summary.json" ]]
[[ -f "$TMP_DIR/matrix/matrix.tsv" ]]

assert_json_field "$TMP_DIR/matrix/matrix-summary.json" "kind" "kgsl_cold_matrix"
assert_json_field "$TMP_DIR/matrix/matrix-summary.json" "case_count" "8"
assert_json_field "$TMP_DIR/matrix/matrix-summary.json" "success_count" "8"
assert_case_field "$TMP_DIR/matrix/matrix-summary.json" "warm-baseline" "origin" "warm"
assert_case_field "$TMP_DIR/matrix/matrix-summary.json" "cold-root-ready" "readiness" "root-ready"
assert_case_field "$TMP_DIR/matrix/matrix-summary.json" "cold-pd-mapper" "readiness" "pd-mapper"
assert_case_field "$TMP_DIR/matrix/matrix-summary.json" "cold-qseecom-service" "readiness" "qseecom-service"
assert_case_field "$TMP_DIR/matrix/matrix-summary.json" "cold-gpu-service" "readiness" "gpu-service"
assert_case_field "$TMP_DIR/matrix/matrix-summary.json" "cold-display-services" "readiness" "display-services"
assert_case_field "$TMP_DIR/matrix/matrix-summary.json" "cold-boot-complete" "readiness" "boot-complete"
assert_case_field "$TMP_DIR/matrix/matrix-summary.json" "cold-display-restored" "readiness" "display-restored"
assert_case_field "$TMP_DIR/matrix/matrix-summary.json" "cold-root-ready" "reboot_attempted" "true"
assert_case_field "$TMP_DIR/matrix/matrix-summary.json" "warm-baseline" "props_snapshot/values/slot_suffix" "_a"

grep -Fq $'case\tserial\torigin\treadiness\textra_wait_secs\tscene\tprofile\texit_status\tsuccess\tkgsl_device_opened\tbefore_holders\tafter_holders' \
  "$TMP_DIR/matrix/matrix.tsv"

cat >"$TMP_DIR/invalid-extra.tsv" <<'EOF'
# case_name	serial	origin	readiness	extra_wait_secs	scene	profile
bad-wait	TESTSERIAL	warm	root-ready	not-a-number	raw-kgsl-open-readonly-smoke	dri+kgsl
EOF

set +e
invalid_output="$(
  PIXEL_SERIAL=TESTSERIAL scripts/pixel/pixel_kgsl_cold_matrix.sh \
    --dry-run \
    --manifest "$TMP_DIR/invalid-extra.tsv" 2>&1
)"
invalid_status=$?
set -e
if [[ "$invalid_status" -eq 0 ]]; then
  echo "expected invalid extra_wait_secs manifest to fail" >&2
  exit 1
fi
grep -Fq 'non-numeric extra_wait_secs' <<<"$invalid_output"

cat >"$TMP_DIR/multi-serial.tsv" <<'EOF'
# case_name	serial	origin	readiness	extra_wait_secs	scene	profile
case-a	TESTSERIALA	warm	root-ready	0	raw-kgsl-open-readonly-smoke	dri+kgsl
case-b	TESTSERIALB	reboot	root-ready	0	raw-kgsl-open-readonly-smoke	dri+kgsl
EOF

set +e
multi_output="$(
  PIXEL_SERIAL=TESTSERIAL scripts/pixel/pixel_kgsl_cold_matrix.sh \
    --dry-run \
    --manifest "$TMP_DIR/multi-serial.tsv" 2>&1
)"
multi_status=$?
set -e
if [[ "$multi_status" -eq 0 ]]; then
  echo "expected multi-serial manifest to fail" >&2
  exit 1
fi
grep -Fq 'multi-serial manifests are unsupported' <<<"$multi_output"
