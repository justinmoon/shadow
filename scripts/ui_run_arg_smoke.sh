#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_RUN_SCRIPT="$SCRIPT_DIR/ui_run.sh"
TMP_HEAD="$(mktemp "${TMPDIR:-/tmp}/ui-run-head.XXXXXX")"

cleanup() {
  rm -f "$TMP_HEAD"
}
trap cleanup EXIT

python3 - "$UI_RUN_SCRIPT" "$TMP_HEAD" <<'PY'
from pathlib import Path
import sys

source_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
source = source_path.read_text()
marker = '\nparse_args "$@"\n'
head, found, _ = source.partition(marker)
if not found:
    raise SystemExit(f"ui_run_arg_smoke: failed to locate parser marker in {source_path}")
output_path.write_text(head + "\n")
PY

# shellcheck source=/dev/null
source "$TMP_HEAD"

fail() {
  echo "ui_run_arg_smoke: $*" >&2
  exit 1
}

check_case() {
  local name="$1"
  local expected_target="$2"
  local expected_app="$3"
  local expected_hold="$4"
  local expected_serial="$5"
  shift 5

  unset PIXEL_SERIAL || true
  parse_args "$@"
  resolve_target

  [[ "$target" == "$expected_target" ]] || fail "$name target=$target expected=$expected_target"
  [[ "$app" == "$expected_app" ]] || fail "$name app=$app expected=$expected_app"
  [[ "$hold" == "$expected_hold" ]] || fail "$name hold=$hold expected=$expected_hold"
  [[ "${PIXEL_SERIAL:-}" == "$expected_serial" ]] || fail "$name PIXEL_SERIAL=${PIXEL_SERIAL:-<unset>} expected=${expected_serial:-<unset>}"
}

check_just_run_case() {
  local name="$1"
  local expected_target="$2"
  local expected_app="$3"
  local expected_hold="$4"
  local expected_serial="$5"
  shift 5

  local dry_run_output
  local -a argv
  dry_run_output="$(just --dry-run run "$@" 2>&1)"
  mapfile -t argv < <(
    python3 - "$dry_run_output" <<'PY'
import shlex
import sys

parts = shlex.split(sys.argv[1])
for part in parts[2:]:
    print(part)
PY
  )

  check_case "$name" "$expected_target" "$expected_app" "$expected_hold" "$expected_serial" "${argv[@]}"
}

check_case defaults desktop shell 1 ""
check_case positional pixel timeline 1 "" pixel timeline 1
check_case named_normal pixel timeline 1 "" target=pixel app=timeline 1
check_case named_reversed pixel timeline 1 "" app=timeline target=pixel 1
check_case named_with_hold pixel timeline 0 "" app=timeline target=pixel hold=0
check_case named_camera pixel camera 1 "" target=pixel app=camera 1
check_case serial_shortcut pixel timeline 1 TESTSERIAL TESTSERIAL timeline 1
check_case defaults desktop shell 1 "" 

check_just_run_case just_default desktop shell 1 ""
check_just_run_case just_named_normal pixel timeline 1 "" app=timeline target=pixel
check_just_run_case just_named_reversed pixel timeline 1 "" target=pixel app=timeline
check_just_run_case just_positional pixel timeline 1 "" pixel timeline
check_just_run_case just_defaults desktop shell 1 ""

printf 'ui_run_arg_smoke: ok\n'
