#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-pixel-boot-safety.XXXXXX")"
MOCK_BIN="$TMP_DIR/bin"
MOCK_IMAGE="$TMP_DIR/mock-boot.img"
EXPECTED_FINGERPRINT="google/sunfish/sunfish:13/TQ3A.230805.001.S2/12655424:user/release-keys"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$MOCK_BIN"
printf 'mock boot image\n' >"$MOCK_IMAGE"

cat >"$MOCK_BIN/adb" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "devices" ]]; then
  printf 'List of devices attached\nTESTSERIAL\tdevice\n'
  exit 0
fi

if [[ "\${1:-}" == "-s" ]]; then
  serial="\${2:-}"
  shift 2
  [[ "\$serial" == "TESTSERIAL" ]] || {
    echo "mock adb: unexpected serial \$serial" >&2
    exit 1
  }
fi

case "\$*" in
  "shell getprop ro.build.fingerprint")
    printf '%s\n' "$EXPECTED_FINGERPRINT"
    ;;
  "shell getprop ro.boot.slot_suffix")
    printf '_a\n'
    ;;
  *)
    echo "mock adb: unexpected args: \$*" >&2
    exit 1
    ;;
esac
EOF

cat >"$MOCK_BIN/fastboot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "devices" ]]; then
  printf 'TESTSERIAL\tfastboot\n'
  exit 0
fi

if [[ "${1:-}" == "-s" ]]; then
  serial="${2:-}"
  shift 2
  [[ "$serial" == "TESTSERIAL" ]] || {
    echo "mock fastboot: unexpected serial $serial" >&2
    exit 1
  }
fi

case "$*" in
  "getvar current-slot")
    printf 'current-slot: a\n'
    ;;
  *)
    echo "mock fastboot: unexpected args: $*" >&2
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

chmod 0755 "$MOCK_BIN/adb" "$MOCK_BIN/fastboot" "$MOCK_BIN/just" "$MOCK_BIN/payload-dumper-go"

TEST_PATH="$MOCK_BIN:$PATH"

assert_contains() {
  local haystack needle
  haystack="$1"
  needle="$2"
  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    echo "pixel_boot_safety_smoke: expected output to contain: $needle" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

assert_success() {
  local output
  output="$("$@" 2>&1)"
  printf '%s\n' "$output"
}

assert_failure() {
  local output status
  set +e
  output="$("$@" 2>&1)"
  status="$?"
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "pixel_boot_safety_smoke: expected failure for: $*" >&2
    echo "$output" >&2
    exit 1
  fi
  printf '%s\n' "$output"
}

flash_without_ack="$(
  assert_failure env PATH="$TEST_PATH" SHADOW_BOOTIMG_SHELL=1 PIXEL_SERIAL=TESTSERIAL \
    "$REPO_ROOT/scripts/pixel/pixel_boot_flash.sh" --dry-run --image "$MOCK_IMAGE"
)"
assert_contains "$flash_without_ack" "refusing to flash without explicit experimental acknowledgement"

flash_default="$(
  assert_success env PATH="$TEST_PATH" SHADOW_BOOTIMG_SHELL=1 PIXEL_SERIAL=TESTSERIAL \
    "$REPO_ROOT/scripts/pixel/pixel_boot_flash.sh" --experimental --dry-run --image "$MOCK_IMAGE"
)"
assert_contains "$flash_default" "current_slot=a"
assert_contains "$flash_default" "known_good_slot=a"
assert_contains "$flash_default" "target_slot=b"
assert_contains "$flash_default" "current_magisk_lane_preserved=true"

flash_active_refused="$(
  assert_failure env PATH="$TEST_PATH" SHADOW_BOOTIMG_SHELL=1 PIXEL_SERIAL=TESTSERIAL \
    "$REPO_ROOT/scripts/pixel/pixel_boot_flash.sh" --experimental --slot active --dry-run --image "$MOCK_IMAGE"
)"
assert_contains "$flash_active_refused" "clobber the working Magisk lane"
assert_contains "$flash_active_refused" "--allow-active-slot"

flash_active_allowed="$(
  assert_success env PATH="$TEST_PATH" SHADOW_BOOTIMG_SHELL=1 PIXEL_SERIAL=TESTSERIAL \
    "$REPO_ROOT/scripts/pixel/pixel_boot_flash.sh" --experimental --slot active --allow-active-slot --dry-run --image "$MOCK_IMAGE"
)"
assert_contains "$flash_active_allowed" "target_slot=a"
assert_contains "$flash_active_allowed" "current_magisk_lane_preserved=false"

restore_without_slot="$(
  assert_failure env PATH="$TEST_PATH" SHADOW_BOOTIMG_SHELL=1 PIXEL_SERIAL=TESTSERIAL \
    "$REPO_ROOT/scripts/pixel/pixel_boot_restore.sh" --dry-run --image "$MOCK_IMAGE"
)"
assert_contains "$restore_without_slot" "--slot is required"

restore_inactive="$(
  assert_success env PATH="$TEST_PATH" SHADOW_BOOTIMG_SHELL=1 PIXEL_SERIAL=TESTSERIAL \
    "$REPO_ROOT/scripts/pixel/pixel_boot_restore.sh" --slot inactive --dry-run --image "$MOCK_IMAGE"
)"
assert_contains "$restore_inactive" "transport=adb"
assert_contains "$restore_inactive" "target_slot=b"

cat >"$TMP_DIR/last-action.json" <<'EOF'
{
  "activate_target": true,
  "current_slot": "a",
  "kind": "boot_flash",
  "known_good_slot": "a",
  "target_slot": "b"
}
EOF

recover_dry_run="$(
  assert_success env PATH="$TEST_PATH" SHADOW_BOOTIMG_SHELL=1 PIXEL_SERIAL=TESTSERIAL \
    "$REPO_ROOT/scripts/pixel/pixel_boot_recover.sh" --metadata "$TMP_DIR/last-action.json" --dry-run --image "$MOCK_IMAGE"
)"
assert_contains "$recover_dry_run" "known_good_slot=a"
assert_contains "$recover_dry_run" "target_slot=b"
assert_contains "$recover_dry_run" "restore_target_slot=true"

echo "pixel_boot_safety_smoke: ok"
