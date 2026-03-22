#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_PATH="${INIT_WRAPPER_OUT:-$(build_dir)/init-wrapper}"
OUT_LINK="${INIT_WRAPPER_OUT_LINK:-$(build_dir)/init-wrapper-result}"

mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -f "$OUT_LINK"

nix build "$(repo_root)#init-wrapper" --out-link "$OUT_LINK"

cp "$OUT_LINK/bin/init-wrapper" "$OUTPUT_PATH"
chmod 0755 "$OUTPUT_PATH"

file_output="$(file "$OUTPUT_PATH")"
printf '%s\n' "$file_output"

if [[ "$file_output" == *"dynamically linked"* ]]; then
  echo "build_init_wrapper: expected a static binary, got a dynamic one" >&2
  exit 1
fi

printf 'Built init wrapper: %s\n' "$OUTPUT_PATH"
