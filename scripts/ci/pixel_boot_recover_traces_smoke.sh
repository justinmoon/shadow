#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-pixel-boot-recover.XXXXXX")"
MOCK_BIN="$TMP_DIR/bin"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$MOCK_BIN"

cat >"$MOCK_BIN/adb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

TRACE_MODE="${MOCK_TRACE_MODE:?}"

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
  shell)
    shift
    cmd="$*"
    case "$cmd" in
      "cat /proc/sys/kernel/random/boot_id 2>/dev/null")
        printf '11111111-2222-3333-4444-555555555555\n'
        ;;
      "getprop sys.boot_completed")
        printf '1\n'
        ;;
      "getprop ro.boot.slot_suffix")
        printf '_a\n'
        ;;
      "logcat -L -d -v threadtime")
        if [[ "$TRACE_MODE" == "matched" ]]; then
          printf '04-19 10:00:00.000 root root I shadow-hello-init: previous boot breadcrumb\n'
        else
          printf '04-19 10:00:00.000 root root I bootstat: cold boot\n'
        fi
        ;;
      "dumpsys dropbox --print SYSTEM_BOOT")
        if [[ "$TRACE_MODE" == "matched" ]]; then
          printf 'SYSTEM_BOOT\n[shadow-drm] restored previous boot trace\n'
        else
          printf 'SYSTEM_BOOT\nBoot completed normally\n'
        fi
        ;;
      "cat /dev/pmsg0")
        if [[ "$TRACE_MODE" == "matched" ]]; then
          printf 'shadow-owned-init-role:hello-init\nshadow-owned-init-impl:c-static\n'
        else
          printf 'audit: pmsg readable but empty of shadow tags\n'
        fi
        ;;
      *"ro.boot.bootreason"* )
        if [[ "$TRACE_MODE" == "matched" ]]; then
          cat <<PROPS
ro.boot.bootreason=reboot,adb
sys.boot.reason=reboot,adb
sys.boot.reason.last=
persist.sys.boot.reason.history=
ro.boot.bootreason_history=
ro.boot.bootreason_last=
PROPS
        else
          cat <<PROPS
ro.boot.bootreason=reboot,recovery
sys.boot.reason=reboot,recovery
sys.boot.reason.last=
persist.sys.boot.reason.history=
ro.boot.bootreason_history=
ro.boot.bootreason_last=
PROPS
        fi
        ;;
      "getprop")
        if [[ "$TRACE_MODE" == "matched" ]]; then
          cat <<PROP
[ro.boot.slot_suffix]: [_a]
[ro.boot.bootreason]: [reboot,adb]
[shadow.boot.marker]: [shadow-hello-init]
PROP
        else
          cat <<PROP
[ro.boot.slot_suffix]: [_a]
[ro.boot.bootreason]: [reboot,recovery]
PROP
        fi
        ;;
      "logcat -d -v threadtime")
        if [[ "$TRACE_MODE" == "matched" ]]; then
          printf '04-19 10:05:00.000 root root I shadow-drm: current boot kernel handoff summary\n'
        else
          printf '04-19 10:05:00.000 root root I ActivityManager: idle\n'
        fi
        ;;
      "logcat -b kernel -d -v threadtime")
        if [[ "$TRACE_MODE" == "matched" ]]; then
          printf '<6>[shadow-drm] current kernel snapshot\n'
        else
          printf '<6>[kernel] boot complete\n'
        fi
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

chmod 0755 "$MOCK_BIN/adb"

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
    value = value[part]

if isinstance(value, bool):
    rendered = "true" if value else "false"
elif value is None:
    rendered = ""
else:
    rendered = str(value)

if rendered != expected:
    raise SystemExit(f"{key_path}: expected {expected!r}, got {rendered!r}")
PY
}

MATCHED_OUTPUT="$TMP_DIR/output-matched"
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=matched \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$MATCHED_OUTPUT" >/dev/null

test -f "$MATCHED_OUTPUT/channels/logcat-last.txt"
test -f "$MATCHED_OUTPUT/meta/bootreason-props-summary.txt"
test -f "$MATCHED_OUTPUT/matches/all-shadow-tags.txt"
grep -Fq 'shadow-hello-init' "$MATCHED_OUTPUT/matches/all-shadow-tags.txt"
grep -Fq 'shadow-owned-init-role:hello-init' "$MATCHED_OUTPUT/matches/all-shadow-tags.txt"
assert_json_field "$MATCHED_OUTPUT/status.json" recovered_previous_boot_traces true
assert_json_field "$MATCHED_OUTPUT/status.json" matched_any_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" previous_boot_channels_with_matches 3
assert_json_field "$MATCHED_OUTPUT/status.json" channels/logcat-last/matched_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/dropbox-system-boot/matched_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/bootreason-props/available true
assert_json_field "$MATCHED_OUTPUT/status.json" bootreason_props/ro.boot.bootreason reboot,adb

CLEAN_OUTPUT="$TMP_DIR/output-clean"
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=clean \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$CLEAN_OUTPUT" >/dev/null

test -f "$CLEAN_OUTPUT/channels/getprop.txt"
assert_json_field "$CLEAN_OUTPUT/status.json" recovered_previous_boot_traces false
assert_json_field "$CLEAN_OUTPUT/status.json" matched_any_shadow_tags false
assert_json_field "$CLEAN_OUTPUT/status.json" previous_boot_channels_with_matches 0
assert_json_field "$CLEAN_OUTPUT/status.json" channels/pmsg0/matched_shadow_tags false
assert_json_field "$CLEAN_OUTPUT/status.json" bootreason_props/sys.boot.reason reboot,recovery

printf 'pixel_boot_recover_traces_smoke: ok\n'
