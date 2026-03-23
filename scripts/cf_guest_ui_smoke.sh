#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

GUEST_UI_NAMESPACE="${SHADOW_GUEST_UI_NAMESPACE:-$(worktree_basename)-$$}"
OUTPUT_IMAGE="${INIT_BOOT_OUT:-$(build_dir)/init_boot.guest_ui.${GUEST_UI_NAMESPACE}.img}"
EXPECTED_FRAME_CHECKSUM="${SHADOW_GUEST_COUNTER_EXPECTED_CHECKSUM:-dd64a1693b87ade5}"
EXPECTED_FRAME_SIZE="${SHADOW_GUEST_COUNTER_EXPECTED_SIZE:-220x120}"
COMPOSITOR_MARKER="${SHADOW_GUEST_COMPOSITOR_WAIT_FOR:-\\[shadow-guest-compositor\\] captured-frame .*checksum=${EXPECTED_FRAME_CHECKSUM} size=${EXPECTED_FRAME_SIZE}}"
CLIENT_MARKER="${SHADOW_GUEST_CLIENT_WAIT_FOR:-\\[shadow-guest-counter\\] frame-committed checksum=${EXPECTED_FRAME_CHECKSUM} size=${EXPECTED_FRAME_SIZE}}"
GUEST_TIMEOUT_SECS="${SHADOW_GUEST_UI_TIMEOUT:-120}"
BOOT_MARKER="${CF_WAIT_FOR:-}"
BOOT_TIMEOUT_SECS="${CF_WAIT_TIMEOUT:-180}"

"$SCRIPT_DIR/init_boot_guest_ui.sh" --output "$OUTPUT_IMAGE"
"$SCRIPT_DIR/cf_launch.sh" \
  --init-boot "$OUTPUT_IMAGE" \
  --wait-for "$COMPOSITOR_MARKER" \
  --timeout "$GUEST_TIMEOUT_SECS"

INSTANCE="$(active_instance_name)"

printf 'Waiting for guest client marker: %s\n' "$CLIENT_MARKER"
wait_for_remote_pattern "$INSTANCE" "$CLIENT_MARKER" "$GUEST_TIMEOUT_SECS"
printf 'Guest client marker observed for instance %s\n' "$INSTANCE"

if [[ -n "${BOOT_MARKER//[[:space:]]/}" ]]; then
  printf 'Waiting for Android boot marker: %s\n' "$BOOT_MARKER"
  wait_for_remote_pattern "$INSTANCE" "$BOOT_MARKER" "$BOOT_TIMEOUT_SECS"
  printf 'Boot marker observed for instance %s\n' "$INSTANCE"
else
  printf 'Skipping Android boot marker wait; guest-ui smoke only asserts compositor and client markers.\n'
fi
