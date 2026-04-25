#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/shadow_common.sh
source "$SCRIPT_DIR/../lib/shadow_common.sh"
# shellcheck source=../lib/ci_common.sh
source "$SCRIPT_DIR/../lib/ci_common.sh"
# shellcheck source=../lib/pixel_common.sh
source "$SCRIPT_DIR/../lib/pixel_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

run_id="${SHADOW_CI_RUN_ID:-$(shadow_ci_run_id)}"
run_token="${RUN_TOKEN:-pre-merge-${run_id}}"
output_root="${OUTPUT_ROOT:-build/pixel/runs/pre-merge-proof}"
hold_secs="${HOLD_SECS:-1}"
watchdog_secs="${WATCHDOG_SECS:-60}"
start_app="${START_APP:-rust-demo}"
lease_agent="${SHADOW_DEVICE_LEASE_AGENT:-pre-merge-${run_id}}"
lease_owner="${SHADOW_DEVICE_LEASE_OWNER:-pre-merge}"
lease_ttl="${SHADOW_PIXEL_PRE_MERGE_LEASE_TTL:-7200}"
selected_serial=""
asset_root="$output_root/$run_token/boot-assets"
firmware_dir="$asset_root/firmware"
input_module_dir="$asset_root/input-modules"

release_selected_serial() {
  if [[ -z "$selected_serial" ]]; then
    return 0
  fi
  scripts/shadowctl lease release "$selected_serial" --agent "$lease_agent" >/dev/null 2>&1 || true
}
trap release_selected_serial EXIT

if [[ ! "$hold_secs" =~ ^[0-9]+$ || ! "$watchdog_secs" =~ ^[0-9]+$ ]]; then
  echo "pixel_pre_merge_proof: HOLD_SECS and WATCHDOG_SECS must be integers" >&2
  exit 64
fi

mapfile -t candidate_serials < <(
  scripts/shadowctl devices --json | python3 -c '
import json
import sys

entries = json.load(sys.stdin)
for entry in entries:
    if entry.get("kind") != "pixel":
        continue
    if entry.get("state") != "device":
        continue
    if entry.get("lease"):
        continue
    serial = entry.get("id")
    if serial:
        print(serial)
'
)

if ((${#candidate_serials[@]} == 0)); then
  echo "pixel_pre_merge_proof: no unleased ready Pixel device is available" >&2
  echo "pixel_pre_merge_proof: pre-merge requires one real Pixel hardware proof; this gate does not skip or fall back" >&2
  scripts/shadowctl devices >&2 || true
  exit 1
fi

lease_errors=()
for serial in "${candidate_serials[@]}"; do
  lease_output=""
  if lease_output="$(
    scripts/shadowctl lease acquire "$serial" \
      --owner "$lease_owner" \
      --agent "$lease_agent" \
      --lane pre-merge-pixel-proof \
      --ttl "$lease_ttl" \
      --note "run_id=${run_id}" 2>&1
  )"; then
    selected_serial="$serial"
    break
  fi
  lease_errors+=("$serial: $lease_output")
done

if [[ -z "$selected_serial" ]]; then
  echo "pixel_pre_merge_proof: failed to lease any ready Pixel device" >&2
  printf '  %s\n' "${lease_errors[@]}" >&2
  scripts/shadowctl devices >&2 || true
  exit 1
fi

device_shell_quote() {
  local value
  value="${1:?device_shell_quote requires a value}"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

find_device_file() {
  local file_name
  file_name="${1:?find_device_file requires a file name}"
  pixel_root_shell_timeout 60 "$selected_serial" "
for path in /vendor/lib/modules/$file_name /vendor_dlkm/lib/modules/$file_name /vendor/firmware/$file_name /vendor/firmware/touch/$file_name; do
  if [ -f \"\$path\" ]; then
    echo \"\$path\"
    exit 0
  fi
done
find /vendor /vendor_dlkm -name $(device_shell_quote "$file_name") -type f 2>/dev/null | head -n 1
" | tr -d '\r' | sed -n '1p'
}

pull_device_file() {
  local device_path host_path tmp_path
  device_path="${1:?pull_device_file requires a device path}"
  host_path="${2:?pull_device_file requires a host path}"
  tmp_path="$host_path.tmp"

  mkdir -p "$(dirname "$host_path")"
  rm -f "$tmp_path"
  if timeout 60 adb -s "$selected_serial" pull "$device_path" "$tmp_path" >/dev/null 2>&1; then
    mv "$tmp_path" "$host_path"
  elif pixel_root_shell_timeout 60 "$selected_serial" "cat $(device_shell_quote "$device_path")" >"$tmp_path"; then
    mv "$tmp_path" "$host_path"
  else
    rm -f "$tmp_path"
    echo "pixel_pre_merge_proof: failed to pull required device file: $device_path" >&2
    return 1
  fi
  chmod 0644 "$host_path" 2>/dev/null || true
}

collect_boot_assets() {
  local firmware module device_path
  rm -rf "$asset_root"
  mkdir -p "$firmware_dir" "$input_module_dir"

  for firmware in a630_sqe.fw a618_gmu.bin a615_zap.mdt a615_zap.b02 ftm5_fw.ftb; do
    device_path="$(find_device_file "$firmware")"
    if [[ -z "$device_path" ]]; then
      echo "pixel_pre_merge_proof: unable to locate required firmware on $selected_serial: $firmware" >&2
      return 1
    fi
    pull_device_file "$device_path" "$firmware_dir/$firmware"
  done

  for module in heatmap.ko ftm5.ko; do
    device_path="$(find_device_file "$module")"
    if [[ -z "$device_path" ]]; then
      echo "pixel_pre_merge_proof: unable to locate required touch module on $selected_serial: $module" >&2
      return 1
    fi
    pull_device_file "$device_path" "$input_module_dir/$module"
  done
}

echo "pixel_pre_merge_proof: leased $selected_serial for pre-merge hardware proof"
echo "pixel_pre_merge_proof: run_token=$run_token"
echo "pixel_pre_merge_proof: collecting boot firmware/modules from $selected_serial"
collect_boot_assets

demo_status=0
env \
  SHADOW_DEVICE_LEASE_AGENT="$lease_agent" \
  SHADOW_DEVICE_LEASE_OWNER="$lease_owner" \
  PIXEL_ORANGE_GPU_ENABLE_LINUX_AUDIO=false \
  PIXEL_BOOT_FULL_SHADOW_FIRMWARE_DIR="$firmware_dir" \
  PIXEL_BOOT_FULL_SHADOW_INPUT_MODULE_DIR="$input_module_dir" \
  scripts/pixel/pixel_boot_full_shadow_demo.sh \
    --serial "$selected_serial" \
    --run-token "$run_token" \
    --output-root "$output_root" \
    --hold-secs "$hold_secs" \
    --watchdog-secs "$watchdog_secs" \
    --start-app "$start_app" \
    --extra-apps "" || demo_status=$?

status_path="$output_root/$run_token/device-run/recover-traces/status.json"
summary_path="$output_root/$run_token/pre-merge-proof.json"

if [[ ! -f "$status_path" ]]; then
  echo "pixel_pre_merge_proof: missing recovered status: $status_path" >&2
  exit 1
fi

python3 - "$status_path" "$summary_path" "$selected_serial" "$run_id" "$run_token" "$demo_status" <<'PY'
import json
import pathlib
import sys

status_path, summary_path, serial, run_id, run_token, demo_status_raw = sys.argv[1:]
status = json.loads(pathlib.Path(status_path).read_text(encoding="utf-8"))
demo_status = int(demo_status_raw)

required_true = [
    "proof_ok",
    "probe_summary_proves_shell_session_held",
    "metadata_probe_summary_shell_session_app_frame_captured",
    "metadata_compositor_frame_proves_shell_session_app",
]
errors = []
for key in required_true:
    if status.get(key) is not True:
        errors.append(f"{key} is not true")

if status.get("expected_orange_gpu_mode") != "shell-session-held":
    errors.append(
        "expected_orange_gpu_mode is not shell-session-held "
        f"(got {status.get('expected_orange_gpu_mode')!r})"
    )

summary = {
    "schemaVersion": 1,
    "gate": "pre-merge-pixel-proof",
    "ok": not errors and demo_status == 0,
    "serial": serial,
    "runId": run_id,
    "runToken": run_token,
    "demoStatus": demo_status,
    "statusPath": status_path,
    "proofOk": status.get("proof_ok") is True,
    "expectedOrangeGpuMode": status.get("expected_orange_gpu_mode"),
    "shellSessionHeld": status.get("probe_summary_proves_shell_session_held"),
    "shellFrameCaptured": status.get(
        "metadata_probe_summary_shell_session_app_frame_captured"
    ),
    "shellFrameProved": status.get("metadata_compositor_frame_proves_shell_session_app"),
    "framePath": status.get("expected_metadata_compositor_frame_path"),
    "errors": errors,
}

path = pathlib.Path(summary_path)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")

if demo_status != 0:
    print(
        f"pixel_pre_merge_proof: full Shadow demo exited with status {demo_status}",
        file=sys.stderr,
    )
if errors:
    print("pixel_pre_merge_proof: recovered Pixel proof is not acceptable", file=sys.stderr)
    for error in errors:
        print(f"  - {error}", file=sys.stderr)
    print(f"pixel_pre_merge_proof: status={status_path}", file=sys.stderr)
    print(f"pixel_pre_merge_proof: summary={summary_path}", file=sys.stderr)
    raise SystemExit(1)
if demo_status != 0:
    print(f"pixel_pre_merge_proof: status={status_path}", file=sys.stderr)
    print(f"pixel_pre_merge_proof: summary={summary_path}", file=sys.stderr)
    raise SystemExit(demo_status)

print("pixel_pre_merge_proof: proof_ok=true")
print(f"pixel_pre_merge_proof: status={status_path}")
print(f"pixel_pre_merge_proof: summary={summary_path}")
PY
