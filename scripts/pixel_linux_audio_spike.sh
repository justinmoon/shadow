#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
# shellcheck source=./pixel_runtime_linux_bundle_common.sh
source "$SCRIPT_DIR/pixel_runtime_linux_bundle_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
run_dir="$(pixel_prepare_named_run_dir "$(pixel_audio_runs_dir)")"
logcat_path="$run_dir/logcat.txt"
session_output_path="$run_dir/session-output.txt"
summary_host_path="$run_dir/audio-summary.json"
status_json_path="$run_dir/status.json"
runtime_dir="$(pixel_audio_linux_dir)"
summary_device_path="$runtime_dir/audio-summary.json"
binary_name="shadow-linux-audio-spike"
bundle_dir="$(pixel_artifact_path shadow-linux-audio-spike-gnu)"
bundle_out_link="$(pixel_dir)/shadow-linux-audio-spike-aarch64-linux-gnu-result"
launcher_artifact="$bundle_dir/run-$binary_name"
launcher_device_path="$runtime_dir/run-$binary_name"
bundle_archive_host=""
bundle_archive_device=""
logcat_pid=""
services_restored=false
run_status=1
device_marker="audio-spike-playback-ok"

cleanup() {
  if [[ -n "$logcat_pid" ]]; then
    kill "$logcat_pid" >/dev/null 2>&1 || true
    wait "$logcat_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$bundle_archive_host" && -f "$bundle_archive_host" ]]; then
    rm -f "$bundle_archive_host"
  fi
}

trap cleanup EXIT

copy_closure_dir_into_bundle() {
  local relative_path destination required source_path closure_path found_any
  relative_path="$1"
  destination="$2"
  required="${3:-required}"
  found_any=0

  for closure_path in "${PIXEL_RUNTIME_CLOSURE_PATHS[@]}"; do
    source_path="$closure_path/$relative_path"
    if [[ ! -d "$source_path" ]]; then
      continue
    fi

    found_any=1
    mkdir -p "$destination"
    chmod -R u+w "$destination" 2>/dev/null || true
    rsync -rL --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r "$source_path"/. "$destination"/

    python3 - "$destination" "$relative_path" "${PIXEL_RUNTIME_CLOSURE_PATHS[@]}" <<'PY'
import os
import sys

destination = sys.argv[1]
relative_path = sys.argv[2]
closure_paths = sys.argv[3:]
target_root = "/" + relative_path
rewrite_prefixes = [os.path.join(path, relative_path) for path in closure_paths]
for root, _, files in os.walk(destination):
    for name in files:
        path = os.path.join(root, name)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                data = handle.read()
        except UnicodeDecodeError:
            continue
        rewritten = data
        for rewrite_prefix in rewrite_prefixes:
            rewritten = rewritten.replace(rewrite_prefix, target_root)
        if rewritten != data:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(rewritten)
PY
  done

  if [[ "$found_any" -ne 1 ]]; then
    if [[ "$required" == "optional" ]]; then
      return 0
    fi
    echo "pixel_linux_audio_spike: missing closure dir: $relative_path" >&2
    return 1
  fi
}

prepare_bundle() {
  local package_ref
  package_ref="$(repo_root)#shadow-linux-audio-spike-aarch64-linux-gnu"

  stage_runtime_host_linux_bundle "$package_ref" "$bundle_out_link" "$bundle_dir" "$binary_name"
  fill_linux_bundle_runtime_deps "$bundle_dir"
  copy_closure_dir_into_bundle "share/alsa" "$bundle_dir/share/alsa"
  mkdir -p "$bundle_dir/lib/alsa-lib"
  copy_closure_dir_into_bundle "lib/alsa-lib" "$bundle_dir/lib/alsa-lib" optional

  cat >"$launcher_artifact" <<EOF
#!/system/bin/sh
DIR=\$(cd "\$(dirname "\$0")" && pwd)
export ALSA_CONFIG_PATH="\$DIR/share/alsa/alsa.conf"
export ALSA_CONFIG_DIR="\$DIR/share/alsa"
export ALSA_CONFIG_UCM="\$DIR/share/alsa/ucm"
export ALSA_CONFIG_UCM2="\$DIR/share/alsa/ucm2"
export ALSA_PLUGIN_DIR="\$DIR/lib/alsa-lib"
exec "\$DIR/lib/$PIXEL_RUNTIME_STAGE_LOADER_NAME" --library-path "\$DIR/lib" "\$DIR/$binary_name" "\$@"
EOF
  chmod 0755 "$launcher_artifact"
}

push_bundle() {
  bundle_archive_host="$(mktemp "${TMPDIR:-/tmp}/shadow-audio-spike.XXXXXX.tar")"
  bundle_archive_device="/data/local/tmp/$(basename "$bundle_archive_host")"
  tar -C "$bundle_dir" -cf "$bundle_archive_host" .
  pixel_root_shell "$serial" "rm -rf '$runtime_dir' '$bundle_archive_device'"
  pixel_adb "$serial" push "$bundle_archive_host" "$bundle_archive_device" >/dev/null
  pixel_root_shell "$serial" "mkdir -p '$runtime_dir' && /system/bin/tar -xf '$bundle_archive_device' -C '$runtime_dir' && chown -R shell:shell '$runtime_dir' && find '$runtime_dir' -type d -exec chmod 0755 {} + && find '$runtime_dir' -type f -exec chmod 0755 {} + && rm -f '$bundle_archive_device'"
}

prepare_bundle
push_bundle

pixel_capture_props "$serial" "$run_dir/device-props.txt"
pixel_capture_processes "$serial" "$run_dir/processes-before.txt"
pixel_adb "$serial" logcat -c || true
pixel_adb "$serial" logcat -v threadtime >"$logcat_path" 2>&1 &
logcat_pid="$!"

: "${SHADOW_AUDIO_SPIKE_DURATION_MS:=1500}"
: "${SHADOW_AUDIO_SPIKE_FREQUENCY_HZ:=440}"
: "${SHADOW_AUDIO_SPIKE_RATE:=48000}"
: "${SHADOW_AUDIO_SPIKE_CHANNELS:=2}"
: "${PIXEL_AUDIO_SPIKE_TIMEOUT_SECS:=12}"

phone_script="$(
  cat <<EOF
$(pixel_takeover_stop_services_script)
rm -f '$summary_device_path'
timeout '$PIXEL_AUDIO_SPIKE_TIMEOUT_SECS' env \
  SHADOW_AUDIO_SPIKE_DURATION_MS='$SHADOW_AUDIO_SPIKE_DURATION_MS' \
  SHADOW_AUDIO_SPIKE_FREQUENCY_HZ='$SHADOW_AUDIO_SPIKE_FREQUENCY_HZ' \
  SHADOW_AUDIO_SPIKE_RATE='$SHADOW_AUDIO_SPIKE_RATE' \
  SHADOW_AUDIO_SPIKE_CHANNELS='$SHADOW_AUDIO_SPIKE_CHANNELS' \
  SHADOW_AUDIO_SPIKE_SUMMARY_PATH='$summary_device_path' \
  '$launcher_device_path'
status=\$?
$(pixel_takeover_start_services_script)
exit \$status
EOF
)"

set +e
pixel_root_shell "$serial" "$phone_script" >"$session_output_path" 2>&1
run_status="$?"
set -e

services_restored=true
pixel_root_shell "$serial" "cat '$summary_device_path' 2>/dev/null || true" >"$summary_host_path" || true

sleep 2
cleanup
logcat_pid=""
pixel_capture_processes "$serial" "$run_dir/processes-after.txt"

summary_present=false
marker_seen=false
if [[ -s "$summary_host_path" ]]; then
  summary_present=true
fi
if grep -Fq "$device_marker" "$session_output_path"; then
  marker_seen=true
fi

success=false
if [[ "$run_status" -eq 0 && "$marker_seen" == true ]]; then
  success=true
fi

pixel_write_status_json "$status_json_path" \
  run_dir="$run_dir" \
  marker_seen="$marker_seen" \
  summary_present="$summary_present" \
  android_restored="$services_restored" \
  success="$success" \
  exit_status="$run_status"

cat "$status_json_path"

if [[ "$run_status" -ne 0 ]]; then
  echo "pixel_linux_audio_spike: device command failed" >&2
  exit "$run_status"
fi

if [[ "$marker_seen" != true ]]; then
  echo "pixel_linux_audio_spike: expected marker not found in session output" >&2
  exit 1
fi
