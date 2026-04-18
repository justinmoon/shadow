#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-pixel-boot-collect.XXXXXX")"
MOCK_BIN="$TMP_DIR/bin"
DEVICE_LOG_ROOT="/data/local/tmp/shadow-boot"
WRAPPER_MARKER_ROOT="/.shadow-init-wrapper"
LIVE_BOOT_ID="11111111-2222-3333-4444-555555555555"
LIVE_SLOT_SUFFIX="_a"
EXPECTED_PROP_KEY="shadow.boot.rc_probe"
EXPECTED_PROP_VALUE="ready"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$MOCK_BIN"

create_device_tree() {
  local root include_helper
  root="$1"
  include_helper="$2"

  mkdir -p "$root$(dirname "$WRAPPER_MARKER_ROOT")" "$root$WRAPPER_MARKER_ROOT"
  printf '%s\n' "$LIVE_BOOT_ID" >"$root$WRAPPER_MARKER_ROOT/boot-id.txt"
  printf 'exec-stock-init\n' >"$root$WRAPPER_MARKER_ROOT/status.txt"
  printf '1\n' >"$root$WRAPPER_MARKER_ROOT/pid.txt"
  printf 'bootstrapping: wrapper bootstrapping\n' >"$root$WRAPPER_MARKER_ROOT/events.log"

  if [[ "$include_helper" == "1" ]]; then
    mkdir -p "$root$DEVICE_LOG_ROOT"
    printf '%s\n' "$LIVE_BOOT_ID" >"$root$DEVICE_LOG_ROOT/boot-id.txt"
    printf '%s\n' "$LIVE_SLOT_SUFFIX" >"$root$DEVICE_LOG_ROOT/slot-suffix.txt"
    printf 'ready\n' >"$root$DEVICE_LOG_ROOT/status.txt"
    printf 'helper finished\n' >"$root$DEVICE_LOG_ROOT/helper.log"
  fi
}

SUCCESS_DEVICE_ROOT="$TMP_DIR/device-success"
WRAPPER_ONLY_DEVICE_ROOT="$TMP_DIR/device-wrapper-only"
create_device_tree "$SUCCESS_DEVICE_ROOT" 1
create_device_tree "$WRAPPER_ONLY_DEVICE_ROOT" 0

cat >"$MOCK_BIN/adb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LIVE_BOOT_ID="${LIVE_BOOT_ID:?}"
LIVE_SLOT_SUFFIX="${LIVE_SLOT_SUFFIX:?}"
MOCK_DEVICE_ROOT="${MOCK_DEVICE_ROOT:?}"
MOCK_FAIL_HELPER_PULL="${MOCK_FAIL_HELPER_PULL:-0}"
MOCK_BEST_EFFORT_FAILURES="${MOCK_BEST_EFFORT_FAILURES:-0}"
MOCK_EXPECTED_PROP_KEY="${MOCK_EXPECTED_PROP_KEY:-}"
MOCK_EXPECTED_PROP_VALUE="${MOCK_EXPECTED_PROP_VALUE:-}"

device_path_to_host() {
  local device_path
  device_path="$1"
  printf '%s%s\n' "$MOCK_DEVICE_ROOT" "$device_path"
}

if [[ "${1:-}" == "devices" ]]; then
  printf 'List of devices attached\nTESTSERIAL\tdevice\n'
  exit 0
fi

if [[ "${1:-}" == "-s" ]]; then
  serial="${2:-}"
  shift 2
  [[ "$serial" == "TESTSERIAL" ]] || {
    echo "mock adb: unexpected serial $serial" >&2
    exit 1
  }
fi

case "${1:-}" in
  pull)
    device_path="${2:-}"
    dest="${3:-}"
    if [[ "$MOCK_FAIL_HELPER_PULL" == "1" && "$device_path" == "$PIXEL_BOOT_DEVICE_LOG_ROOT" ]]; then
      echo "mock adb: forced pull failure for $device_path" >&2
      exit 1
    fi
    host_path="$(device_path_to_host "$device_path")"
    [[ -e "$host_path" ]] || {
      echo "mock adb: missing device path $device_path" >&2
      exit 1
    }
    cp -R "$host_path" "$dest"
    ;;
  shell)
    shift
    cmd="$*"
    if printf '%s\n' "$cmd" | grep -Eq "^\\[ -e '.+' \\]$"; then
      device_path="$(printf '%s\n' "$cmd" | sed -E "s/^\\[ -e '(.*)' \\]$/\\1/")"
      host_path="$(device_path_to_host "$device_path")"
      [[ -e "$host_path" ]]
      exit $?
    fi
    if printf '%s\n' "$cmd" | grep -Eq "^ls -ld '.+' 2>/dev/null \\|\\| true$"; then
      device_path="$(printf '%s\n' "$cmd" | sed -E "s/^ls -ld '(.*)' 2>\\/dev\\/null \\|\\| true$/\\1/")"
      host_path="$(device_path_to_host "$device_path")"
      if [[ -e "$host_path" ]]; then
        printf 'drwxr-xr-x 2 root root 0 2026-04-18 %s\n' "$device_path"
      fi
      exit 0
    fi
    if printf '%s\n' "$cmd" | grep -Eq "^cat '.+' 2>/dev/null \\|\\| true$"; then
      device_path="$(printf '%s\n' "$cmd" | sed -E "s/^cat '(.*)' 2>\\/dev\\/null \\|\\| true$/\\1/")"
      host_path="$(device_path_to_host "$device_path")"
      if [[ -f "$host_path" ]]; then
        cat "$host_path"
      fi
      exit 0
    fi
    case "$cmd" in
      "cat /proc/sys/kernel/random/boot_id 2>/dev/null")
        printf '%s\n' "$LIVE_BOOT_ID"
        ;;
      "getprop ro.boot.slot_suffix")
        printf '%s\n' "$LIVE_SLOT_SUFFIX"
        ;;
      "getprop $MOCK_EXPECTED_PROP_KEY")
        printf '%s\n' "${MOCK_EXPECTED_PROP_VALUE:-}"
        ;;
      "getprop")
        if [[ "$MOCK_BEST_EFFORT_FAILURES" == "1" ]]; then
          exit 1
        fi
        cat <<PROP
[ro.boot.slot_suffix]: [$LIVE_SLOT_SUFFIX]
[ro.bootmode]: [normal]
[${MOCK_EXPECTED_PROP_KEY}]: [${MOCK_EXPECTED_PROP_VALUE:-}]
PROP
        ;;
      "logcat -d -s shadow-init:I shadow-boot:I 2>/dev/null || true")
        if [[ "$MOCK_BEST_EFFORT_FAILURES" == "1" ]]; then
          exit 1
        fi
        printf '%s\n' '--------- beginning of main'
        ;;
      "logcat -b kernel -d 2>/dev/null || true")
        if [[ "$MOCK_BEST_EFFORT_FAILURES" == "1" ]]; then
          exit 1
        fi
        printf '<6>[shadow-init] wrapper starting\n'
        ;;
      "ps -A -o USER,PID,PPID,NAME,ARGS 2>/dev/null || ps -A || true")
        if [[ "$MOCK_BEST_EFFORT_FAILURES" == "1" ]]; then
          exit 1
        fi
        printf 'USER PID PPID NAME ARGS\nroot 1 0 init /init\n'
        ;;
      *)
        echo "mock adb: unexpected shell command: $cmd" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "mock adb: unexpected args: $*" >&2
    exit 1
    ;;
esac
EOF

cat >"$MOCK_BIN/just" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$MOCK_BIN/payload-dumper-go" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod 0755 "$MOCK_BIN/adb" "$MOCK_BIN/just" "$MOCK_BIN/payload-dumper-go"

assert_failure() {
  local output status
  set +e
  output="$("$@" 2>&1)"
  status="$?"
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "pixel_boot_collect_logs_smoke: expected failure for: $*" >&2
    echo "$output" >&2
    exit 1
  fi
  printf '%s\n' "$output"
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

value = data[key]
if isinstance(value, bool):
    rendered = "true" if value else "false"
else:
    rendered = str(value)

if rendered != expected:
    raise SystemExit(f"{key}: expected {expected!r}, got {rendered!r}")
PY
}

SUCCESS_OUTPUT="$TMP_DIR/output-success"
env \
  PATH="$MOCK_BIN:$PATH" \
  SHADOW_BOOTIMG_SHELL=1 \
  PIXEL_SERIAL=TESTSERIAL \
  PIXEL_BOOT_DEVICE_LOG_ROOT="$DEVICE_LOG_ROOT" \
  PIXEL_INIT_WRAPPER_MARKER_ROOT="$WRAPPER_MARKER_ROOT" \
  LIVE_BOOT_ID="$LIVE_BOOT_ID" \
  LIVE_SLOT_SUFFIX="$LIVE_SLOT_SUFFIX" \
  MOCK_EXPECTED_PROP_KEY="$EXPECTED_PROP_KEY" \
  MOCK_DEVICE_ROOT="$SUCCESS_DEVICE_ROOT" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_collect_logs.sh" \
  --wait-ready 0 \
  --output "$SUCCESS_OUTPUT" >/dev/null

test -f "$SUCCESS_OUTPUT/device/$(basename "$DEVICE_LOG_ROOT")/status.txt"
test -f "$SUCCESS_OUTPUT/device/$(basename "$WRAPPER_MARKER_ROOT")/events.log"
assert_json_field "$SUCCESS_OUTPUT/status.json" collection_succeeded true
assert_json_field "$SUCCESS_OUTPUT/status.json" helper_dir_pulled true
assert_json_field "$SUCCESS_OUTPUT/status.json" wrapper_matches_current_boot true

PULL_FAILURE_OUTPUT="$TMP_DIR/output-pull-failure"
assert_failure env \
  PATH="$MOCK_BIN:$PATH" \
  SHADOW_BOOTIMG_SHELL=1 \
  PIXEL_SERIAL=TESTSERIAL \
  PIXEL_BOOT_DEVICE_LOG_ROOT="$DEVICE_LOG_ROOT" \
  PIXEL_INIT_WRAPPER_MARKER_ROOT="$WRAPPER_MARKER_ROOT" \
  LIVE_BOOT_ID="$LIVE_BOOT_ID" \
  LIVE_SLOT_SUFFIX="$LIVE_SLOT_SUFFIX" \
  MOCK_EXPECTED_PROP_KEY="$EXPECTED_PROP_KEY" \
  MOCK_FAIL_HELPER_PULL=1 \
  MOCK_DEVICE_ROOT="$SUCCESS_DEVICE_ROOT" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_collect_logs.sh" \
  --wait-ready 0 \
  --output "$PULL_FAILURE_OUTPUT" >/dev/null

assert_json_field "$PULL_FAILURE_OUTPUT/status.json" helper_dir_present true
assert_json_field "$PULL_FAILURE_OUTPUT/status.json" helper_dir_pulled false
assert_json_field "$PULL_FAILURE_OUTPUT/status.json" collection_succeeded false

PROP_SUCCESS_OUTPUT="$TMP_DIR/output-prop-success"
env \
  PATH="$MOCK_BIN:$PATH" \
  SHADOW_BOOTIMG_SHELL=1 \
  PIXEL_SERIAL=TESTSERIAL \
  PIXEL_BOOT_DEVICE_LOG_ROOT="$DEVICE_LOG_ROOT" \
  PIXEL_INIT_WRAPPER_MARKER_ROOT="$WRAPPER_MARKER_ROOT" \
  LIVE_BOOT_ID="$LIVE_BOOT_ID" \
  LIVE_SLOT_SUFFIX="$LIVE_SLOT_SUFFIX" \
  MOCK_EXPECTED_PROP_KEY="$EXPECTED_PROP_KEY" \
  MOCK_EXPECTED_PROP_VALUE="$EXPECTED_PROP_VALUE" \
  MOCK_DEVICE_ROOT="$WRAPPER_ONLY_DEVICE_ROOT" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_collect_logs.sh" \
  --wait-ready 0 \
  --proof-prop "$EXPECTED_PROP_KEY=$EXPECTED_PROP_VALUE" \
  --output "$PROP_SUCCESS_OUTPUT" >/dev/null

assert_json_field "$PROP_SUCCESS_OUTPUT/status.json" collection_succeeded true
assert_json_field "$PROP_SUCCESS_OUTPUT/status.json" helper_dir_present false
assert_json_field "$PROP_SUCCESS_OUTPUT/status.json" proof_mode property
assert_json_field "$PROP_SUCCESS_OUTPUT/status.json" proof_property_key "$EXPECTED_PROP_KEY"
assert_json_field "$PROP_SUCCESS_OUTPUT/status.json" proof_property_actual "$EXPECTED_PROP_VALUE"
assert_json_field "$PROP_SUCCESS_OUTPUT/status.json" proof_property_matched true

PROPERTY_SLOT_MISMATCH_METADATA="$TMP_DIR/property-slot-mismatch-metadata.json"
cat >"$PROPERTY_SLOT_MISMATCH_METADATA" <<'EOF'
{
  "kind": "boot_flash",
  "activate_target": true,
  "target_slot": "b"
}
EOF

PROP_SLOT_MISMATCH_OUTPUT="$TMP_DIR/output-prop-slot-mismatch"
assert_failure env \
  PATH="$MOCK_BIN:$PATH" \
  SHADOW_BOOTIMG_SHELL=1 \
  PIXEL_SERIAL=TESTSERIAL \
  PIXEL_BOOT_DEVICE_LOG_ROOT="$DEVICE_LOG_ROOT" \
  PIXEL_INIT_WRAPPER_MARKER_ROOT="$WRAPPER_MARKER_ROOT" \
  LIVE_BOOT_ID="$LIVE_BOOT_ID" \
  LIVE_SLOT_SUFFIX="$LIVE_SLOT_SUFFIX" \
  MOCK_EXPECTED_PROP_KEY="$EXPECTED_PROP_KEY" \
  MOCK_EXPECTED_PROP_VALUE="$EXPECTED_PROP_VALUE" \
  MOCK_DEVICE_ROOT="$WRAPPER_ONLY_DEVICE_ROOT" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_collect_logs.sh" \
  --wait-ready 0 \
  --proof-prop "$EXPECTED_PROP_KEY=$EXPECTED_PROP_VALUE" \
  --metadata "$PROPERTY_SLOT_MISMATCH_METADATA" \
  --output "$PROP_SLOT_MISMATCH_OUTPUT" >/dev/null

assert_json_field "$PROP_SLOT_MISMATCH_OUTPUT/status.json" collection_succeeded false
assert_json_field "$PROP_SLOT_MISMATCH_OUTPUT/status.json" live_matches_expected_slot false
assert_json_field "$PROP_SLOT_MISMATCH_OUTPUT/status.json" proof_property_matched true

WRAPPER_ONLY_OUTPUT="$TMP_DIR/output-wrapper-only"
assert_failure env \
  PATH="$MOCK_BIN:$PATH" \
  SHADOW_BOOTIMG_SHELL=1 \
  PIXEL_SERIAL=TESTSERIAL \
  PIXEL_BOOT_DEVICE_LOG_ROOT="$DEVICE_LOG_ROOT" \
  PIXEL_INIT_WRAPPER_MARKER_ROOT="$WRAPPER_MARKER_ROOT" \
  LIVE_BOOT_ID="$LIVE_BOOT_ID" \
  LIVE_SLOT_SUFFIX="$LIVE_SLOT_SUFFIX" \
  MOCK_EXPECTED_PROP_KEY="$EXPECTED_PROP_KEY" \
  MOCK_EXPECTED_PROP_VALUE= \
  MOCK_BEST_EFFORT_FAILURES=1 \
  MOCK_DEVICE_ROOT="$WRAPPER_ONLY_DEVICE_ROOT" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_collect_logs.sh" \
  --wait-ready 0 \
  --proof-prop "$EXPECTED_PROP_KEY=$EXPECTED_PROP_VALUE" \
  --output "$WRAPPER_ONLY_OUTPUT" >/dev/null

test -f "$WRAPPER_ONLY_OUTPUT/device/$(basename "$WRAPPER_MARKER_ROOT")/status.txt"
assert_json_field "$WRAPPER_ONLY_OUTPUT/status.json" collection_succeeded false
assert_json_field "$WRAPPER_ONLY_OUTPUT/status.json" helper_dir_present false
assert_json_field "$WRAPPER_ONLY_OUTPUT/status.json" wrapper_marker_dir_present true
assert_json_field "$WRAPPER_ONLY_OUTPUT/status.json" wrapper_matches_current_boot true
assert_json_field "$WRAPPER_ONLY_OUTPUT/status.json" proof_property_matched false

echo "pixel_boot_collect_logs_smoke: ok"
