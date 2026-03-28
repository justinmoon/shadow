#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_PATH="${SHADOW_SESSION_OUT:-$(build_dir)/shadow-session}"
OUT_LINK="${SHADOW_SESSION_OUT_LINK:-$(build_dir)/shadow-session-result}"

mkdir -p "$(dirname "$OUTPUT_PATH")"
rm -f "$OUT_LINK"

nix build "$(repo_root)#shadow-session" --out-link "$OUT_LINK"

cp "$OUT_LINK/bin/shadow-session" "$OUTPUT_PATH"
chmod 0755 "$OUTPUT_PATH"

file_output="$(file "$OUTPUT_PATH")"
printf '%s\n' "$file_output"

if [[ "$file_output" == *"dynamically linked"* ]]; then
  echo "build_shadow_session: expected a static binary, got a dynamic one" >&2
  exit 1
fi

printf 'Built shadow session: %s\n' "$OUTPUT_PATH"
