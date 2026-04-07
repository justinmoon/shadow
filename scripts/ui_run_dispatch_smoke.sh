#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_RUN_SCRIPT="$SCRIPT_DIR/ui_run.sh"

fail() {
  echo "ui_run_dispatch_smoke: $*" >&2
  exit 1
}

check_dispatch_case() {
  local name="$1"
  local expected_status="$2"
  local expected_stdout="$3"
  local expected_stderr_substring="$4"
  shift 4

  local stdout_path stderr_path status stdout stderr
  stdout_path="$(mktemp "${TMPDIR:-/tmp}/ui-run-dispatch-stdout.XXXXXX")"
  stderr_path="$(mktemp "${TMPDIR:-/tmp}/ui-run-dispatch-stderr.XXXXXX")"
  if SHADOW_UI_RUN_ECHO_EXEC=1 "$UI_RUN_SCRIPT" "$@" >"$stdout_path" 2>"$stderr_path"; then
    status=0
  else
    status=$?
  fi
  stdout="$(cat "$stdout_path")"
  stderr="$(cat "$stderr_path")"
  rm -f "$stdout_path" "$stderr_path"

  [[ "$status" -eq "$expected_status" ]] || fail "$name status=$status expected=$expected_status"
  [[ "$stdout" == "$expected_stdout" ]] || fail "$name stdout=$stdout expected=$expected_stdout"
  [[ "$stderr" == *"$expected_stderr_substring"* ]] || fail "$name stderr missing substring: $expected_stderr_substring"
}

check_dispatch_case \
  pixel_timeline_hold \
  0 \
  "$(printf 'env=PIXEL_SHELL_START_APP_ID=timeline\ncommand=%s' "$SCRIPT_DIR/pixel_shell_drm_hold.sh")" \
  "target=pixel launches the full home shell and asks it to open timeline" \
  app=timeline target=pixel

check_dispatch_case \
  pixel_shell_no_hold \
  0 \
  "command=$SCRIPT_DIR/pixel_shell_drm.sh" \
  "target=pixel launches the full home shell" \
  app=shell target=pixel hold=0

check_dispatch_case \
  pixel_counter_rejected \
  1 \
  "" \
  "target=pixel currently supports app=shell or app=timeline" \
  app=counter target=pixel

printf 'ui_run_dispatch_smoke: ok\n'
