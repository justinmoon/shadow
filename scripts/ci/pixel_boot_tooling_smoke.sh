#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-pixel-boot-tooling.XXXXXX")"
MOCK_BIN="$TMP_DIR/bin"
COMMON_ROOT="$TMP_DIR/common-root"
LOCAL_BOOT="$TMP_DIR/local-boot.img"
SHARED_BOOT="$TMP_DIR/shared-boot.img"
PROBE_IMAGE="$TMP_DIR/probe.img"
ONESHOT_OUTPUT="$TMP_DIR/oneshot-output"
FLASH_RUN_OUTPUT="$TMP_DIR/flash-run-output"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$MOCK_BIN"
printf 'local boot image\n' >"$LOCAL_BOOT"
printf 'shared boot image\n' >"$SHARED_BOOT"
printf 'probe image\n' >"$PROBE_IMAGE"

cat >"$MOCK_BIN/adb" <<'EOF'
#!/usr/bin/env bash
exit 0
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

assert_eq() {
  local actual expected message
  actual="$1"
  expected="$2"
  message="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "pixel_boot_tooling_smoke: $message" >&2
    echo "  actual:   $actual" >&2
    echo "  expected: $expected" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack needle
  haystack="$1"
  needle="$2"
  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    echo "pixel_boot_tooling_smoke: expected output to contain: $needle" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

shared_path="$(
  env SHADOW_REPO_COMMON_ROOT="$COMMON_ROOT" \
    bash -lc 'cd "$0" && source scripts/lib/pixel_common.sh && pixel_shared_stock_boot_img' "$REPO_ROOT"
)"
assert_eq \
  "$shared_path" \
  "$COMMON_ROOT/build/shared/pixel/root/boot.img" \
  "shared stock boot path should be rooted at git common-dir"

worktree_metadata_path="$(
  env SHADOW_REPO_COMMON_ROOT="$COMMON_ROOT" \
    bash -lc 'cd "$0" && source scripts/lib/pixel_common.sh && pixel_boot_last_action_json' "$REPO_ROOT"
)"
assert_eq \
  "$worktree_metadata_path" \
  "$REPO_ROOT/build/pixel/boot/last-action.json" \
  "boot metadata must stay worktree-local"

resolved_local="$(
  env PIXEL_ROOT_STOCK_BOOT_IMG="$LOCAL_BOOT" PIXEL_SHARED_STOCK_BOOT_IMG="$SHARED_BOOT" \
    bash -lc 'cd "$0" && source scripts/lib/pixel_common.sh && pixel_resolve_stock_boot_img' "$REPO_ROOT"
)"
assert_eq \
  "$resolved_local" \
  "$LOCAL_BOOT" \
  "local stock boot image should win over the shared fallback"

rm -f "$LOCAL_BOOT"
resolved_shared="$(
  env PIXEL_ROOT_STOCK_BOOT_IMG="$LOCAL_BOOT" PIXEL_SHARED_STOCK_BOOT_IMG="$SHARED_BOOT" \
    bash -lc 'cd "$0" && source scripts/lib/pixel_common.sh && pixel_resolve_stock_boot_img' "$REPO_ROOT"
)"
assert_eq \
  "$resolved_shared" \
  "$SHARED_BOOT" \
  "shared stock boot image should be used when the worktree-local copy is missing"

oneshot_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 PIXEL_SERIAL=TESTSERIAL \
    "$REPO_ROOT/scripts/pixel/pixel_boot_oneshot.sh" \
      --dry-run \
      --image "$PROBE_IMAGE" \
      --output "$ONESHOT_OUTPUT" \
      --wait-ready 30 \
      --adb-timeout 45 \
      --boot-timeout 60 \
      --no-wait-boot-completed
)"

assert_contains "$oneshot_output" "pixel_boot_oneshot: dry-run"
assert_contains "$oneshot_output" "serial=TESTSERIAL"
assert_contains "$oneshot_output" "image=$PROBE_IMAGE"
assert_contains "$oneshot_output" "output_dir=$ONESHOT_OUTPUT"
assert_contains "$oneshot_output" "metadata_path=$ONESHOT_OUTPUT/boot-action.json"
assert_contains "$oneshot_output" "collect_output_dir=$ONESHOT_OUTPUT/collect"
assert_contains "$oneshot_output" "wait_ready_secs=30"
assert_contains "$oneshot_output" "adb_timeout_secs=45"
assert_contains "$oneshot_output" "boot_timeout_secs=60"
assert_contains "$oneshot_output" "wait_boot_completed=false"

if [[ -e "$ONESHOT_OUTPUT" ]]; then
  echo "pixel_boot_tooling_smoke: dry-run should not create the output dir" >&2
  exit 1
fi

flash_run_output="$(
  env PATH="$MOCK_BIN:$PATH" SHADOW_BOOTIMG_SHELL=1 PIXEL_SERIAL=TESTSERIAL \
    "$REPO_ROOT/scripts/pixel/pixel_boot_flash_run.sh" \
      --dry-run \
      --image "$PROBE_IMAGE" \
      --slot inactive \
      --output "$FLASH_RUN_OUTPUT" \
      --wait-ready 30 \
      --adb-timeout 45 \
      --boot-timeout 60 \
      --allow-active-slot \
      --recover-after
)"

assert_contains "$flash_run_output" "pixel_boot_flash_run: dry-run"
assert_contains "$flash_run_output" "serial=TESTSERIAL"
assert_contains "$flash_run_output" "image=$PROBE_IMAGE"
assert_contains "$flash_run_output" "requested_slot=inactive"
assert_contains "$flash_run_output" "output_dir=$FLASH_RUN_OUTPUT"
assert_contains "$flash_run_output" "metadata_path=$FLASH_RUN_OUTPUT/boot-action.json"
assert_contains "$flash_run_output" "collect_output_dir=$FLASH_RUN_OUTPUT/collect"
assert_contains "$flash_run_output" "wait_ready_secs=30"
assert_contains "$flash_run_output" "adb_timeout_secs=45"
assert_contains "$flash_run_output" "boot_timeout_secs=60"
assert_contains "$flash_run_output" "allow_active_slot=true"
assert_contains "$flash_run_output" "recover_after=true"
assert_contains "$flash_run_output" "activate_target=true"

if [[ -e "$FLASH_RUN_OUTPUT" ]]; then
  echo "pixel_boot_tooling_smoke: flash-run dry-run should not create the output dir" >&2
  exit 1
fi

echo "pixel_boot_tooling_smoke: ok"
