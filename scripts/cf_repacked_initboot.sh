#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_IMAGE="${INIT_BOOT_OUT:-$(build_dir)/init_boot.repacked.img}"
WAIT_FOR="${CF_WAIT_FOR:-VIRTUAL_DEVICE_BOOT_COMPLETED|GUEST_BUILD_FINGERPRINT}"
TIMEOUT_SECS="${CF_WAIT_TIMEOUT:-180}"

"$SCRIPT_DIR/init_boot_repack.sh" --output "$OUTPUT_IMAGE"
exec "$SCRIPT_DIR/cf_launch.sh" \
  --init-boot "$OUTPUT_IMAGE" \
  --wait-for "$WAIT_FOR" \
  --timeout "$TIMEOUT_SECS"
