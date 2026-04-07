#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ASSET_DIR="${SHADOW_SOUND_DEMO_ASSET_DIR:-$REPO_ROOT/build/runtime/app-sound-smoke-assets}"
AUDIO_DIR="$ASSET_DIR/audio"
WAV_PATH="$AUDIO_DIR/demo-tone.wav"
DURATION_MS="${SHADOW_SOUND_DEMO_DURATION_MS:-2600}"
FREQUENCY_HZ="${SHADOW_SOUND_DEMO_FREQUENCY_HZ:-440}"
SAMPLE_RATE_HZ="${SHADOW_SOUND_DEMO_SAMPLE_RATE_HZ:-48000}"
CHANNELS="${SHADOW_SOUND_DEMO_CHANNELS:-2}"

mkdir -p "$AUDIO_DIR"

python3 - "$WAV_PATH" "$DURATION_MS" "$FREQUENCY_HZ" "$SAMPLE_RATE_HZ" "$CHANNELS" <<'PY'
import math
import struct
import sys
import wave

output_path, duration_ms, frequency_hz, sample_rate_hz, channels = sys.argv[1:6]
duration_ms = int(duration_ms)
frequency_hz = float(frequency_hz)
sample_rate_hz = int(sample_rate_hz)
channels = int(channels)
frame_count = max(1, round(sample_rate_hz * duration_ms / 1000))
amplitude = 0.22 * 32767

with wave.open(output_path, "wb") as wav:
    wav.setnchannels(channels)
    wav.setsampwidth(2)
    wav.setframerate(sample_rate_hz)
    data = bytearray()
    for frame_index in range(frame_count):
        sample = int(amplitude * math.sin(2 * math.pi * frequency_hz * frame_index / sample_rate_hz))
        for _ in range(channels):
            data += struct.pack("<h", sample)
    wav.writeframes(data)
PY

python3 - "$ASSET_DIR" "$WAV_PATH" "$DURATION_MS" <<'PY'
import json
import os
import sys

asset_dir, wav_path, duration_ms = sys.argv[1:4]
print(json.dumps({
    "assetDir": os.path.abspath(asset_dir),
    "source": {
        "durationMs": int(duration_ms),
        "kind": "file",
        "path": os.path.relpath(wav_path, asset_dir),
    },
}, indent=2))
PY
