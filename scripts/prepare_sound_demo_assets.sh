#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_SOURCE_ASSET_PATH="$REPO_ROOT/runtime/app-sound-smoke/assets/demo-tone.mp3"
SOURCE_ASSET_PATH="${SHADOW_SOUND_DEMO_SOURCE_ASSET_PATH:-$DEFAULT_SOURCE_ASSET_PATH}"
SOURCE_PATH_IN_BUNDLE="${SHADOW_SOUND_DEMO_SOURCE_PATH_IN_BUNDLE:-assets/$(basename "$SOURCE_ASSET_PATH")}"
DURATION_MS="${SHADOW_SOUND_DEMO_DURATION_MS:-2640}"
EXPECTED_SHA256="${SHADOW_SOUND_DEMO_EXPECTED_SHA256:-d060e3aede3e768da2c246bda3471866d0e8e9125e32380e34325548a7629fc9}"

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

python3 - "$DURATION_MS" "$SOURCE_PATH_IN_BUNDLE" <<'PY'
import json
import sys

duration_ms, source_path = sys.argv[1:3]
print(json.dumps({
    "source": {
        "durationMs": int(duration_ms),
        "kind": "file",
        "path": source_path,
    },
}, indent=2))
PY
