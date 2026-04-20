#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs

serial="$(pixel_resolve_serial)"
pixel_adb "$serial" get-state >/dev/null
pixel_require_host_lock "$serial" "$0" "$@"

run_root="$(pixel_runs_dir)/gpu-smoke"
run_dir="${PIXEL_GPU_SMOKE_RUN_DIR-}"
if [[ -z "$run_dir" ]]; then
  run_dir="$(pixel_prepare_named_run_dir "$run_root")"
else
  mkdir -p "$run_dir"
fi

device_dir="${PIXEL_GPU_SMOKE_DEVICE_DIR:-/data/local/tmp/shadow-gpu-smoke-gnu}"
device_launcher="$device_dir/run-shadow-gpu-smoke"
device_summary_path="$device_dir/summary.json"
device_ppm_path="$device_dir/shadow-gpu-smoke.ppm"
prepare_output_path="$run_dir/prepare-output.json"
device_command_path="$run_dir/device-command.sh"
device_output_path="$run_dir/device-output.txt"
checkpoint_log_path="$run_dir/checkpoints.txt"
pull_summary_log_path="$run_dir/pull-summary.txt"
pull_ppm_log_path="$run_dir/pull-ppm.txt"
status_path="$run_dir/status.json"
summary_path="$run_dir/summary.json"
ppm_path="$run_dir/shadow-gpu-smoke.ppm"
takeover_display="${PIXEL_GPU_SMOKE_TAKEOVER_DISPLAY-}"
present_kms_requested=false
services_stopped=false
android_restored=false

require_safe_device_dir() {
  local path="$1"
  case "$path" in
    /data/local/tmp/shadow-gpu-smoke* )
      ;;
    * )
      echo "pixel_gpu_smoke: unsafe PIXEL_GPU_SMOKE_DEVICE_DIR: $path" >&2
      echo "expected a path under /data/local/tmp/shadow-gpu-smoke*" >&2
      return 1
      ;;
  esac

  if [[ "$path" == "/data/local/tmp" || "$path" == "/data/local/tmp/" ]]; then
    echo "pixel_gpu_smoke: refusing unsafe device dir root: $path" >&2
    return 1
  fi
}

quote_args() {
  local quoted=()
  local arg
  for arg in "$@"; do
    quoted+=("$(printf '%q' "$arg")")
  done
  printf '%s' "${quoted[*]}"
}

restore_android_display() {
  printf '[gpu-smoke] restoring Android display services\n' | tee -a "$checkpoint_log_path"
  if pixel_restore_android_best_effort "$serial" 30; then
    android_restored=true
    printf '[gpu-smoke] Android display services restored\n' | tee -a "$checkpoint_log_path"
    return 0
  fi

  printf '[gpu-smoke] Android display restore failed\n' | tee -a "$checkpoint_log_path"
  return 1
}

cleanup() {
  if [[ "$takeover_display" == "1" && "$services_stopped" == true && "$android_restored" != true ]]; then
    restore_android_display || true
  fi
}

trap cleanup EXIT

printf '[gpu-smoke] serial=%s\n' "$serial" | tee -a "$checkpoint_log_path"
printf '[gpu-smoke] run_dir=%s\n' "$run_dir" | tee -a "$checkpoint_log_path"
printf '[gpu-smoke] device_dir=%s\n' "$device_dir" | tee -a "$checkpoint_log_path"

require_safe_device_dir "$device_dir"

PIXEL_GPU_SMOKE_DEVICE_DIR="$device_dir" \
  "$SCRIPT_DIR/pixel/pixel_prepare_gpu_smoke_bundle.sh" >"$prepare_output_path"

bundle_dir="$(pixel_artifact_path shadow-gpu-smoke-gnu)"
launcher_artifact="$(pixel_artifact_path run-shadow-gpu-smoke)"
if [[ ! -d "$bundle_dir" || ! -x "$launcher_artifact" ]]; then
  echo "pixel_gpu_smoke: missing prepared gpu-smoke bundle artifacts" >&2
  exit 1
fi

pixel_root_shell "$serial" "
set -e
rm -rf '$device_dir'
" >/dev/null

pixel_adb "$serial" shell "
set -e
mkdir -p '$device_dir'
" >/dev/null

pixel_adb "$serial" push "$bundle_dir/." "$device_dir/" >/dev/null
pixel_adb "$serial" push "$launcher_artifact" "$device_launcher" >/dev/null

device_args=(
  --summary-path "$device_summary_path"
  --ppm-path "$device_ppm_path"
)
if [[ "$#" -gt 0 ]]; then
  device_args+=("$@")
fi

for arg in "${device_args[@]}"; do
  if [[ "$arg" == "--present-kms" ]]; then
    present_kms_requested=true
    break
  fi
done

if [[ -z "$takeover_display" ]]; then
  if [[ "$present_kms_requested" == true ]]; then
    takeover_display=1
  else
    takeover_display=0
  fi
fi

printf '[gpu-smoke] present_kms=%s takeover_display=%s\n' \
  "$present_kms_requested" "$takeover_display" | tee -a "$checkpoint_log_path"

if [[ "$takeover_display" == "1" ]]; then
  printf '[gpu-smoke] stopping Android display services\n' | tee -a "$checkpoint_log_path"
  pixel_root_shell "$serial" "$(pixel_takeover_stop_services_script)" >/dev/null
  if ! pixel_wait_for_condition 15 1 pixel_display_services_stopped "$serial"; then
    echo "pixel_gpu_smoke: Android display services did not stop cleanly" >&2
    exit 1
  fi
  services_stopped=true
  printf '[gpu-smoke] Android display services stopped\n' | tee -a "$checkpoint_log_path"
fi

cat >"$device_command_path" <<EOF
set -e
find '$(printf '%s' "$device_dir")/lib' -maxdepth 1 -type f -name 'ld-linux-*' -exec chmod 0755 {} +
chmod 0755 '$(printf '%s' "$device_dir")/shadow-gpu-smoke' '$(printf '%s' "$device_launcher")'
rm -f '$(printf '%s' "$device_summary_path")' '$(printf '%s' "$device_ppm_path")'
exec $(quote_args "$device_launcher" "${device_args[@]}")
EOF

set +e
pixel_root_shell "$serial" "$(cat "$device_command_path")" >"$device_output_path" 2>&1
run_status="$?"
set -e

summary_pulled=false
ppm_pulled=false
if pixel_root_shell "$serial" "
set -e
if [ -f '$device_summary_path' ]; then
  chmod 0644 '$device_summary_path'
fi
if [ -f '$device_ppm_path' ]; then
  chmod 0644 '$device_ppm_path'
fi
" >/dev/null; then
  :
fi

if pixel_adb "$serial" shell "[ -f '$device_summary_path' ]" >/dev/null 2>&1; then
  pixel_adb "$serial" pull "$device_summary_path" "$summary_path" >"$pull_summary_log_path" 2>&1
  summary_pulled=true
else
  printf 'missing: %s\n' "$device_summary_path" >"$pull_summary_log_path"
fi

if pixel_adb "$serial" shell "[ -f '$device_ppm_path' ]" >/dev/null 2>&1; then
  pixel_adb "$serial" pull "$device_ppm_path" "$ppm_path" >"$pull_ppm_log_path" 2>&1
  ppm_pulled=true
else
  printf 'missing: %s\n' "$device_ppm_path" >"$pull_ppm_log_path"
fi

if [[ "$takeover_display" == "1" ]]; then
  restore_android_display || true
fi

set +e
python3 - "$status_path" "$serial" "$device_dir" "$summary_path" "$ppm_path" "$run_status" "$summary_pulled" "$ppm_pulled" "$present_kms_requested" "$takeover_display" "$android_restored" <<'PY'
import json
import sys
from pathlib import Path

(
    status_path,
    serial,
    device_dir,
    summary_path_raw,
    ppm_path_raw,
    run_status_raw,
    summary_pulled_raw,
    ppm_pulled_raw,
    present_kms_requested_raw,
    takeover_display_raw,
    android_restored_raw,
) = sys.argv[1:12]
summary_path = Path(summary_path_raw)
ppm_path = Path(ppm_path_raw)
run_status = int(run_status_raw)
present_kms_requested = present_kms_requested_raw == "true"
summary_payload = None
summary_error = None
strict_invariants_ok = False
present_kms_ok = False
if summary_path.is_file():
    try:
        summary_payload = json.loads(summary_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        summary_error = f"invalid summary json: {exc}"
else:
    summary_error = "missing pulled summary.json"

if summary_payload is not None:
    adapter = summary_payload.get("adapter") or {}
    strict_invariants_ok = (
        adapter.get("backend") == "Vulkan"
        and summary_payload.get("software_backed") is False
        and summary_payload.get("require_vulkan") is True
        and summary_payload.get("allow_software") is False
    )
    if not strict_invariants_ok and summary_error is None:
        summary_error = "summary did not satisfy strict gpu-smoke invariants"
    if present_kms_requested:
        kms_present = summary_payload.get("kms_present")
        present_kms_ok = (
            summary_payload.get("present_kms") is True
            and isinstance(kms_present, dict)
            and kms_present.get("mode_width")
            and kms_present.get("mode_height")
            and kms_present.get("hold_secs") == summary_payload.get("hold_secs")
            and kms_present.get("source_width") == summary_payload.get("width")
            and kms_present.get("source_height") == summary_payload.get("height")
        )
        if not present_kms_ok and summary_error is None:
            summary_error = "summary did not prove kms presentation"
    else:
        present_kms_ok = True

proof_ok = summary_payload is not None and summary_error is None and strict_invariants_ok and present_kms_ok
run_succeeded = run_status == 0 and proof_ok

payload = {
    "androidRestored": android_restored_raw == "true",
    "serial": serial,
    "deviceDir": device_dir,
    "runSucceeded": run_succeeded,
    "exitStatus": run_status,
    "proofOk": proof_ok,
    "summaryPulled": summary_pulled_raw == "true",
    "ppmPulled": ppm_pulled_raw == "true",
    "summaryPath": str(summary_path) if summary_path.is_file() else None,
    "ppmPath": str(ppm_path) if ppm_path.is_file() else None,
    "strictInvariantsOk": strict_invariants_ok,
    "presentKmsRequested": present_kms_requested,
    "presentKmsOk": present_kms_ok,
    "takeoverDisplay": takeover_display_raw == "1",
    "summaryError": summary_error,
    "summary": summary_payload,
}

with open(status_path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")

print(json.dumps(payload, indent=2, sort_keys=True))
raise SystemExit(0 if run_succeeded else 1)
PY
status_check="$?"
set -e

if [[ "$run_status" -ne 0 ]]; then
  echo "pixel_gpu_smoke: device run failed; see $device_output_path" >&2
  exit "$run_status"
fi

if [[ "$status_check" -ne 0 ]]; then
  echo "pixel_gpu_smoke: missing or invalid pulled summary proof; see $status_path" >&2
  exit "$status_check"
fi

cat "$status_path"
