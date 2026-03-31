#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

run_dir="${1:-$(pixel_selected_run_dir)}"
if [[ -z "${run_dir:-}" || ! -d "$run_dir" ]]; then
  echo "pixel_verify: run directory not found" >&2
  exit 1
fi

session_output="$run_dir/session-output.txt"
frame_artifact="$run_dir/shadow-frame.ppm"
compositor_marker="$(pixel_compositor_marker)"
client_marker="$(pixel_client_marker)"

if [[ ! -f "$session_output" ]]; then
  echo "pixel_verify: missing session output: $session_output" >&2
  exit 1
fi

compositor_ok=false
client_ok=false
frame_ok=false
require_client_marker="${PIXEL_VERIFY_REQUIRE_CLIENT_MARKER-1}"

if grep -Fq "$compositor_marker" "$session_output"; then
  compositor_ok=true
fi
if [[ -z "$require_client_marker" ]]; then
  client_ok=true
elif grep -Fq "$client_marker" "$session_output"; then
  client_ok=true
fi
if [[ -s "$frame_artifact" ]]; then
  frame_ok=true
fi

success=false
if [[ "$compositor_ok" == true && "$client_ok" == true && "$frame_ok" == true ]]; then
  success=true
fi

pixel_write_status_json "$run_dir/status.json" \
  run_dir="$run_dir" \
  compositor_marker_seen="$compositor_ok" \
  client_marker_seen="$client_ok" \
  frame_artifact_present="$frame_ok" \
  success="$success"

cat "$run_dir/status.json"

if [[ "$success" != true ]]; then
  exit 1
fi
