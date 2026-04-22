#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHADOWCTL_SCRIPT="$SCRIPT_DIR/shadowctl"
PYTHON3_BIN="$(command -v python3)"
TMP_FILES=()

cleanup() {
  if ((${#TMP_FILES[@]})); then
    rm -rf "${TMP_FILES[@]}"
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

mktemp_dir_tracked() {
  local path
  path="$(mktemp -d "${TMPDIR:-/tmp}/operator-cli.XXXXXX")"
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

check_json_python_case() {
  local name="$1"
  local expected_status="$2"
  local python_check="$3"
  shift 3

  local stdout_path stderr_path status stderr
  stdout_path="$(mktemp_tracked)"
  stderr_path="$(mktemp_tracked)"

  set +e
  (cd "$REPO_ROOT" && "$@") >"$stdout_path" 2>"$stderr_path"
  status=$?
  set -e

  stderr="$(cat "$stderr_path")"
  [[ "$status" -eq "$expected_status" ]] || fail "$name status=$status expected=$expected_status stderr=$stderr"

  JSON_CHECK="$python_check" "$PYTHON3_BIN" - "$stdout_path" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)

namespace = {"payload": payload}
exec(os.environ["JSON_CHECK"], {}, namespace)
PY
}

mixed_model_manifest="$(mktemp_tracked)"
cat >"$mixed_model_manifest" <<'JSON'
{
  "schemaVersion": 1,
  "shell": {
    "id": "shell",
    "waylandAppId": "dev.shadow.shell"
  },
  "apps": [
    {
      "id": "mixed-ts",
      "model": "typescript",
      "title": "Mixed TS",
      "iconLabel": "TS",
      "subtitle": "TypeScript lane",
      "lifecycleHint": "Mixed TypeScript app.",
      "binaryName": "shadow-blitz-demo",
      "waylandAppId": "dev.shadow.mixed-ts",
      "windowTitle": "Mixed TS",
      "runtime": {
        "bundleEnv": "SHADOW_RUNTIME_APP_MIXED_TS_BUNDLE_PATH",
        "bundleFilename": "runtime-app-mixed-ts-bundle.js",
        "inputPath": "runtime/app-counter/app.tsx",
        "cacheDirs": {
          "vm-shell": "build/runtime/mixed-ts-vm",
          "pixel-shell": "build/runtime/mixed-ts-pixel"
        },
        "config": null
      },
      "profiles": ["vm-shell", "pixel-shell"],
      "ui": {
        "iconColor": "ICON_CYAN"
      }
    },
    {
      "id": "mixed-rust",
      "model": "rust",
      "title": "Mixed Rust",
      "iconLabel": "RS",
      "subtitle": "Rust lane",
      "lifecycleHint": "Mixed Rust app.",
      "binaryName": "shadow-rust-demo",
      "waylandAppId": "dev.shadow.mixed-rust",
      "windowTitle": "Mixed Rust",
      "profiles": ["vm-shell"],
      "ui": {
        "iconColor": "ICON_GREEN"
      }
    }
  ]
}
JSON

check_stdout_contains \
  just_run_uses_shadowctl_run_flags \
  0 \
  'exec scripts/shadowctl run --dry-run -t "$target_arg" --app "$app_arg" --hold "$hold_arg"' \
  just --dry-run run target=vm app=camera

check_output_case \
  just_run_named_args_any_order \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --no-camera-runtime --app timeline' "$SCRIPT_DIR/pixel/pixel_shell_drm.sh")" \
  "" \
  env SHADOWCTL_JUST_DRY_RUN=1 just run app=timeline target=TESTSERIAL hold=0

check_output_case \
  just_run_vm_defaults_to_podcast \
  0 \
  "$(printf 'command=%s --app podcast' "$SCRIPT_DIR/vm/ui_vm_run.sh")" \
  "" \
  env SHADOWCTL_JUST_DRY_RUN=1 just run target=vm

check_output_case \
  just_run_pixel_defaults_to_shell \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel/pixel_shell_drm_hold.sh")" \
  "" \
  env SHADOWCTL_JUST_DRY_RUN=1 just run target=TESTSERIAL

check_stdout_contains \
  just_stop_uses_shadowctl_flags \
  0 \
  'exec scripts/shadowctl stop -t "$target_arg"' \
  just --dry-run stop target=TESTSERIAL

check_output_case \
  just_stop_named_arg \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel/pixel_restore_android.sh")" \
  "" \
  env SHADOWCTL_JUST_DRY_RUN=1 just stop target=TESTSERIAL

check_output_case \
  just_pixel_ci_routes_through_shadowctl \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s camera' "$SCRIPT_DIR/ci/pixel_ci.sh")" \
  "" \
  env SHADOWCTL_JUST_DRY_RUN=1 just pixel-ci --target TESTSERIAL camera

check_output_case \
  just_pixel_stage_routes_through_shadowctl \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --stage-only sound' "$SCRIPT_DIR/ci/pixel_ci.sh")" \
  "" \
  env SHADOWCTL_JUST_DRY_RUN=1 just pixel-stage --target TESTSERIAL sound

check_output_case \
  just_pixel_run_routes_through_shadowctl \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --run-only podcast' "$SCRIPT_DIR/ci/pixel_ci.sh")" \
  "" \
  env SHADOWCTL_JUST_DRY_RUN=1 just pixel-run --target TESTSERIAL podcast

check_stdout_contains \
  just_pixel_runtime_drm_routes_through_shadowctl_debug \
  0 \
  'exec scripts/shadowctl debug --dry-run -t "$target_arg" runtime-drm' \
  just --dry-run pixel-runtime-app-drm

check_output_case \
  just_pixel_runtime_drm_named_serial \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel/pixel_runtime_app_drm.sh")" \
  "" \
  env SHADOWCTL_JUST_DRY_RUN=1 PIXEL_SERIAL=TESTSERIAL just pixel-runtime-app-drm

check_stdout_contains \
  just_pixel_runtime_drm_gpu_probe_routes_through_shadowctl_debug \
  0 \
  'exec scripts/shadowctl debug --dry-run -t "$target_arg" runtime-drm-gpu-probe --profile "vulkan_kgsl_first"' \
  just --dry-run pixel-runtime-app-drm-gpu-probe

check_output_case \
  just_pixel_runtime_drm_gpu_probe_named_serial \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s gl_kgsl' "$SCRIPT_DIR/pixel/pixel_runtime_app_drm_gpu_probe.sh")" \
  "" \
  env SHADOWCTL_JUST_DRY_RUN=1 PIXEL_SERIAL=TESTSERIAL just pixel-runtime-app-drm-gpu-probe profile=gl_kgsl

check_stdout_contains \
  just_pixel_runtime_drm_gpu_matrix_routes_through_shadowctl_debug \
  0 \
  'exec scripts/shadowctl debug --dry-run -t "$target_arg" runtime-drm-gpu-matrix' \
  just --dry-run pixel-runtime-app-drm-gpu-matrix

check_output_case \
  just_pixel_runtime_drm_gpu_matrix_named_serial \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel/pixel_runtime_app_drm_gpu_matrix.sh")" \
  "" \
  env SHADOWCTL_JUST_DRY_RUN=1 PIXEL_SERIAL=TESTSERIAL just pixel-runtime-app-drm-gpu-matrix

check_stdout_contains \
  just_pixel_prep_settings_routes_through_shadowctl \
  0 \
  'exec scripts/shadowctl prep-settings --dry-run -t "$target_arg"' \
  just --dry-run pixel-prep-settings

check_output_case \
  just_pixel_prep_settings_named_serial \
  0 \
  "$(cat <<'EOF'
command=adb -s TESTSERIAL shell settings put global stay_on_while_plugged_in 15
command=adb -s TESTSERIAL shell settings put system screen_off_timeout 1800000
command=adb -s TESTSERIAL shell settings put secure screensaver_enabled 0
command=adb -s TESTSERIAL shell settings put secure screensaver_activate_on_dock 0
command=adb -s TESTSERIAL shell settings put secure screensaver_activate_on_sleep 0
command=adb -s TESTSERIAL shell locksettings set-disabled true
command=adb -s TESTSERIAL shell input keyevent KEYCODE_WAKEUP
command=adb -s TESTSERIAL shell wm dismiss-keyguard
EOF
)" \
  "" \
  env SHADOWCTL_JUST_DRY_RUN=1 PIXEL_SERIAL=TESTSERIAL just pixel-prep-settings

check_stdout_contains \
  just_pixel_restore_android_routes_through_shadowctl \
  0 \
  'exec scripts/shadowctl restore-android --dry-run -t "$target_arg"' \
  just --dry-run pixel-restore-android

check_output_case \
  shadowctl_run_vm_default_podcast \
  0 \
  "$(printf 'command=%s --app podcast' "$SCRIPT_DIR/vm/ui_vm_run.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" run --dry-run -t vm

check_output_case \
  shadowctl_run_pixel_default_shell \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel/pixel_shell_drm_hold.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" run --dry-run -t TESTSERIAL

check_output_case \
  shadowctl_run_vm_shell \
  0 \
  "command=$SCRIPT_DIR/vm/ui_vm_run.sh" \
  "" \
  "$SHADOWCTL_SCRIPT" run --dry-run -t vm --app shell

check_output_case \
  shadowctl_run_vm_camera \
  0 \
  "$(printf 'command=%s --app camera' "$SCRIPT_DIR/vm/ui_vm_run.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" run --dry-run -t vm --app camera

check_output_case \
  shadowctl_run_vm_mixed_rust \
  0 \
  "$(printf 'command=%s --app mixed-rust' "$SCRIPT_DIR/vm/ui_vm_run.sh")" \
  "" \
  env SHADOW_APP_METADATA_MANIFEST="$mixed_model_manifest" \
    "$SHADOWCTL_SCRIPT" run --dry-run -t vm --app mixed-rust

check_output_case \
  shadowctl_run_pixel_rejects_mixed_rust \
  1 \
  "" \
  "unsupported app 'mixed-rust'" \
  env SHADOW_APP_METADATA_MANIFEST="$mixed_model_manifest" \
    "$SHADOWCTL_SCRIPT" run --dry-run -t TESTSERIAL --app mixed-rust

check_output_case \
  session_apps_helper_vm_lists_mixed_rust \
  0 \
  "$(printf 'shell\nmixed-ts\nmixed-rust')" \
  "" \
  env SHADOW_APP_METADATA_MANIFEST="$mixed_model_manifest" SHADOW_SESSION_APP_PROFILE=vm-shell \
    bash -lc 'cd "$0" && source scripts/lib/session_apps.sh && shadow_load_session_apps && printf "%s\n" "${shadow_session_apps[@]}"' "$REPO_ROOT"

check_output_case \
  session_apps_helper_pixel_keeps_typescript_only \
  0 \
  "$(printf 'shell\nmixed-ts')" \
  "" \
  env SHADOW_APP_METADATA_MANIFEST="$mixed_model_manifest" SHADOW_SESSION_APP_PROFILE=pixel-shell \
    bash -lc 'cd "$0" && source scripts/lib/session_apps.sh && shadow_load_session_apps && printf "%s\n" "${shadow_session_apps[@]}"' "$REPO_ROOT"

check_output_case \
  shadowctl_run_pixel_timeline \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --no-camera-runtime --app timeline' "$SCRIPT_DIR/pixel/pixel_shell_drm_hold.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" run --dry-run -t TESTSERIAL --app timeline

check_output_case \
  shadowctl_run_pixel_camera \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --camera-runtime --app camera' "$SCRIPT_DIR/pixel/pixel_shell_drm_hold.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" run --dry-run -t TESTSERIAL --app camera

check_output_case \
  shadowctl_run_pixel_no_hold \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel/pixel_shell_drm.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" run --dry-run -t TESTSERIAL --app shell --hold 0

check_output_case \
  shadowctl_global_target_before_command \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --no-camera-runtime --app timeline' "$SCRIPT_DIR/pixel/pixel_shell_drm_hold.sh")" \
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
  "command=$SCRIPT_DIR/vm/ui_vm_stop.sh" \
  "" \
  "$SHADOWCTL_SCRIPT" stop --dry-run -t vm

check_output_case \
  shadowctl_stop_pixel \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel/pixel_restore_android.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" stop --dry-run -t TESTSERIAL

check_output_case \
  shadowctl_pixel_ci_camera \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s camera' "$SCRIPT_DIR/ci/pixel_ci.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" ci --dry-run -t TESTSERIAL camera

check_output_case \
  shadowctl_pixel_stage_sound \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --stage-only sound' "$SCRIPT_DIR/ci/pixel_ci.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" stage --dry-run -t TESTSERIAL sound

check_output_case \
  shadowctl_pixel_debug_latency \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/debug/pixel_touch_latency_probe.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" debug --dry-run -t TESTSERIAL latency

check_output_case \
  shadowctl_pixel_debug_runtime_drm \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel/pixel_runtime_app_drm.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" debug --dry-run -t TESTSERIAL runtime-drm

check_output_case \
  shadowctl_pixel_debug_runtime_drm_gpu_probe \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s vulkan_kgsl_first' "$SCRIPT_DIR/pixel/pixel_runtime_app_drm_gpu_probe.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" debug --dry-run -t TESTSERIAL runtime-drm-gpu-probe --profile vulkan_kgsl_first

check_output_case \
  shadowctl_pixel_debug_runtime_drm_gpu_matrix \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel/pixel_runtime_app_drm_gpu_matrix.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" debug --dry-run -t TESTSERIAL runtime-drm-gpu-matrix

check_output_case \
  shadowctl_pixel_debug_boot_lab_flash_run \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --image /tmp/probe.img --slot inactive --output /tmp/flash-out --wait-ready 30 --adb-timeout 45 --boot-timeout 60 --allow-active-slot --recover-after --proof-prop debug.shadow.boot.rc_probe=ready' "$SCRIPT_DIR/pixel/pixel_boot_flash_run.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" debug --dry-run -t TESTSERIAL boot-lab-flash-run \
    --image /tmp/probe.img \
    --slot inactive \
    --output /tmp/flash-out \
    --wait-ready 30 \
    --adb-timeout 45 \
    --boot-timeout 60 \
    --allow-active-slot \
    --recover-after \
    --proof-prop debug.shadow.boot.rc_probe=ready

check_output_case \
  shadowctl_pixel_debug_boot_lab_flash_run_fastboot_return \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --image /tmp/probe.img --slot inactive --output /tmp/flash-out --success-signal fastboot-return --return-timeout 45 --recover-after' "$SCRIPT_DIR/pixel/pixel_boot_flash_run.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" debug --dry-run -t TESTSERIAL boot-lab-flash-run \
    --image /tmp/probe.img \
    --slot inactive \
    --output /tmp/flash-out \
    --success-signal fastboot-return \
    --return-timeout 45 \
    --recover-after

check_output_case \
  shadowctl_pixel_debug_boot_lab_oneshot \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --image /tmp/probe.img --output /tmp/boot-out --wait-ready 30 --adb-timeout 45 --boot-timeout 60 --no-wait-boot-completed --proof-prop debug.shadow.boot.rc_probe=ready' "$SCRIPT_DIR/pixel/pixel_boot_oneshot.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" debug --dry-run -t TESTSERIAL boot-lab-oneshot \
    --image /tmp/probe.img \
    --output /tmp/boot-out \
    --wait-ready 30 \
    --adb-timeout 45 \
    --boot-timeout 60 \
    --no-wait-boot-completed \
    --proof-prop debug.shadow.boot.rc_probe=ready

check_output_case \
  shadowctl_pixel_debug_boot_lab_oneshot_fastboot_return \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --image /tmp/probe.img --output /tmp/boot-out --success-signal fastboot-return --return-timeout 45' "$SCRIPT_DIR/pixel/pixel_boot_oneshot.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" debug --dry-run -t TESTSERIAL boot-lab-oneshot \
    --image /tmp/probe.img \
    --output /tmp/boot-out \
    --success-signal fastboot-return \
    --return-timeout 45

check_output_case \
  shadowctl_pixel_debug_boot_lab_oneshot_adb_return_private \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --image /tmp/probe.img --output /tmp/boot-out --adb-timeout 45 --boot-timeout 60 --skip-collect --recover-traces-after' "$SCRIPT_DIR/pixel/pixel_boot_oneshot.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" debug --dry-run -t TESTSERIAL boot-lab-oneshot \
    --image /tmp/probe.img \
    --output /tmp/boot-out \
    --adb-timeout 45 \
    --boot-timeout 60 \
    --skip-collect \
    --recover-traces-after

check_output_case \
  shadowctl_pixel_debug_boot_lab_rust_bridge_run \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --input /tmp/base.img --output-dir /tmp/rust-bridge-out --image-output /tmp/rust-bridge.img --shim-mode exec --child-profile std-probe --adb-timeout 45 --boot-timeout 60 --skip-collect --recover-traces-after' "$SCRIPT_DIR/pixel/pixel_boot_rust_bridge_run.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" debug --dry-run -t TESTSERIAL boot-lab-rust-bridge-run \
    --input /tmp/base.img \
    --output /tmp/rust-bridge-out \
    --image-output /tmp/rust-bridge.img \
    --shim-mode exec \
    --child-profile std-probe \
    --adb-timeout 45 \
    --boot-timeout 60 \
    --skip-collect \
    --recover-traces-after

check_output_case \
  shadowctl_pixel_debug_boot_lab_preflight \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --input /tmp/stock.img --output-dir /tmp/preflight-out --adb-timeout 45 --boot-timeout 60 --recover-traces-after --patch-target init.recovery.rc --trigger post-fs-data --trigger property:init.svc.gpu=running' "$SCRIPT_DIR/pixel/pixel_boot_preflight.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" debug --dry-run -t TESTSERIAL boot-lab-preflight \
    --input /tmp/stock.img \
    --output /tmp/preflight-out \
    --adb-timeout 45 \
    --boot-timeout 60 \
    --patch-target init.recovery.rc \
    --trigger post-fs-data \
    --trigger property:init.svc.gpu=running \
    --recover-traces-after

check_output_case \
  shadowctl_pixel_debug_boot_lab_recover_traces \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --output /tmp/recover-out' "$SCRIPT_DIR/pixel/pixel_boot_recover_traces.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" debug --dry-run -t TESTSERIAL boot-lab-recover-traces \
    --output /tmp/recover-out

check_output_case \
  shadowctl_pixel_debug_boot_lab_rc_trigger_ladder \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --input /tmp/stock.img --output-dir /tmp/trigger-out --adb-timeout 45 --boot-timeout 60 --property-key debug.shadow.boot.rc_probe --trigger post-fs-data --trigger property:init.svc.gpu=running' "$SCRIPT_DIR/pixel/pixel_boot_rc_trigger_ladder.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" debug --dry-run -t TESTSERIAL boot-lab-rc-trigger-ladder \
    --input /tmp/stock.img \
    --output /tmp/trigger-out \
    --adb-timeout 45 \
    --boot-timeout 60 \
    --property-key debug.shadow.boot.rc_probe \
    --trigger post-fs-data \
    --trigger property:init.svc.gpu=running

check_output_case \
  shadowctl_pixel_ci_run_only_podcast \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s --run-only podcast' "$SCRIPT_DIR/ci/pixel_ci.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" ci --dry-run --run-only -t TESTSERIAL podcast

check_output_case \
  shadowctl_root_prep \
  0 \
  "command=$SCRIPT_DIR/pixel/pixel_root_prep.sh" \
  "" \
  "$SHADOWCTL_SCRIPT" root-prep --dry-run

check_output_case \
  shadowctl_root_patch \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel/pixel_root_patch.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" root-patch --dry-run -t TESTSERIAL

check_output_case \
  shadowctl_root_stage \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel/pixel_root_stage.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" root-stage --dry-run -t TESTSERIAL

check_output_case \
  shadowctl_root_flash \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel/pixel_root_flash.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" root-flash --dry-run -t TESTSERIAL

check_output_case \
  shadowctl_ota_sideload \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel/pixel_ota_sideload.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" ota-sideload --dry-run -t TESTSERIAL

check_output_case \
  shadowctl_root_check_dry_run \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel/pixel_root_check.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" root-check --dry-run -t TESTSERIAL

check_output_case \
  shadowctl_restore_android_dry_run \
  0 \
  "$(printf 'env=PIXEL_SERIAL=TESTSERIAL\ncommand=%s' "$SCRIPT_DIR/pixel/pixel_restore_android.sh")" \
  "" \
  "$SHADOWCTL_SCRIPT" restore-android --dry-run -t TESTSERIAL

check_output_case \
  shadowctl_prep_settings_dry_run \
  0 \
  "$(cat <<'EOF'
command=adb -s TESTSERIAL shell settings put global stay_on_while_plugged_in 15
command=adb -s TESTSERIAL shell settings put system screen_off_timeout 1800000
command=adb -s TESTSERIAL shell settings put secure screensaver_enabled 0
command=adb -s TESTSERIAL shell settings put secure screensaver_activate_on_dock 0
command=adb -s TESTSERIAL shell settings put secure screensaver_activate_on_sleep 0
command=adb -s TESTSERIAL shell locksettings set-disabled true
command=adb -s TESTSERIAL shell input keyevent KEYCODE_WAKEUP
command=adb -s TESTSERIAL shell wm dismiss-keyguard
EOF
)" \
  "" \
  "$SHADOWCTL_SCRIPT" prep-settings --dry-run -t TESTSERIAL

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
  1 \
  "" \
  "unsupported app 'unknown'" \
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

lease_common_root="$(mktemp_dir_tracked)"
lease_serial="LEASESERIAL01"

check_json_python_case \
  shadowctl_lease_list_empty \
  0 \
  "assert payload == []" \
  env SHADOW_REPO_COMMON_ROOT="$lease_common_root" "$PYTHON3_BIN" "$SHADOWCTL_SCRIPT" lease list --json

check_json_python_case \
  shadowctl_lease_acquire \
  0 \
  "assert payload['action'] == 'acquired'; assert payload['serial'] == 'LEASESERIAL01'; assert payload['lane'] == 'stream-b'; assert payload['owner'] == 'boot-2'; assert payload['agent'] == 'alpha'; assert payload['status'] == 'active'; assert payload['lease_id']" \
  env SHADOW_REPO_COMMON_ROOT="$lease_common_root" SHADOW_DEVICE_LEASE_AGENT=alpha "$PYTHON3_BIN" "$SHADOWCTL_SCRIPT" lease acquire "$lease_serial" --lane stream-b --owner boot-2 --ttl 15m --json

check_json_python_case \
  shadowctl_lease_show \
  0 \
  "assert payload['leased'] is True; assert payload['serial'] == 'LEASESERIAL01'; assert payload['agent'] == 'alpha'; assert payload['status'] == 'active'" \
  env SHADOW_REPO_COMMON_ROOT="$lease_common_root" "$PYTHON3_BIN" "$SHADOWCTL_SCRIPT" lease show "$lease_serial" --json

check_stdout_contains \
  shadowctl_lease_conflict \
  1 \
  "active lease on LEASESERIAL01 held by boot-2 lane=stream-b" \
  env SHADOW_REPO_COMMON_ROOT="$lease_common_root" SHADOW_DEVICE_LEASE_AGENT=beta "$PYTHON3_BIN" "$SHADOWCTL_SCRIPT" lease acquire "$lease_serial" --lane stream-c

check_json_python_case \
  shadowctl_lease_release \
  0 \
  "assert payload['action'] == 'released'; assert payload['serial'] == 'LEASESERIAL01'" \
  env SHADOW_REPO_COMMON_ROOT="$lease_common_root" SHADOW_DEVICE_LEASE_AGENT=alpha "$PYTHON3_BIN" "$SHADOWCTL_SCRIPT" lease release "$lease_serial" --json

check_json_python_case \
  shadowctl_lease_list_empty_after_release \
  0 \
  "assert payload == []" \
  env SHADOW_REPO_COMMON_ROOT="$lease_common_root" "$PYTHON3_BIN" "$SHADOWCTL_SCRIPT" lease list --json

printf 'operator_cli_smoke: ok\n'
