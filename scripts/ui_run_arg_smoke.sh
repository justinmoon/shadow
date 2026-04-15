#!/usr/bin/env bash
set -euo pipefail

SMOKE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_RUN_SCRIPT="$SMOKE_SCRIPT_DIR/ui_run.sh"
SHADOWCTL_SCRIPT="$SMOKE_SCRIPT_DIR/shadowctl"
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
  local expected_stdout="$2"
  shift 2

  local stdout status
  if stdout="$(SHADOW_UI_RUN_ECHO_EXEC=1 just run "$@" 2>&1)"; then
    status=0
  else
    status=$?
  fi

  [[ "$status" -eq 0 ]] || fail "$name status=$status expected=0"
  [[ "$stdout" == "$expected_stdout" ]] || fail "$name stdout=$stdout expected=$expected_stdout"
}

check_just_stop_case() {
  local name="$1"
  local expected_stdout="$2"
  shift 2

  local stdout status
  if stdout="$(SHADOW_UI_STOP_ECHO_EXEC=1 just stop "$@" 2>&1)"; then
    status=0
  else
    status=$?
  fi

  [[ "$status" -eq 0 ]] || fail "$name status=$status expected=0"
  [[ "$stdout" == "$expected_stdout" ]] || fail "$name stdout=$stdout expected=$expected_stdout"
}

check_shadowctl_echo_case() {
  local name="$1"
  local expected_status="$2"
  local expected_stdout="$3"
  shift 3

  local stdout status
  local -a argv=("$@")
  if stdout="$("$SHADOWCTL_SCRIPT" "${argv[0]}" --dry-run "${argv[@]:1}" 2>&1)"; then
    status=0
  else
    status=$?
  fi

  [[ "$status" -eq "$expected_status" ]] || fail "$name status=$status expected=$expected_status"
  [[ "$stdout" == "$expected_stdout" ]] || fail "$name stdout=$stdout expected=$expected_stdout"
}

check_case defaults desktop shell 1 ""
check_case positional pixel timeline 1 "" pixel timeline 1
check_case named_normal pixel timeline 1 "" target=pixel app=timeline 1
check_case named_reversed pixel timeline 1 "" app=timeline target=pixel 1
check_case named_with_hold pixel timeline 0 "" app=timeline target=pixel hold=0
check_case named_camera pixel camera 1 "" target=pixel app=camera 1
check_case serial_shortcut pixel timeline 1 TESTSERIAL TESTSERIAL timeline 1
check_case defaults desktop shell 1 ""

check_just_run_case just_default "command=$SMOKE_SCRIPT_DIR/ui_vm_run.sh"
check_just_run_case \
  just_named_normal \
  "$(printf 'env=PIXEL_SERIAL=pixel\nenv=PIXEL_SHELL_START_APP_ID=timeline\ncommand=%s' "$SMOKE_SCRIPT_DIR/pixel_shell_drm_hold.sh")" \
  app=timeline target=pixel
check_just_run_case \
  just_named_reversed \
  "$(printf 'env=PIXEL_SERIAL=pixel\nenv=PIXEL_SHELL_START_APP_ID=timeline\ncommand=%s' "$SMOKE_SCRIPT_DIR/pixel_shell_drm_hold.sh")" \
  target=pixel app=timeline
check_just_run_case \
  just_positional \
  "$(printf 'env=PIXEL_SERIAL=pixel\nenv=PIXEL_SHELL_START_APP_ID=timeline\ncommand=%s' "$SMOKE_SCRIPT_DIR/pixel_shell_drm_hold.sh")" \
  pixel timeline
check_just_run_case \
  just_serial_shortcut \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\nenv=PIXEL_SHELL_START_APP_ID=timeline\ncommand=%s' "$SMOKE_SCRIPT_DIR/pixel_shell_drm_hold.sh")" \
  TESTSERIAL timeline
check_just_run_case \
  just_no_hold \
  "$(printf 'env=PIXEL_SERIAL=pixel\ncommand=%s' "$SMOKE_SCRIPT_DIR/pixel_shell_drm.sh")" \
  target=pixel app=shell hold=0

check_just_stop_case just_stop_default "command=$SMOKE_SCRIPT_DIR/ui_vm_stop.sh"
check_just_stop_case just_stop_pixel "$(printf 'env=PIXEL_SERIAL=pixel\ncommand=%s' "$SMOKE_SCRIPT_DIR/pixel_restore_android.sh")" target=pixel
check_just_stop_case just_stop_serial "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SMOKE_SCRIPT_DIR/pixel_restore_android.sh")" TESTSERIAL

check_shadowctl_echo_case \
  shadowctl_start_vm_shell \
  0 \
  "command=$SMOKE_SCRIPT_DIR/ui_vm_run.sh" \
  start -t vm --app shell

check_shadowctl_echo_case \
  shadowctl_start_vm_camera \
  0 \
  "$(printf 'command=%s --app camera' "$SMOKE_SCRIPT_DIR/ui_vm_run.sh")" \
  start -t vm --app camera

check_shadowctl_echo_case \
  shadowctl_start_pixel_timeline \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\nenv=PIXEL_SHELL_START_APP_ID=timeline\ncommand=%s' "$SMOKE_SCRIPT_DIR/pixel_shell_drm_hold.sh")" \
  start -t pixel:TESTSERIAL --app timeline

check_shadowctl_echo_case \
  shadowctl_start_pixel_no_hold \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SMOKE_SCRIPT_DIR/pixel_shell_drm.sh")" \
  start -t pixel:TESTSERIAL --app shell --hold 0

check_shadowctl_echo_case \
  shadowctl_stop_vm \
  0 \
  "command=$SMOKE_SCRIPT_DIR/ui_vm_stop.sh" \
  stop -t vm

check_shadowctl_echo_case \
  shadowctl_stop_pixel \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SMOKE_SCRIPT_DIR/pixel_restore_android.sh")" \
  stop -t pixel:TESTSERIAL

printf 'ui_run_arg_smoke: ok\n'
