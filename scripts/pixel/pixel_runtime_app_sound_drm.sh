#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

stage_only=0
if [[ -n "${PIXEL_RUNTIME_APP_PREP_ONLY-}" || -n "${PIXEL_RUNTIME_APP_PREPARE_ONLY-}" || -n "${PIXEL_RUNTIME_APP_STAGE_ONLY-}" ]]; then
  stage_only=1
fi
serial=""
run_dir="${PIXEL_GUEST_RUN_DIR-}"
audio_summary_device_path="${PIXEL_RUNTIME_AUDIO_SPIKE_SUMMARY_PATH:-$(pixel_runtime_dir)/audio-spike-summary.json}"
asset_json="$("$SCRIPT_DIR/runtime/prepare_sound_demo_assets.sh")"
runtime_app_config_json="${SHADOW_RUNTIME_APP_CONFIG_JSON:-$(
  ASSET_JSON="$asset_json" python3 - <<'PY'
import json
import os

asset = json.loads(os.environ["ASSET_JSON"])
print(json.dumps({"source": asset["source"]}))
PY
)}"
source_path_in_bundle="$(
  ASSET_JSON="$asset_json" python3 - <<'PY'
import json
import os

asset = json.loads(os.environ["ASSET_JSON"])
print(asset["source"]["path"])
PY
)"

sound_guest_env=''
if (( stage_only == 0 )); then
  serial="$(pixel_resolve_serial)"
  if [[ -z "$run_dir" ]]; then
    run_dir="$(pixel_prepare_named_run_dir "$(pixel_drm_guest_runs_dir)")"
  else
    mkdir -p "$run_dir"
  fi
  panel_size="$(pixel_display_size "$serial")"
  panel_width="${panel_size%x*}"
  panel_height="${panel_size#*x}"
  sound_guest_env=$(
    cat <<EOF
SHADOW_BLITZ_SURFACE_WIDTH=$panel_width
SHADOW_BLITZ_SURFACE_HEIGHT=$panel_height
SHADOW_BLITZ_RUNTIME_AUTO_CLICK_TARGET=play
SHADOW_RUNTIME_AUDIO_BACKEND=${PIXEL_RUNTIME_AUDIO_LEGACY_CONFLICT_BACKEND:-memory}
SHADOW_RUNTIME_AUDIO_SPIKE_GAIN=${PIXEL_RUNTIME_AUDIO_SPIKE_GAIN:-0.03}
SHADOW_AUDIO_SPIKE_SUMMARY_PATH=$audio_summary_device_path
EOF
  )
fi

if [[ -n "${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}" ]]; then
  sound_guest_env="${sound_guest_env}"$'\n'"${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV}"
fi

required_markers=$(
  cat <<EOF
runtime-event-dispatched source=auto type=click target=play
[shadow-runtime-audio-smoke] command=play state=playing backend=linux_spike source_kind=file source=$source_path_in_bundle
EOF
)
if [[ -n "${PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS-}" ]]; then
  required_markers="${required_markers}"$'\n'"${PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS}"
fi

forbidden_markers=$(
  cat <<'EOF'
[shadow-runtime-audio-smoke] command=play error=
[shadow-runtime-audio-smoke] command=play state=playing backend=memory
EOF
)
if [[ -n "${PIXEL_RUNTIME_APP_EXTRA_FORBIDDEN_MARKERS-}" ]]; then
  forbidden_markers="${forbidden_markers}"$'\n'"${PIXEL_RUNTIME_APP_EXTRA_FORBIDDEN_MARKERS}"
fi

run_status=0
set +e
PIXEL_TAKEOVER_STOP_ALLOCATOR="${PIXEL_TAKEOVER_STOP_ALLOCATOR:-0}" \
  PIXEL_RUNTIME_ENABLE_LINUX_AUDIO=1 \
  PIXEL_RUNTIME_APP_INPUT_PATH="runtime/app-sound-smoke/app.tsx" \
  PIXEL_RUNTIME_APP_CACHE_DIR="build/runtime/pixel-app-sound-smoke" \
  PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV="$sound_guest_env" \
  PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS="$required_markers" \
  PIXEL_RUNTIME_APP_EXTRA_FORBIDDEN_MARKERS="$forbidden_markers" \
  SHADOW_RUNTIME_APP_CONFIG_JSON="$runtime_app_config_json" \
  PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS="${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS:-30000}" \
  PIXEL_GUEST_REQUIRED_MARKER_TIMEOUT_SECS="${PIXEL_GUEST_REQUIRED_MARKER_TIMEOUT_SECS:-45}" \
  PIXEL_GUEST_SESSION_EXIT_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_EXIT_TIMEOUT_SECS:-8}" \
  PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-90}" \
  PIXEL_GUEST_RUN_DIR="${run_dir:-}" \
  "$SCRIPT_DIR/pixel/pixel_runtime_app_drm.sh"
run_status=$?
set -e

if (( stage_only == 0 )); then
  audio_summary_host_path="$run_dir/audio-spike-summary.json"
  audio_proof_path="$run_dir/audio-proof.json"
  audio_summary_tmp_path="$run_dir/.audio-spike-summary.json.tmp"
  audio_summary_device_quoted="'${audio_summary_device_path//\'/\'\\\'\'}'"
  pull_status=0
  if pixel_adb "$serial" pull "$audio_summary_device_path" "$audio_summary_host_path" >/dev/null 2>&1; then
    pull_status=0
  elif pixel_root_shell "$serial" "cat $audio_summary_device_quoted" >"$audio_summary_tmp_path"; then
    mv "$audio_summary_tmp_path" "$audio_summary_host_path"
    pull_status=0
  else
    pull_status=$?
    rm -f "$audio_summary_tmp_path"
  fi

  python3 - "$audio_proof_path" "$audio_summary_host_path" "$audio_summary_device_path" "$run_status" "$pull_status" "$source_path_in_bundle" <<'PY'
import json
import sys
from pathlib import Path

proof_path = Path(sys.argv[1])
summary_path = Path(sys.argv[2])
device_path = sys.argv[3]
run_status = int(sys.argv[4])
pull_status = int(sys.argv[5])
expected_source = sys.argv[6]

summary = None
summary_error = ""
if summary_path.exists():
    try:
        summary = json.loads(summary_path.read_text(encoding="utf-8"))
    except Exception as error:  # noqa: BLE001 - proof artifact should preserve parse failures.
        summary_error = str(error)

playback = summary.get("playback") if isinstance(summary, dict) else None
attempts = summary.get("attempts") if isinstance(summary, dict) else []
successful_attempts = [
    attempt
    for attempt in attempts
    if isinstance(attempt, dict) and attempt.get("success") is True
]
source_kind = summary.get("source_kind") if isinstance(summary, dict) else None
source_path = summary.get("source_path") if isinstance(summary, dict) else None
summary_success = bool(summary.get("success")) if isinstance(summary, dict) else False
playback_device = playback.get("device") if isinstance(playback, dict) else None
source_matches = (
    isinstance(source_path, str)
    and (source_path == expected_source or source_path.endswith("/" + expected_source))
)

proof_ok = (
    run_status == 0
    and pull_status == 0
    and summary_success
    and source_kind == "file"
    and source_matches
    and isinstance(playback, dict)
    and bool(successful_attempts)
)

proof = {
    "audioSummaryDevicePath": device_path,
    "audioSummaryHostPath": str(summary_path),
    "audioSummaryPresent": summary_path.exists(),
    "audioSummaryParseError": summary_error,
    "expectedSourcePath": expected_source,
    "playbackDevice": playback_device,
    "proofOk": proof_ok,
    "pullStatus": pull_status,
    "runStatus": run_status,
    "sourceKind": source_kind,
    "sourceMatchesExpected": source_matches,
    "sourcePath": source_path,
    "successfulAttemptCount": len(successful_attempts),
    "summarySuccess": summary_success,
}
if isinstance(playback, dict):
    proof["playback"] = playback
if successful_attempts:
    proof["selectedAttempt"] = successful_attempts[0]
elif isinstance(attempts, list) and attempts:
    proof["lastAttempt"] = attempts[-1]

proof_path.write_text(json.dumps(proof, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"pixel-runtime-sound-audio-proof={proof_path}")
print(f"pixel-runtime-sound-audio-proof-ok={str(proof_ok).lower()}")
PY

  if [[ ! -f "$audio_proof_path" ]] || ! python3 - "$audio_proof_path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    raise SystemExit(0 if json.load(handle).get("proofOk") is True else 1)
PY
  then
    echo "pixel_runtime_app_sound_drm: Linux audio proof failed: $audio_proof_path" >&2
    exit 1
  fi
fi

exit "$run_status"
