#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-pixel-boot-preflight.XXXXXX")"
MOCK_BIN="$TMP_DIR/bin"
BOOT_BUILD_INPUT="$TMP_DIR/stock.img"
AVB_KEY_PATH="$TMP_DIR/avb-test-key.pem"
PREFLIGHT_BUILD_MOCK="$MOCK_BIN/pixel-boot-preflight-build-mock"
PREFLIGHT_ONESHOT_MOCK="$MOCK_BIN/pixel-boot-preflight-oneshot-mock"
PHASE1_RUNTIME_ROOT="/data/local/tmp/shadow-runtime-gnu"
PHASE1_SYSTEM_LAUNCHER_PATH="$PHASE1_RUNTIME_ROOT/run-shadow-system"
PHASE1_GUEST_CLIENT_LAUNCHER_PATH="$PHASE1_RUNTIME_ROOT/run-shadow-blitz-demo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$MOCK_BIN"
printf 'mock stock image\n' >"$BOOT_BUILD_INPUT"
printf 'mock avb test key\n' >"$AVB_KEY_PATH"

cat >"$PREFLIGHT_BUILD_MOCK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
profile=""
trigger=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    --preflight-profile)
      profile="$2"
      shift 2
      ;;
    --trigger)
      trigger="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$(dirname "$output")"
printf 'mock preflight image\n' >"$output"
printf 'Profile: %s\n' "$profile"
printf 'Trigger: %s\n' "$trigger"
EOF
chmod 0755 "$PREFLIGHT_BUILD_MOCK"

cat >"$PREFLIGHT_ONESHOT_MOCK" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

image=""
output=""
proof_prop=""
observed_prop=""
mode="${MOCK_PREFLIGHT_ONESHOT_MODE:-summary-blocked}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      image="$2"
      shift 2
      ;;
    --output)
      output="$2"
      shift 2
      ;;
    --proof-prop)
      proof_prop="$2"
      shift 2
      ;;
    --observed-prop)
      observed_prop="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$output/collect"
cat >"$output/collect/getprop.txt" <<'GPROPS'
[debug.shadow.boot.preflight.second_stage]: [ready]
GPROPS

python3 - "$output/status.json" "$output/collect/status.json" "$image" "${PIXEL_SERIAL:-TESTSERIAL}" "$proof_prop" "$observed_prop" "$mode" <<'PY'
import json
import sys

status_path, collect_status_path, image_path, serial, proof_prop, observed_prop, mode = sys.argv[1:8]

collect_output_dir = str(collect_status_path.rsplit("/", 1)[0])
device_status = {
    "ok": mode != "second-stage-only",
    "serial": serial,
    "collect_succeeded": mode != "second-stage-only",
    "collection_succeeded": mode != "second-stage-only",
    "collect_output_dir": collect_output_dir,
    "failure_stage": "collect" if mode == "second-stage-only" else "",
    "proof_prop": proof_prop,
    "observed_prop": observed_prop,
}

collect_status = {
    "collection_succeeded": False,
    "observed_property_matched": False,
    "helper_dir_present": False,
    "helper_dir_pulled": False,
    "helper_status_present": False,
    "matched_current_boot": False,
    "matched_current_slot": False,
    "matched_expected_slot": False,
    "preflight_summary_present": False,
    "preflight_checks_present": False,
    "preflight_profile": "",
    "preflight_status": "",
    "preflight_ready": False,
    "preflight_blocked_reason": "",
    "preflight_required_missing_labels": "",
}

if mode == "summary-blocked":
    collect_status.update(
        {
            "collection_succeeded": True,
            "observed_property_matched": True,
            "helper_dir_present": True,
            "helper_dir_pulled": True,
            "helper_status_present": True,
            "matched_current_boot": True,
            "matched_current_slot": True,
            "matched_expected_slot": True,
            "preflight_summary_present": True,
            "preflight_checks_present": True,
            "preflight_profile": "phase1-shell",
            "preflight_status": "blocked",
            "preflight_ready": False,
            "preflight_blocked_reason": "missing-required-paths",
            "preflight_required_missing_labels": "system-launcher,guest-client-launcher",
        }
    )
elif mode == "helper-launch-fallback":
    collect_status.update(
        {
            "collection_succeeded": True,
            "helper_dir_present": True,
            "helper_dir_pulled": True,
            "helper_status_present": True,
            "matched_current_boot": True,
            "matched_current_slot": True,
            "matched_expected_slot": True,
        }
    )
elif mode == "import-proof-fallback":
    collect_status.update({"collection_succeeded": True})
elif mode != "second-stage-only":
    raise SystemExit(f"unexpected oneshot mode: {mode}")

with open(status_path, "w", encoding="utf-8") as fh:
    json.dump(device_status, fh, indent=2, sort_keys=True)
    fh.write("\n")

with open(collect_status_path, "w", encoding="utf-8") as fh:
    json.dump(collect_status, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

printf 'mock preflight oneshot for %s\n' "$image"
if [[ "$mode" == "second-stage-only" ]]; then
  exit 1
fi
EOF
chmod 0755 "$PREFLIGHT_ONESHOT_MOCK"

assert_contains() {
  local haystack needle
  haystack="$1"
  needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "pixel_boot_preflight_smoke: expected output to contain: $needle" >&2
    exit 1
  fi
}

assert_json_field() {
  local json_path key expected
  json_path="$1"
  key="$2"
  expected="$3"
  python3 - "$json_path" "$key" "$expected" <<'PY'
import json
import sys

path, key, expected = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

value = data
for part in key.split("/"):
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value[part]

if isinstance(value, bool):
    rendered = "true" if value else "false"
else:
    rendered = str(value)

if rendered != expected:
    raise SystemExit(f"{key}: expected {expected!r}, got {rendered!r}")
PY
}

assert_json_array_length() {
  local json_path key expected
  json_path="$1"
  key="$2"
  expected="$3"
  python3 - "$json_path" "$key" "$expected" <<'PY'
import json
import sys

path, key, expected = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)

value = data
for part in key.split("/"):
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value[part]

actual = len(value)
if actual != int(expected):
    raise SystemExit(f"{key}: expected length {expected}, got {actual}")
PY
}

run_preflight_case() {
  local mode output_dir common_root
  mode="$1"
  output_dir="$2"
  common_root="$3"

  rm -rf "$output_dir"
  env \
    PATH="$MOCK_BIN:$PATH" \
    SHADOW_BOOTIMG_SHELL=1 \
    SHADOW_REPO_COMMON_ROOT="$common_root" \
    PIXEL_SERIAL=TESTSERIAL \
    MOCK_PREFLIGHT_ONESHOT_MODE="$mode" \
    PIXEL_BOOT_PREFLIGHT_BUILD_SCRIPT="$PREFLIGHT_BUILD_MOCK" \
    PIXEL_BOOT_PREFLIGHT_ONESHOT_SCRIPT="$PREFLIGHT_ONESHOT_MOCK" \
    "$REPO_ROOT/scripts/pixel/pixel_boot_preflight.sh" \
      --serial TESTSERIAL \
      --input "$BOOT_BUILD_INPUT" \
      --key "$AVB_KEY_PATH" \
      --output-dir "$output_dir" \
      --trigger post-fs-data \
      --patch-target init.recovery.rc \
      --adb-timeout 45 \
      --boot-timeout 60 \
      --recover-traces-after
}

SUMMARY_OUTPUT="$TMP_DIR/preflight-summary-output"
summary_output="$(
  run_preflight_case summary-blocked "$SUMMARY_OUTPUT" "$TMP_DIR/common-root-summary"
)"
assert_contains "$summary_output" "Boot preflight output: $SUMMARY_OUTPUT"
assert_contains "$summary_output" "Import proved current boot: true"
assert_contains "$summary_output" "Helper launch proved current boot: true"
assert_contains "$summary_output" "Phase-1 preflight status: blocked"
assert_contains "$summary_output" "Phase-1 preflight blocked reason: missing-required-paths"
assert_contains "$summary_output" "Phase-1 preflight source: preflight-summary"
assert_contains "$summary_output" "Phase-1 required missing labels: system-launcher,guest-client-launcher"
assert_contains "$summary_output" "Phase-1 recovery note: Run sc -t pixel stage shell to restage $PHASE1_SYSTEM_LAUNCHER_PATH before rerunning phase-1 preflight."
assert_contains "$summary_output" "Phase-1 recovery note: Run sc -t pixel stage shell to restage $PHASE1_GUEST_CLIENT_LAUNCHER_PATH before rerunning phase-1 preflight."
assert_contains "$summary_output" "Preflight status: blocked"
assert_json_field "$SUMMARY_OUTPUT/summary.json" ok true
assert_json_field "$SUMMARY_OUTPUT/summary.json" second_stage_property_proved_current_boot true
assert_json_field "$SUMMARY_OUTPUT/summary.json" import_proved_current_boot true
assert_json_field "$SUMMARY_OUTPUT/summary.json" helper_launch_proved_current_boot true
assert_json_field "$SUMMARY_OUTPUT/summary.json" phase1_preflight_status blocked
assert_json_field "$SUMMARY_OUTPUT/summary.json" phase1_preflight_blocked_reason missing-required-paths
assert_json_field "$SUMMARY_OUTPUT/summary.json" phase1_preflight_status_source preflight-summary
assert_json_field "$SUMMARY_OUTPUT/summary.json" phase1_preflight_required_missing_labels system-launcher,guest-client-launcher
assert_json_array_length "$SUMMARY_OUTPUT/summary.json" phase1_preflight_recovery_notes 2
assert_json_field "$SUMMARY_OUTPUT/summary.json" phase1_preflight_recovery_notes/0 "Run sc -t pixel stage shell to restage $PHASE1_SYSTEM_LAUNCHER_PATH before rerunning phase-1 preflight."
assert_json_field "$SUMMARY_OUTPUT/summary.json" phase1_preflight_recovery_notes/1 "Run sc -t pixel stage shell to restage $PHASE1_GUEST_CLIENT_LAUNCHER_PATH before rerunning phase-1 preflight."
assert_json_field "$SUMMARY_OUTPUT/device-run/status.json" boot_oneshot_ok true
assert_json_field "$SUMMARY_OUTPUT/device-run/status.json" phase1_preflight_status blocked
assert_json_field "$SUMMARY_OUTPUT/device-run/status.json" phase1_preflight_status_source preflight-summary
assert_json_field "$SUMMARY_OUTPUT/device-run/status.json" phase1_preflight_device_status_aligned false

HELPER_FALLBACK_OUTPUT="$TMP_DIR/preflight-helper-launch-fallback-output"
helper_fallback_output="$(
  run_preflight_case helper-launch-fallback "$HELPER_FALLBACK_OUTPUT" "$TMP_DIR/common-root-helper-fallback"
)"
assert_contains "$helper_fallback_output" "Boot preflight output: $HELPER_FALLBACK_OUTPUT"
assert_contains "$helper_fallback_output" "Import proved current boot: true"
assert_contains "$helper_fallback_output" "Helper launch proved current boot: true"
assert_contains "$helper_fallback_output" "Phase-1 preflight status: blocked"
assert_contains "$helper_fallback_output" "Phase-1 preflight blocked reason: boot-helper-preflight-status-missing"
assert_contains "$helper_fallback_output" "Phase-1 preflight source: helper-launch-proof"
assert_json_field "$HELPER_FALLBACK_OUTPUT/summary.json" ok true
assert_json_field "$HELPER_FALLBACK_OUTPUT/summary.json" second_stage_property_proved_current_boot true
assert_json_field "$HELPER_FALLBACK_OUTPUT/summary.json" import_proved_current_boot true
assert_json_field "$HELPER_FALLBACK_OUTPUT/summary.json" helper_launch_proved_current_boot true
assert_json_field "$HELPER_FALLBACK_OUTPUT/summary.json" preflight_status ""
assert_json_field "$HELPER_FALLBACK_OUTPUT/summary.json" phase1_preflight_status blocked
assert_json_field "$HELPER_FALLBACK_OUTPUT/summary.json" phase1_preflight_blocked_reason boot-helper-preflight-status-missing
assert_json_field "$HELPER_FALLBACK_OUTPUT/summary.json" phase1_preflight_status_source helper-launch-proof
assert_json_field "$HELPER_FALLBACK_OUTPUT/summary.json" phase1_preflight_required_missing_labels ""
assert_json_array_length "$HELPER_FALLBACK_OUTPUT/summary.json" phase1_preflight_recovery_notes 0
assert_json_field "$HELPER_FALLBACK_OUTPUT/device-run/status.json" boot_oneshot_ok true
assert_json_field "$HELPER_FALLBACK_OUTPUT/device-run/status.json" phase1_preflight_status blocked
assert_json_field "$HELPER_FALLBACK_OUTPUT/device-run/status.json" phase1_preflight_blocked_reason boot-helper-preflight-status-missing
assert_json_field "$HELPER_FALLBACK_OUTPUT/device-run/status.json" phase1_preflight_status_source helper-launch-proof
assert_json_field "$HELPER_FALLBACK_OUTPUT/device-run/status.json" phase1_preflight_device_status_aligned false

IMPORT_FALLBACK_OUTPUT="$TMP_DIR/preflight-import-proof-fallback-output"
import_fallback_output="$(
  run_preflight_case import-proof-fallback "$IMPORT_FALLBACK_OUTPUT" "$TMP_DIR/common-root-import-fallback"
)"
assert_contains "$import_fallback_output" "Boot preflight output: $IMPORT_FALLBACK_OUTPUT"
assert_contains "$import_fallback_output" "Import proved current boot: true"
assert_contains "$import_fallback_output" "Helper launch proved current boot: false"
assert_contains "$import_fallback_output" "Phase-1 preflight status: blocked"
assert_contains "$import_fallback_output" "Phase-1 preflight blocked reason: boot-helper-launch-not-proved"
assert_contains "$import_fallback_output" "Phase-1 preflight source: import-proof"
assert_json_field "$IMPORT_FALLBACK_OUTPUT/summary.json" ok true
assert_json_field "$IMPORT_FALLBACK_OUTPUT/summary.json" second_stage_property_proved_current_boot true
assert_json_field "$IMPORT_FALLBACK_OUTPUT/summary.json" import_proved_current_boot true
assert_json_field "$IMPORT_FALLBACK_OUTPUT/summary.json" helper_launch_proved_current_boot false
assert_json_field "$IMPORT_FALLBACK_OUTPUT/summary.json" preflight_status ""
assert_json_field "$IMPORT_FALLBACK_OUTPUT/summary.json" phase1_preflight_status blocked
assert_json_field "$IMPORT_FALLBACK_OUTPUT/summary.json" phase1_preflight_blocked_reason boot-helper-launch-not-proved
assert_json_field "$IMPORT_FALLBACK_OUTPUT/summary.json" phase1_preflight_status_source import-proof
assert_json_field "$IMPORT_FALLBACK_OUTPUT/summary.json" phase1_preflight_required_missing_labels ""
assert_json_array_length "$IMPORT_FALLBACK_OUTPUT/summary.json" phase1_preflight_recovery_notes 0
assert_json_field "$IMPORT_FALLBACK_OUTPUT/device-run/status.json" boot_oneshot_ok true
assert_json_field "$IMPORT_FALLBACK_OUTPUT/device-run/status.json" phase1_preflight_status blocked
assert_json_field "$IMPORT_FALLBACK_OUTPUT/device-run/status.json" phase1_preflight_blocked_reason boot-helper-launch-not-proved
assert_json_field "$IMPORT_FALLBACK_OUTPUT/device-run/status.json" phase1_preflight_status_source import-proof
assert_json_field "$IMPORT_FALLBACK_OUTPUT/device-run/status.json" phase1_preflight_device_status_aligned false

SECOND_STAGE_OUTPUT="$TMP_DIR/preflight-second-stage-only-output"
second_stage_output="$(
  run_preflight_case second-stage-only "$SECOND_STAGE_OUTPUT" "$TMP_DIR/common-root-second-stage"
)"
assert_contains "$second_stage_output" "Boot preflight output: $SECOND_STAGE_OUTPUT"
assert_contains "$second_stage_output" "Import proved current boot: false"
assert_contains "$second_stage_output" "Helper launch proved current boot: false"
assert_contains "$second_stage_output" "Phase-1 preflight status: blocked"
assert_contains "$second_stage_output" "Phase-1 preflight blocked reason: stock-init-import-not-proved"
assert_contains "$second_stage_output" "Phase-1 preflight source: second-stage-property-proof"
assert_json_field "$SECOND_STAGE_OUTPUT/summary.json" ok true
assert_json_field "$SECOND_STAGE_OUTPUT/summary.json" second_stage_property_proved_current_boot true
assert_json_field "$SECOND_STAGE_OUTPUT/summary.json" import_proved_current_boot false
assert_json_field "$SECOND_STAGE_OUTPUT/summary.json" helper_launch_proved_current_boot false
assert_json_field "$SECOND_STAGE_OUTPUT/summary.json" phase1_preflight_status blocked
assert_json_field "$SECOND_STAGE_OUTPUT/summary.json" phase1_preflight_blocked_reason stock-init-import-not-proved
assert_json_field "$SECOND_STAGE_OUTPUT/summary.json" phase1_preflight_status_source second-stage-property-proof
assert_json_field "$SECOND_STAGE_OUTPUT/summary.json" phase1_preflight_required_missing_labels ""
assert_json_array_length "$SECOND_STAGE_OUTPUT/summary.json" phase1_preflight_recovery_notes 0
assert_json_field "$SECOND_STAGE_OUTPUT/device-run/status.json" ok true
assert_json_field "$SECOND_STAGE_OUTPUT/device-run/status.json" failure_stage ""
assert_json_field "$SECOND_STAGE_OUTPUT/device-run/status.json" boot_oneshot_ok false
assert_json_field "$SECOND_STAGE_OUTPUT/device-run/status.json" boot_oneshot_failure_stage collect
assert_json_field "$SECOND_STAGE_OUTPUT/device-run/status.json" collection_succeeded false
assert_json_field "$SECOND_STAGE_OUTPUT/device-run/status.json" phase1_preflight_status blocked
assert_json_field "$SECOND_STAGE_OUTPUT/device-run/status.json" phase1_preflight_blocked_reason stock-init-import-not-proved
assert_json_field "$SECOND_STAGE_OUTPUT/device-run/status.json" phase1_preflight_status_source second-stage-property-proof
assert_json_field "$SECOND_STAGE_OUTPUT/device-run/status.json" phase1_preflight_device_status_aligned true

echo "pixel_boot_preflight_smoke: ok"
