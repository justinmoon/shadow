#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-pixel-boot-recover.XXXXXX")"
MOCK_BIN="$TMP_DIR/bin"
RUN_TOKEN="recover-run-token-1234"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$MOCK_BIN"

cat >"$MOCK_BIN/adb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

TRACE_MODE="${MOCK_TRACE_MODE:?}"
TRACE_RUN_TOKEN="${MOCK_TRACE_RUN_TOKEN:-}"
TRACE_ROOT_MODE="${MOCK_TRACE_ROOT_MODE:-available}"

emit_shell_command() {
  local cmd="$1"

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
        printf '04-19 10:00:00.000 root root I shadow-hello-init: previous boot breadcrumb run_token=%s\n' "$TRACE_RUN_TOKEN"
      elif [[ "$TRACE_MODE" == "token-only" ]]; then
        printf '04-19 10:00:00.000 root root I bootstat: previous boot breadcrumb run_token=%s\n' "$TRACE_RUN_TOKEN"
      else
        printf '04-19 10:00:00.000 root root I bootstat: cold boot\n'
      fi
      ;;
    "dumpsys dropbox --print SYSTEM_BOOT")
      if [[ "$TRACE_MODE" == "matched" ]]; then
        printf 'SYSTEM_BOOT\n[shadow-drm] restored previous boot trace run_token=%s\n' "$TRACE_RUN_TOKEN"
      else
        printf 'SYSTEM_BOOT\nBoot completed normally\n'
      fi
      ;;
    "dumpsys dropbox --print SYSTEM_LAST_KMSG")
      if [[ "$TRACE_MODE" == "matched" ]]; then
        printf 'SYSTEM_LAST_KMSG\n<6>[shadow-hello-init] previous kernel breadcrumb\n'
      else
        printf 'SYSTEM_LAST_KMSG\nkernel boot without shadow tags\n'
      fi
      ;;
    "cat /dev/pmsg0")
      if [[ "$TRACE_MODE" == "matched" ]]; then
        printf 'shadow-owned-init-run-token:%s\nshadow-owned-init-role:hello-init\nshadow-owned-init-impl:c-static\n' "$TRACE_RUN_TOKEN"
      elif [[ "$TRACE_MODE" == "token-only" ]]; then
        printf 'run_token=%s\n' "$TRACE_RUN_TOKEN"
      else
        printf 'audit: pmsg readable but empty of shadow tags\n'
      fi
      ;;
    *"/sys/fs/pstore"*)
      if [[ "$TRACE_MODE" == "matched" ]]; then
        printf '== /sys/fs/pstore/console-ramoops-0 ==\n<6>[shadow-hello-init] pstore breadcrumb run_token=%s\nshadow-owned-init-role:hello-init\n' "$TRACE_RUN_TOKEN"
      else
        printf 'no pstore entries\n'
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
  shell)
    shift
    if [[ "$#" -eq 1 && ( "$1" == "/debug_ramdisk/su 0 sh -c id" || "$1" == "su 0 sh -c id" ) ]]; then
      if [[ "$TRACE_ROOT_MODE" == "available" ]]; then
        printf 'uid=0(root) gid=0(root) groups=0(root)\n'
        exit 0
      fi
      exit 1
    fi
    if [[ "$#" -eq 3 && ( "$1" == "/debug_ramdisk/su" || "$1" == "su" ) && "$2" == "0" && "$3" == "sh" ]]; then
      if [[ "$TRACE_ROOT_MODE" != "available" ]]; then
        exit 1
      fi
      cmd="$(cat)"
      emit_shell_command "$cmd"
      exit 0
    fi
    cmd="$*"
    emit_shell_command "$cmd"
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

write_recover_context() {
  local parent_dir image_path run_token
  parent_dir="$1"
  image_path="$2"
  run_token="$3"

  mkdir -p "$parent_dir"
  cat >"$parent_dir/status.json" <<EOF
{
  "image": "$image_path",
  "kind": "boot_oneshot"
}
EOF
cat >"$image_path.hello-init.json" <<EOF
{
  "kind": "hello_init_build",
  "run_token": "$run_token",
  "log_kmsg": true,
  "log_pmsg": true
}
EOF
}

MATCHED_PARENT="$TMP_DIR/output-matched"
MATCHED_IMAGE="$TMP_DIR/output-matched.img"
MATCHED_OUTPUT="$MATCHED_PARENT/recover-traces"
write_recover_context "$MATCHED_PARENT" "$MATCHED_IMAGE" "$RUN_TOKEN"
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=matched \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$MATCHED_OUTPUT" >/dev/null

test -f "$MATCHED_OUTPUT/channels/logcat-last.txt"
test -f "$MATCHED_OUTPUT/channels/pstore.txt"
test -f "$MATCHED_OUTPUT/meta/bootreason-props-summary.txt"
test -f "$MATCHED_OUTPUT/meta/expected-run-token.txt"
test -f "$MATCHED_OUTPUT/meta/root-state.txt"
test -f "$MATCHED_OUTPUT/matches/all-shadow-tags.txt"
test -f "$MATCHED_OUTPUT/matches/all-run-token-matches.txt"
grep -Fq 'shadow-hello-init' "$MATCHED_OUTPUT/matches/all-shadow-tags.txt"
grep -Fq 'shadow-owned-init-role:hello-init' "$MATCHED_OUTPUT/matches/all-shadow-tags.txt"
grep -Fq "$RUN_TOKEN" "$MATCHED_OUTPUT/matches/all-run-token-matches.txt"
assert_json_field "$MATCHED_OUTPUT/status.json" recovered_previous_boot_traces true
assert_json_field "$MATCHED_OUTPUT/status.json" matched_any_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" matched_any_correlated_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" proof_ok true
assert_json_field "$MATCHED_OUTPUT/status.json" expected_run_token "$RUN_TOKEN"
assert_json_field "$MATCHED_OUTPUT/status.json" expected_run_token_source image-metadata
assert_json_field "$MATCHED_OUTPUT/status.json" expected_durable_logging_summary "kmsg=true,pmsg=true"
assert_json_field "$MATCHED_OUTPUT/status.json" absence_reason_summary ""
assert_json_field "$MATCHED_OUTPUT/status.json" previous_boot_channel_attempts 5
assert_json_field "$MATCHED_OUTPUT/status.json" previous_boot_channels_with_matches 4
assert_json_field "$MATCHED_OUTPUT/status.json" uncorrelated_previous_boot_channels_with_matches 1
assert_json_field "$MATCHED_OUTPUT/status.json" previous_boot_channels_with_shadow_hints 1
assert_json_field "$MATCHED_OUTPUT/status.json" matched_any_uncorrelated_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" root_available true
assert_json_field "$MATCHED_OUTPUT/status.json" root_id "uid=0(root) gid=0(root) groups=0(root)"
assert_json_field "$MATCHED_OUTPUT/status.json" channels/logcat-last/matched_expected_run_token true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/logcat-last/correlated true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/logcat-last/correlation_state correlated
assert_json_field "$MATCHED_OUTPUT/status.json" channels/logcat-last/matched_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/dropbox-system-boot/matched_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/dropbox-system-boot/matched_expected_run_token true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/dropbox-system-last-kmsg/matched_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/dropbox-system-last-kmsg/matched_expected_run_token false
assert_json_field "$MATCHED_OUTPUT/status.json" channels/dropbox-system-last-kmsg/correlation_state shadow-hint-only
assert_json_field "$MATCHED_OUTPUT/status.json" channels/pmsg0/requested_access_mode root
assert_json_field "$MATCHED_OUTPUT/status.json" channels/pmsg0/actual_access_mode root
assert_json_field "$MATCHED_OUTPUT/status.json" channels/pmsg0/matched_expected_run_token true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/pstore/requested_access_mode root
assert_json_field "$MATCHED_OUTPUT/status.json" channels/pstore/actual_access_mode root
assert_json_field "$MATCHED_OUTPUT/status.json" channels/pstore/matched_shadow_tags true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/pstore/matched_expected_run_token true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/pstore/correlated true
assert_json_field "$MATCHED_OUTPUT/status.json" channels/bootreason-props/available true
assert_json_field "$MATCHED_OUTPUT/status.json" bootreason_props/ro.boot.bootreason reboot,adb

CLEAN_PARENT="$TMP_DIR/output-clean"
CLEAN_IMAGE="$TMP_DIR/output-clean.img"
CLEAN_OUTPUT="$CLEAN_PARENT/recover-traces"
write_recover_context "$CLEAN_PARENT" "$CLEAN_IMAGE" "$RUN_TOKEN"
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=clean \
  MOCK_TRACE_ROOT_MODE=unavailable \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$CLEAN_OUTPUT" >/dev/null

test -f "$CLEAN_OUTPUT/channels/getprop.txt"
assert_json_field "$CLEAN_OUTPUT/status.json" recovered_previous_boot_traces false
assert_json_field "$CLEAN_OUTPUT/status.json" matched_any_shadow_tags false
assert_json_field "$CLEAN_OUTPUT/status.json" matched_any_correlated_shadow_tags false
assert_json_field "$CLEAN_OUTPUT/status.json" proof_ok false
assert_json_field "$CLEAN_OUTPUT/status.json" matched_any_uncorrelated_shadow_tags false
assert_json_field "$CLEAN_OUTPUT/status.json" expected_durable_logging_summary "kmsg=true,pmsg=true"
assert_json_field "$CLEAN_OUTPUT/status.json" absence_reason_summary "pmsg_root_unavailable,pstore_root_unavailable"
assert_json_field "$CLEAN_OUTPUT/status.json" previous_boot_channel_attempts 5
assert_json_field "$CLEAN_OUTPUT/status.json" previous_boot_channels_with_matches 0
assert_json_field "$CLEAN_OUTPUT/status.json" root_available false
assert_json_field "$CLEAN_OUTPUT/status.json" channels/pmsg0/requested_access_mode root
assert_json_field "$CLEAN_OUTPUT/status.json" channels/pmsg0/actual_access_mode root-unavailable
assert_json_field "$CLEAN_OUTPUT/status.json" channels/pmsg0/available false
assert_json_field "$CLEAN_OUTPUT/status.json" channels/pmsg0/matched_shadow_tags false
assert_json_field "$CLEAN_OUTPUT/status.json" channels/pstore/requested_access_mode root
assert_json_field "$CLEAN_OUTPUT/status.json" channels/pstore/actual_access_mode root-unavailable
assert_json_field "$CLEAN_OUTPUT/status.json" channels/pstore/available false
assert_json_field "$CLEAN_OUTPUT/status.json" bootreason_props/sys.boot.reason reboot,recovery

TOKEN_ONLY_PARENT="$TMP_DIR/output-token-only"
TOKEN_ONLY_IMAGE="$TMP_DIR/output-token-only.img"
TOKEN_ONLY_OUTPUT="$TOKEN_ONLY_PARENT/recover-traces"
write_recover_context "$TOKEN_ONLY_PARENT" "$TOKEN_ONLY_IMAGE" "$RUN_TOKEN"
env \
  PATH="$MOCK_BIN:$PATH" \
  PIXEL_SERIAL=TESTSERIAL \
  MOCK_TRACE_MODE=token-only \
  MOCK_TRACE_RUN_TOKEN="$RUN_TOKEN" \
  "$REPO_ROOT/scripts/pixel/pixel_boot_recover_traces.sh" \
  --output "$TOKEN_ONLY_OUTPUT" >/dev/null

assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" matched_any_shadow_tags false
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" matched_any_expected_run_token true
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" matched_any_correlated_shadow_tags false
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" proof_ok false
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" recovered_previous_boot_traces false
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" expected_durable_logging_summary "kmsg=true,pmsg=true"
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" previous_boot_channels_with_matches 0
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" channels/logcat-last/correlation_state token-only
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" channels/logcat-last/correlated false
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" channels/logcat-last/matched_expected_run_token true
assert_json_field "$TOKEN_ONLY_OUTPUT/status.json" channels/logcat-last/matched_shadow_tags false

printf 'pixel_boot_recover_traces_smoke: ok\n'
