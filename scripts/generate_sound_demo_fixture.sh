#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_PATH="${1:-$REPO_ROOT/runtime/app-sound-smoke/assets/demo-tone.mp3}"
EXPECTED_SHA256="d060e3aede3e768da2c246bda3471866d0e8e9125e32380e34325548a7629fc9"

mkdir -p "$(dirname "$OUTPUT_PATH")"

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

tmp_output="$tmp_dir/demo-tone.mp3"

nix shell --accept-flake-config --inputs-from "$REPO_ROOT" nixpkgs#ffmpeg -c \
  ffmpeg -hide_banner -loglevel error \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=2.6' \
  -ac 2 -ar 48000 \
  -c:a libmp3lame -b:a 128k \
  -map_metadata -1 -write_xing 0 -id3v2_version 0 \
  "$tmp_output"

actual_sha256="$(
  python3 - "$tmp_output" <<'PY'
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
with path.open("rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())
PY
)"

if [[ "$actual_sha256" != "$EXPECTED_SHA256" ]]; then
  echo "generate_sound_demo_fixture: unexpected fixture hash: $actual_sha256" >&2
  exit 1
fi

mv "$tmp_output" "$OUTPUT_PATH"
chmod 0644 "$OUTPUT_PATH"
printf '%s\n' "$OUTPUT_PATH"
