#!/usr/bin/env bash
set -euo pipefail

printf 'fake-linux-spike-stdout source=%s\n' "${SHADOW_AUDIO_SPIKE_SOURCE_KIND:-unknown}"
printf 'fake-linux-spike-stderr source=%s\n' "${SHADOW_AUDIO_SPIKE_SOURCE_KIND:-unknown}" >&2

trap 'exit 0' TERM

sleep "${SHADOW_AUDIO_SPIKE_TEST_SLEEP_SECS:-5}" &
wait "$!"
