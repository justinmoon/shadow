#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
# shellcheck source=./pixel_runtime_linux_bundle_common.sh
source "$SCRIPT_DIR/pixel_runtime_linux_bundle_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs
repo="$(repo_root)"
host_bundle_dir="$(pixel_shell_runtime_host_bundle_artifact_dir)"
host_bundle_out_link="$(pixel_dir)/shadow-runtime-shell-host-aarch64-linux-gnu-result"
host_binary_name="shadow-runtime-host"
host_launcher_artifact="$host_bundle_dir/run-shadow-runtime-host"
host_bundle_manifest_path="$host_bundle_dir/.bundle-manifest.json"
runtime_manifest_path="$host_bundle_dir/.runtime-bundle-manifest.json"
package_ref="$repo#shadow-runtime-host-aarch64-linux-gnu"
extra_bundle_dir="${PIXEL_RUNTIME_EXTRA_BUNDLE_ARTIFACT_DIR-}"
audio_enabled="${PIXEL_SHELL_ENABLE_LINUX_AUDIO:-1}"
audio_package_ref="$repo#shadow-linux-audio-spike-aarch64-linux-gnu"
audio_out_link="$(pixel_dir)/shadow-linux-audio-spike-aarch64-linux-gnu-result"
audio_binary_name="shadow-linux-audio-spike"
audio_launcher_artifact="$host_bundle_dir/run-$audio_binary_name"
xkb_source_dir="$(runtime_bundle_xkb_source_dir)"
android_font_source_dir="$(runtime_bundle_android_font_source_dir)"
declare -a shell_runtime_source_inputs=()

mapfile -t shell_runtime_source_inputs < <(
  runtime_bundle_cargo_package_source_inputs "$repo/rust/runtime-camera-host"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/shadow-runtime-host"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/runtime-audio-host"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/runtime-cashu-host"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/runtime-nostr-host"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/shadow-linux-audio-spike"
)

counter_input_path="${PIXEL_SHELL_COUNTER_INPUT_PATH:-runtime/app-counter/app.tsx}"
counter_cache_dir="${PIXEL_SHELL_COUNTER_CACHE_DIR:-build/runtime/pixel-shell-counter}"
counter_bundle_artifact="$(pixel_runtime_counter_bundle_artifact)"

camera_input_path="${PIXEL_SHELL_CAMERA_INPUT_PATH:-runtime/app-camera/app.tsx}"
camera_cache_dir="${PIXEL_SHELL_CAMERA_CACHE_DIR:-build/runtime/pixel-shell-camera}"
camera_bundle_artifact="$(pixel_runtime_camera_bundle_artifact)"

timeline_input_path="${PIXEL_SHELL_TIMELINE_INPUT_PATH:-runtime/app-nostr-timeline/app.tsx}"
timeline_cache_dir="${PIXEL_SHELL_TIMELINE_CACHE_DIR:-build/runtime/pixel-shell-timeline}"
timeline_bundle_artifact="$(pixel_runtime_timeline_bundle_artifact)"

podcast_input_path="${PIXEL_SHELL_PODCAST_INPUT_PATH:-runtime/app-podcast-player/app.tsx}"
podcast_cache_dir="${PIXEL_SHELL_PODCAST_CACHE_DIR:-build/runtime/pixel-shell-podcast}"
podcast_bundle_artifact="$(pixel_runtime_podcast_bundle_artifact)"
podcast_episode_ids="${SHADOW_PODCAST_PLAYER_EPISODE_IDS:-00}"
app_artifact_root="${PIXEL_SHELL_APP_ARTIFACT_ROOT:-build/runtime/pixel-shell-app-artifacts}"
podcast_asset_dir=""
podcast_config_json=""

cashu_input_path="${PIXEL_SHELL_CASHU_INPUT_PATH:-runtime/app-cashu-wallet/app.tsx}"
cashu_cache_dir="${PIXEL_SHELL_CASHU_CACHE_DIR:-build/runtime/pixel-shell-cashu}"
cashu_bundle_artifact="$(pixel_runtime_cashu_bundle_artifact)"

timeline_config_json="${SHADOW_RUNTIME_APP_TIMELINE_CONFIG_JSON-}"
if [[ -z "$timeline_config_json" ]]; then
  timeline_config_json='{"limit":12,"syncOnStart":true}'
fi

manifest_app_field() {
  local app_id="$1"
  local field="$2"

  APP_MANIFEST_JSON="$app_manifest_json" APP_ID="$app_id" APP_FIELD="$field" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["APP_MANIFEST_JSON"])
value = data["apps"][os.environ["APP_ID"]].get(os.environ["APP_FIELD"])
if isinstance(value, (dict, list)):
    print(json.dumps(value))
elif value is not None:
    print(value)
PY
}

if [[ -n "$extra_bundle_dir" ]]; then
  extra_bundle_dir="$(normalize_runtime_bundle_input_path "$extra_bundle_dir")"
  if [[ ! -d "$extra_bundle_dir" ]]; then
    echo "pixel_prepare_shell_runtime_artifacts: extra bundle dir not found: $extra_bundle_dir" >&2
    exit 1
  fi
fi

app_manifest_json="$(
  SHADOW_RUNTIME_APP_TIMELINE_CONFIG_JSON="$timeline_config_json" \
  SHADOW_PODCAST_PLAYER_EPISODE_IDS="$podcast_episode_ids" \
    "$SCRIPT_DIR/runtime_build_artifacts.sh" \
      --profile pixel-shell \
      --include-podcast \
      --artifact-root "$app_artifact_root"
)"

counter_bundle_source_path="$(manifest_app_field counter effectiveBundlePath)"
camera_bundle_source_path="$(manifest_app_field camera effectiveBundlePath)"
timeline_bundle_source_path="$(manifest_app_field timeline effectiveBundlePath)"
podcast_bundle_source_path="$(manifest_app_field podcast effectiveBundlePath)"
cashu_bundle_source_path="$(manifest_app_field cashu effectiveBundlePath)"
podcast_asset_dir="$(manifest_app_field podcast extraAssetDir)"
podcast_config_json="$(manifest_app_field podcast runtimeAppConfig)"

mkdir -p "$(dirname "$counter_bundle_artifact")"
cp "$counter_bundle_source_path" "$counter_bundle_artifact"
cp "$camera_bundle_source_path" "$camera_bundle_artifact"
cp "$timeline_bundle_source_path" "$timeline_bundle_artifact"
cp "$podcast_bundle_source_path" "$podcast_bundle_artifact"
cp "$cashu_bundle_source_path" "$cashu_bundle_artifact"
chmod 0644 \
  "$counter_bundle_artifact" \
  "$camera_bundle_artifact" \
  "$timeline_bundle_artifact" \
  "$podcast_bundle_artifact" \
  "$cashu_bundle_artifact"

host_bundle_source_fingerprint="$(
  runtime_bundle_source_fingerprint \
    "pixel-shell-runtime $package_ref" \
    "$repo/flake.nix" \
    "$repo/flake.lock" \
    "${shell_runtime_source_inputs[@]}" \
    "$repo/rust/vendor/temporal_rs" \
    "$SCRIPT_DIR/pixel_prepare_shell_runtime_artifacts.sh" \
    "$SCRIPT_DIR/pixel_runtime_linux_bundle_common.sh" \
    "$SCRIPT_DIR/runtime_build_artifacts.sh" \
    "$SCRIPT_DIR/runtime_build_artifacts.ts" \
    "$SCRIPT_DIR/runtime_prepare_app_bundle.ts" \
    "$SCRIPT_DIR/runtime_compile_solid.ts" \
    "$SCRIPT_DIR/prepare_podcast_player_demo_assets.sh" \
    "$xkb_source_dir" \
    "$android_font_source_dir" \
    "$counter_bundle_source_path" \
    "$camera_bundle_source_path" \
    "$timeline_bundle_source_path" \
    "$podcast_bundle_source_path" \
    "$cashu_bundle_source_path" \
    "$podcast_asset_dir" \
    "__pixel_shell_enable_linux_audio__${audio_enabled}" \
    "__pixel_shell_audio_package_ref__${audio_package_ref}" \
    "__pixel_shell_podcast_config__${podcast_config_json}" \
    "${extra_bundle_dir:-__no_extra_bundle__}"
)"

host_bundle_cache_hit=0
if [[ "${PIXEL_FORCE_LINUX_BUNDLE_REBUILD-}" != 1 ]] \
  && [[ -d "$host_bundle_dir" ]] \
  && [[ -x "$host_launcher_artifact" ]] \
  && [[ -f "$host_bundle_dir/$host_binary_name" ]] \
  && [[ -f "$host_bundle_dir/$(basename "$(pixel_runtime_counter_bundle_dst)")" ]] \
  && [[ -f "$host_bundle_dir/$(basename "$(pixel_runtime_camera_bundle_dst)")" ]] \
  && [[ -f "$host_bundle_dir/$(basename "$(pixel_runtime_timeline_bundle_dst)")" ]] \
  && [[ -f "$host_bundle_dir/$(basename "$(pixel_runtime_podcast_bundle_dst)")" ]] \
  && [[ -f "$host_bundle_dir/$(basename "$(pixel_runtime_cashu_bundle_dst)")" ]] \
  && [[ -d "$host_bundle_dir/share/X11/xkb" ]] \
  && [[ ! -L "$host_bundle_dir/share/X11/xkb" ]] \
  && runtime_bundle_manifest_matches "$host_bundle_manifest_path" "$host_bundle_source_fingerprint"; then
  host_bundle_cache_hit=1
  if [[ "$audio_enabled" == "1" ]] \
    && { [[ ! -x "$audio_launcher_artifact" ]] || [[ ! -f "$host_bundle_dir/$audio_binary_name" ]]; }; then
    host_bundle_cache_hit=0
  fi
fi
if [[ "$host_bundle_cache_hit" == "1" ]]; then
  printf 'Shell runtime host bundle cacheHit -> %s\n' "$host_bundle_dir"
else
  stage_runtime_host_linux_bundle "$package_ref" "$host_bundle_out_link" "$host_bundle_dir" "$host_binary_name"
  if [[ "$audio_enabled" == "1" ]]; then
    nix build --accept-flake-config "$audio_package_ref" --out-link "$audio_out_link"
    cp "$audio_out_link/bin/$audio_binary_name" "$host_bundle_dir/$audio_binary_name"
    chmod 0755 "$host_bundle_dir/$audio_binary_name"
    append_runtime_closure_from_package_ref "$audio_package_ref"
  fi
  fill_linux_bundle_runtime_deps "$host_bundle_dir"
  stage_runtime_bundle_xkb_config "$host_bundle_dir"
  stage_runtime_bundle_android_fonts "$host_bundle_dir"
  if [[ "$audio_enabled" == "1" ]]; then
    copy_closure_dir_into_bundle "share/alsa" "$host_bundle_dir/share/alsa"
    mkdir -p "$host_bundle_dir/lib/alsa-lib"
    copy_closure_dir_into_bundle "lib/alsa-lib" "$host_bundle_dir/lib/alsa-lib" optional
  fi

  if [[ -n "$extra_bundle_dir" ]]; then
    chmod -R u+w "$host_bundle_dir" 2>/dev/null || true
    cp -R "$extra_bundle_dir"/. "$host_bundle_dir"/
  fi

  if [[ "$audio_enabled" == "1" ]]; then
    cat >"$audio_launcher_artifact" <<EOF
#!/system/bin/sh
DIR=\$(cd "\$(dirname "\$0")" && pwd)
export ALSA_CONFIG_PATH="\$DIR/share/alsa/alsa.conf"
export ALSA_CONFIG_DIR="\$DIR/share/alsa"
export ALSA_CONFIG_UCM="\$DIR/share/alsa/ucm"
export ALSA_CONFIG_UCM2="\$DIR/share/alsa/ucm2"
export ALSA_PLUGIN_DIR="\$DIR/lib/alsa-lib"
exec "\$DIR/lib/$PIXEL_RUNTIME_STAGE_LOADER_NAME" --library-path "\$DIR/lib" "\$DIR/$audio_binary_name" "\$@"
EOF
    chmod 0755 "$audio_launcher_artifact"
  fi

  cat >"$host_launcher_artifact" <<EOF
#!/system/bin/sh
DIR=\$(cd "\$(dirname "\$0")" && pwd)
if [ "\$#" -ne 2 ] || [ "\$1" != "--session" ]; then
  echo "usage: $host_binary_name --session <bundle-path>" >&2
  exit 64
fi
EOF
  if [[ "$audio_enabled" == "1" ]]; then
    cat >>"$host_launcher_artifact" <<EOF
export SHADOW_RUNTIME_AUDIO_BACKEND="linux_spike"
export SHADOW_RUNTIME_AUDIO_SPIKE_BINARY="\$DIR/$audio_binary_name"
export SHADOW_RUNTIME_AUDIO_SPIKE_STAGE_LOADER_PATH="\$DIR/lib/$PIXEL_RUNTIME_STAGE_LOADER_NAME"
export SHADOW_RUNTIME_AUDIO_SPIKE_STAGE_LIBRARY_PATH="\$DIR/lib"
export ALSA_CONFIG_PATH="\$DIR/share/alsa/alsa.conf"
export ALSA_CONFIG_DIR="\$DIR/share/alsa"
export ALSA_CONFIG_UCM="\$DIR/share/alsa/ucm"
export ALSA_CONFIG_UCM2="\$DIR/share/alsa/ucm2"
export ALSA_PLUGIN_DIR="\$DIR/lib/alsa-lib"
export SHADOW_RUNTIME_BUNDLE_DIR="\$DIR"
exec "\$DIR/lib/$PIXEL_RUNTIME_STAGE_LOADER_NAME" --library-path "\$DIR/lib" "\$DIR/$host_binary_name" "\$@"
EOF
  else
    cat >>"$host_launcher_artifact" <<EOF
if command -v chroot >/dev/null 2>&1; then
  case "\$2" in
    "\$DIR"/*) set -- "\$1" "/\${2#\$DIR/}" ;;
  esac
  exec chroot "\$DIR" "/lib/$PIXEL_RUNTIME_STAGE_LOADER_NAME" --library-path /lib "/$host_binary_name" "\$@"
fi
exec "\$DIR/lib/$PIXEL_RUNTIME_STAGE_LOADER_NAME" --library-path "\$DIR/lib" "\$DIR/$host_binary_name" "\$@"
EOF
  fi
  chmod 0755 "$host_launcher_artifact"

  write_runtime_bundle_manifest \
    "$host_bundle_manifest_path" \
    "$host_bundle_source_fingerprint" \
    "$package_ref"
fi

cp "$counter_bundle_artifact" "$host_bundle_dir/$(basename "$(pixel_runtime_counter_bundle_dst)")"
cp "$camera_bundle_artifact" "$host_bundle_dir/$(basename "$(pixel_runtime_camera_bundle_dst)")"
cp "$timeline_bundle_artifact" "$host_bundle_dir/$(basename "$(pixel_runtime_timeline_bundle_dst)")"
cp "$podcast_bundle_artifact" "$host_bundle_dir/$(basename "$(pixel_runtime_podcast_bundle_dst)")"
cp "$cashu_bundle_artifact" "$host_bundle_dir/$(basename "$(pixel_runtime_cashu_bundle_dst)")"
if [[ -n "$podcast_asset_dir" ]]; then
  chmod -R u+w "$host_bundle_dir/assets" 2>/dev/null || true
  rm -rf "$host_bundle_dir/assets"
  cp -R "$podcast_asset_dir"/. "$host_bundle_dir"/
fi
chmod 0644 \
  "$host_bundle_dir/$(basename "$(pixel_runtime_counter_bundle_dst)")" \
  "$host_bundle_dir/$(basename "$(pixel_runtime_camera_bundle_dst)")" \
  "$host_bundle_dir/$(basename "$(pixel_runtime_timeline_bundle_dst)")" \
  "$host_bundle_dir/$(basename "$(pixel_runtime_podcast_bundle_dst)")" \
  "$host_bundle_dir/$(basename "$(pixel_runtime_cashu_bundle_dst)")"

runtime_helper_content_fingerprint="$(
  runtime_bundle_directory_fingerprint "$host_bundle_dir"
)"
python3 - "$runtime_manifest_path" "$runtime_helper_content_fingerprint" "$audio_enabled" "$podcast_config_json" "$timeline_config_json" "$counter_input_path" "$camera_input_path" "$timeline_input_path" "$podcast_input_path" "$podcast_asset_dir" "$cashu_input_path" "$extra_bundle_dir" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

(
    manifest_path,
    content_fingerprint,
    audio_enabled,
    podcast_config_json,
    timeline_config_json,
    counter_input_path,
    camera_input_path,
    timeline_input_path,
    podcast_input_path,
    podcast_asset_dir,
    cashu_input_path,
    extra_bundle_dir,
) = sys.argv[1:13]
manifest = {
    "cashuInputPath": cashu_input_path,
    "cameraInputPath": camera_input_path,
    "contentFingerprint": content_fingerprint,
    "counterInputPath": counter_input_path,
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "mode": "pixel-shell-runtime",
    "linuxAudioEnabled": audio_enabled == "1",
    "podcastAssetDir": os.path.abspath(podcast_asset_dir) if podcast_asset_dir else None,
    "podcastConfigJson": podcast_config_json,
    "podcastInputPath": podcast_input_path,
    "runtimeExtraBundleArtifactDir": os.path.abspath(extra_bundle_dir) if extra_bundle_dir else None,
    "timelineConfigJson": timeline_config_json,
    "timelineInputPath": timeline_input_path,
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY

python3 - "$host_bundle_dir" "$counter_bundle_artifact" "$camera_bundle_artifact" "$timeline_bundle_artifact" "$podcast_bundle_artifact" "$cashu_bundle_artifact" "$host_bundle_cache_hit" <<'PY'
import json
import os
import sys

(
    host_bundle_dir,
    counter_bundle_artifact,
    camera_bundle_artifact,
    timeline_bundle_artifact,
    podcast_bundle_artifact,
    cashu_bundle_artifact,
    host_bundle_cache_hit,
) = sys.argv[1:8]
print(json.dumps({
    "cashuBundleArtifact": os.path.abspath(cashu_bundle_artifact),
    "cashuBundleDevicePath": "/data/local/tmp/shadow-runtime-gnu/runtime-app-cashu-bundle.js",
    "cameraBundleArtifact": os.path.abspath(camera_bundle_artifact),
    "cameraBundleDevicePath": "/data/local/tmp/shadow-runtime-gnu/runtime-app-camera-bundle.js",
    "counterBundleArtifact": os.path.abspath(counter_bundle_artifact),
    "counterBundleDevicePath": "/data/local/tmp/shadow-runtime-gnu/runtime-app-counter-bundle.js",
    "mode": "pixel-shell-runtime",
    "podcastBundleArtifact": os.path.abspath(podcast_bundle_artifact),
    "podcastBundleDevicePath": "/data/local/tmp/shadow-runtime-gnu/runtime-app-podcast-bundle.js",
    "runtimeHostBundleArtifactDir": os.path.abspath(host_bundle_dir),
    "runtimeHostBundleCacheHit": host_bundle_cache_hit == "1",
    "runtimeHostLauncherDevicePath": "/data/local/tmp/shadow-runtime-gnu/run-shadow-runtime-host",
    "timelineBundleArtifact": os.path.abspath(timeline_bundle_artifact),
    "timelineBundleDevicePath": "/data/local/tmp/shadow-runtime-gnu/runtime-app-timeline-bundle.js",
}, indent=2))
PY
