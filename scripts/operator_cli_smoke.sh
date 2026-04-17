#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHADOWCTL_SCRIPT="$SCRIPT_DIR/shadowctl"
PYTHON3_BIN="$(command -v python3)"
TMP_FILES=()

cleanup() {
  if ((${#TMP_FILES[@]})); then
    rm -f "${TMP_FILES[@]}"
  fi
}
trap cleanup EXIT

fail() {
  echo "operator_cli_smoke: $*" >&2
  exit 1
}

mktemp_tracked() {
  local path
  path="$(mktemp "${TMPDIR:-/tmp}/operator-cli.XXXXXX")"
  TMP_FILES+=("$path")
  printf '%s\n' "$path"
}

check_output_case() {
  local name="$1"
  local expected_status="$2"
  local expected_stdout="$3"
  local expected_stderr_substring="$4"
  shift 4

  local stdout_path stderr_path status stdout stderr
  stdout_path="$(mktemp_tracked)"
  stderr_path="$(mktemp_tracked)"

  set +e
  (cd "$REPO_ROOT" && "$@") >"$stdout_path" 2>"$stderr_path"
  status=$?
  set -e

  stdout="$(cat "$stdout_path")"
  stderr="$(cat "$stderr_path")"

  [[ "$status" -eq "$expected_status" ]] || fail "$name status=$status expected=$expected_status"
  [[ "$stdout" == "$expected_stdout" ]] || fail "$name stdout=$stdout expected=$expected_stdout"
  [[ "$stderr" == *"$expected_stderr_substring"* ]] || fail "$name stderr missing substring: $expected_stderr_substring"
}

check_stdout_contains() {
  local name="$1"
  local expected_status="$2"
  local expected_substring="$3"
  shift 3

  local stdout_path stderr_path status stdout stderr
  stdout_path="$(mktemp_tracked)"
  stderr_path="$(mktemp_tracked)"

  set +e
  (cd "$REPO_ROOT" && "$@") >"$stdout_path" 2>"$stderr_path"
  status=$?
  set -e

  stdout="$(cat "$stdout_path")"
  stderr="$(cat "$stderr_path")"

  [[ "$status" -eq "$expected_status" ]] || fail "$name status=$status expected=$expected_status stderr=$stderr"
  local combined="$stdout
$stderr"
  [[ "$combined" == *"$expected_substring"* ]] || fail "$name output missing substring: $expected_substring"
}

check_stdout_contains \
  just_run_uses_shadowctl_run_flags \
  0 \
  'exec scripts/shadowctl run -t "$target_arg" --app "$app_arg" --hold "$hold_arg"' \
  just --dry-run run target=vm app=camera

check_output_case \
  just_run_named_args_any_order \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --app timeline' "$SCRIPT_DIR/pixel_shell_drm.sh")" \
  "" \
  env SHADOWCTL_JUST_DRY_RUN=1 just run app=timeline target=TESTSERIAL hold=0

check_stdout_contains \
  just_stop_uses_shadowctl_flags \
  0 \
  'exec scripts/shadowctl stop -t "$target_arg"' \
  just --dry-run stop target=TESTSERIAL

check_output_case \
  just_stop_named_arg \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel_restore_android.sh")" \
  "" \
  env SHADOWCTL_JUST_DRY_RUN=1 just stop target=TESTSERIAL

check_output_case \
  just_pixel_ci_routes_through_shadowctl \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s camera' "$SCRIPT_DIR/pixel_ci.sh")" \
  "" \
  env SHADOWCTL_JUST_DRY_RUN=1 just pixel-ci --target TESTSERIAL camera

check_output_case \
  just_pixel_stage_routes_through_shadowctl \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --stage-only sound' "$SCRIPT_DIR/pixel_ci.sh")" \
  "" \
  env SHADOWCTL_JUST_DRY_RUN=1 just pixel-stage --target TESTSERIAL sound

check_output_case \
  just_pixel_run_routes_through_shadowctl \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --run-only podcast' "$SCRIPT_DIR/pixel_ci.sh")" \
  "" \
  env SHADOWCTL_JUST_DRY_RUN=1 just pixel-run --target TESTSERIAL podcast

check_output_case \
  shadowctl_run_vm_default \
  0 \
  "command=$SCRIPT_DIR/ui_vm_run.sh" \
  "" \
  "$SHADOWCTL_SCRIPT" run --dry-run -t vm --app shell

check_output_case \
  shadowctl_run_vm_camera \
  0 \
  "$(printf 'command=%s --app camera' "$SCRIPT_DIR/ui_vm_run.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" run --dry-run -t vm --app camera

check_output_case \
  shadowctl_run_pixel_timeline \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --app timeline' "$SCRIPT_DIR/pixel_shell_drm_hold.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" run --dry-run -t TESTSERIAL --app timeline

check_output_case \
  shadowctl_run_pixel_no_hold \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel_shell_drm.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" run --dry-run -t TESTSERIAL --app shell --hold 0

check_output_case \
  shadowctl_global_target_before_command \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --app timeline' "$SCRIPT_DIR/pixel_shell_drm_hold.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" -t TESTSERIAL run --dry-run --app timeline

check_output_case \
  shadowctl_conflicting_targets_rejected \
  2 \
  "" \
  "conflicting targets" \
  "$SHADOWCTL_SCRIPT" -t vm run -t pixel --dry-run

check_output_case \
  shadowctl_pixel_colon_serial_rejected \
  1 \
  "" \
  "target 'pixel:<serial>' was removed; use the raw adb serial" \
  "$SHADOWCTL_SCRIPT" run --dry-run -t pixel:TESTSERIAL

check_output_case \
  shadowctl_stop_vm \
  0 \
  "command=$SCRIPT_DIR/ui_vm_stop.sh" \
  "" \
  "$SHADOWCTL_SCRIPT" stop --dry-run -t vm

check_output_case \
  shadowctl_stop_pixel \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel_restore_android.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" stop --dry-run -t TESTSERIAL

check_output_case \
  shadowctl_pixel_ci_camera \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s camera' "$SCRIPT_DIR/pixel_ci.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" ci --dry-run -t TESTSERIAL camera

check_output_case \
  shadowctl_pixel_stage_sound \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --stage-only sound' "$SCRIPT_DIR/pixel_ci.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" stage --dry-run -t TESTSERIAL sound

check_output_case \
  shadowctl_pixel_debug_latency \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel_touch_latency_probe.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" debug --dry-run -t TESTSERIAL latency

check_output_case \
  shadowctl_pixel_ci_run_only_podcast \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --run-only podcast' "$SCRIPT_DIR/pixel_ci.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" ci --dry-run --run-only -t TESTSERIAL podcast

check_output_case \
  shadowctl_root_prep \
  0 \
  "command=$SCRIPT_DIR/pixel_root_prep.sh" \
  "" \
  "$SHADOWCTL_SCRIPT" root-prep --dry-run

check_output_case \
  shadowctl_root_patch \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel_root_patch.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" root-patch --dry-run -t TESTSERIAL

check_output_case \
  shadowctl_root_stage \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel_root_stage.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" root-stage --dry-run -t TESTSERIAL

check_output_case \
  shadowctl_root_flash \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel_root_flash.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" root-flash --dry-run -t TESTSERIAL

check_output_case \
  shadowctl_ota_sideload \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel_ota_sideload.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" ota-sideload --dry-run -t TESTSERIAL

check_output_case \
  shadowctl_root_check_dry_run \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel_root_check.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" root-check --dry-run -t TESTSERIAL

check_output_case \
  shadowctl_restore_android_dry_run \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel_restore_android.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" restore-android --dry-run -t TESTSERIAL

check_output_case \
  desktop_target_rejected \
  1 \
  "" \
  "target 'desktop' was removed; use 'vm'" \
  "$SHADOWCTL_SCRIPT" run --dry-run -t desktop

check_output_case \
  legacy_target_token_rejected \
  2 \
  "" \
  "unrecognized arguments: target=vm" \
  "$SHADOWCTL_SCRIPT" run --dry-run target=vm

check_output_case \
  unknown_app_rejected \
  2 \
  "" \
  "invalid choice: 'unknown'" \
  "$SHADOWCTL_SCRIPT" run --dry-run -t vm --app unknown

check_output_case \
  unsupported_pixel_journal_rejected_before_adb_resolution \
  2 \
  "" \
  "journal supports targets: vm; got pixel (pixel)" \
  "$SHADOWCTL_SCRIPT" -t pixel journal

check_output_case \
  unsupported_pixel_ssh_rejected_before_adb_resolution \
  2 \
  "" \
  "ssh supports targets: vm; got pixel (pixel)" \
  "$SHADOWCTL_SCRIPT" -t pixel ssh

check_output_case \
  unsupported_vm_root_check_rejected \
  2 \
  "" \
  "root-check supports targets: pixel; got vm (vm)" \
  "$SHADOWCTL_SCRIPT" -t vm root-check

check_output_case \
  unsupported_vm_stage_rejected \
  2 \
  "" \
  "stage supports targets: pixel; got vm (vm)" \
  "$SHADOWCTL_SCRIPT" -t vm stage --dry-run camera

check_output_case \
  unsupported_vm_debug_rejected \
  2 \
  "" \
  "debug supports targets: pixel; got vm (vm)" \
  "$SHADOWCTL_SCRIPT" -t vm debug --dry-run latency

check_output_case \
  unsupported_vm_root_patch_rejected \
  2 \
  "" \
  "root-patch supports targets: pixel; got vm (vm)" \
  "$SHADOWCTL_SCRIPT" -t vm root-patch --dry-run

check_output_case \
  root_prep_rejects_target \
  2 \
  "" \
  "root-prep does not accept --target" \
  "$SHADOWCTL_SCRIPT" -t TESTSERIAL root-prep --dry-run

check_output_case \
  pixel_ci_mode_conflict_rejected \
  1 \
  "" \
  "--stage-only and --run-only are mutually exclusive" \
  "$SHADOWCTL_SCRIPT" -t TESTSERIAL ci --dry-run --stage-only --run-only camera

check_stdout_contains \
  sc_help_uses_sc_prog \
  0 \
  "usage: sc" \
  env SHADOWCTL_PROG=sc "$SHADOWCTL_SCRIPT" --help

check_stdout_contains \
  shadowctl_ssh_help_stays_in_argparse \
  0 \
  "SSH into the VM target." \
  "$SHADOWCTL_SCRIPT" -t vm ssh --help

check_stdout_contains \
  shadowctl_ssh_local_target_help_stays_in_argparse \
  0 \
  "SSH into the VM target." \
  "$SHADOWCTL_SCRIPT" ssh -t vm --help

check_stdout_contains \
  shadowctl_devices_adb_missing_is_best_effort \
  0 \
  "adb" \
  env PATH=/usr/bin:/bin "$PYTHON3_BIN" "$SHADOWCTL_SCRIPT" devices

printf 'operator_cli_smoke: ok\n'
