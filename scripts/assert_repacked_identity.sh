#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

stock_image="$(cached_init_boot_image)"
repacked_image="${INIT_BOOT_OUT:-$(build_dir)/init_boot.repacked.img}"

if [[ ! -f "$stock_image" ]]; then
  echo "assert_repacked_identity: stock image not found: $stock_image" >&2
  exit 1
fi

if [[ ! -f "$repacked_image" ]]; then
  echo "assert_repacked_identity: repacked image not found: $repacked_image" >&2
  exit 1
fi

if ! cmp -s "$stock_image" "$repacked_image"; then
  echo "assert_repacked_identity: images differ" >&2
  sha256sum "$stock_image" "$repacked_image" >&2
  exit 1
fi

echo "Identity repack matches stock init_boot.img"
sha256sum "$stock_image" "$repacked_image"
