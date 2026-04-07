#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSET_DIR="${SHADOW_SOUND_DEMO_ASSET_DIR:-$REPO_ROOT/build/runtime/app-sound-smoke-assets}"
AUDIO_DIR="$ASSET_DIR/audio"
DEFAULT_SOURCE_ASSET_PATH="$REPO_ROOT/runtime/app-sound-smoke/assets/demo-tone.mp3"
SOURCE_ASSET_PATH="${SHADOW_SOUND_DEMO_SOURCE_ASSET_PATH:-$DEFAULT_SOURCE_ASSET_PATH}"
OUTPUT_BASENAME="${SHADOW_SOUND_DEMO_OUTPUT_BASENAME:-$(basename "$SOURCE_ASSET_PATH")}"
OUTPUT_PATH="$AUDIO_DIR/$OUTPUT_BASENAME"
DURATION_MS="${SHADOW_SOUND_DEMO_DURATION_MS:-2640}"
EXPECTED_SHA256="${SHADOW_SOUND_DEMO_EXPECTED_SHA256:-d060e3aede3e768da2c246bda3471866d0e8e9125e32380e34325548a7629fc9}"

mkdir -p "$AUDIO_DIR"
if [[ -n "${SHADOW_SOUND_DEMO_SOURCE_ASSET_PATH-}" || -n "${SHADOW_SOUND_DEMO_EXPECTED_SHA256-}" ]]; then
  if [[ -z "${SHADOW_SOUND_DEMO_DURATION_MS-}" ]]; then
    echo "prepare_sound_demo_assets: custom source/hash requires SHADOW_SOUND_DEMO_DURATION_MS" >&2
    exit 1
  fi
fi
if [[ ! -f "$SOURCE_ASSET_PATH" ]]; then
  echo "prepare_sound_demo_assets: missing source asset: $SOURCE_ASSET_PATH" >&2
  exit 1
fi

actual_sha256="$(
  python3 - "$SOURCE_ASSET_PATH" <<'PY'
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
  echo "prepare_sound_demo_assets: unexpected source asset hash: $actual_sha256" >&2
  exit 1
fi

cp "$SOURCE_ASSET_PATH" "$OUTPUT_PATH"
chmod 0644 "$OUTPUT_PATH"

python3 - "$ASSET_DIR" "$OUTPUT_PATH" "$DURATION_MS" <<'PY'
import json
import os
import sys

asset_dir, output_path, duration_ms = sys.argv[1:4]
print(json.dumps({
    "assetDir": os.path.abspath(asset_dir),
    "source": {
        "durationMs": int(duration_ms),
        "kind": "file",
        "path": os.path.relpath(output_path, asset_dir),
    },
}, indent=2))
PY
