#!/usr/bin/env bash
set -euo pipefail

printf 'fake-linux-spike-stdout source=%s\n' "${SHADOW_AUDIO_SPIKE_SOURCE_KIND:-unknown}"
printf 'fake-linux-spike-stderr source=%s\n' "${SHADOW_AUDIO_SPIKE_SOURCE_KIND:-unknown}" >&2

if [[ -n "${SHADOW_AUDIO_SPIKE_TEST_OUTPUT:-}" ]]; then
  mkdir -p "$(dirname "$SHADOW_AUDIO_SPIKE_TEST_OUTPUT")"
  python3 - <<'PY' > "$SHADOW_AUDIO_SPIKE_TEST_OUTPUT"
import json
import os

print(json.dumps({
    "filePath": os.environ.get("SHADOW_AUDIO_SPIKE_FILE_PATH"),
    "sourceKind": os.environ.get("SHADOW_AUDIO_SPIKE_SOURCE_KIND"),
    "url": os.environ.get("SHADOW_AUDIO_SPIKE_URL"),
}))
PY
fi

trap 'exit 0' TERM

sleep "${SHADOW_AUDIO_SPIKE_TEST_SLEEP_SECS:-5}" &
wait "$!"
