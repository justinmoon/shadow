#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./pixel_runtime_linux_bundle_common.sh
source "$SCRIPT_DIR/lib/pixel_runtime_linux_bundle_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs
repo="$(repo_root)"
linux_system="${PIXEL_GUEST_BUILD_SYSTEM:-aarch64-linux}"
host_bundle_dir="$(pixel_shell_runtime_host_bundle_artifact_dir)"
host_bundle_out_link="$(pixel_dir)/shadow-runtime-shell-host-aarch64-linux-gnu-result"
host_binary_name="shadow-runtime-host"
host_launcher_artifact="$host_bundle_dir/run-shadow-runtime-host"
host_bundle_manifest_path="$host_bundle_dir/.bundle-manifest.json"
runtime_manifest_path="$host_bundle_dir/.runtime-bundle-manifest.json"
package_ref="$repo#packages.${linux_system}.shadow-runtime-host"
extra_bundle_dir="${PIXEL_RUNTIME_EXTRA_BUNDLE_ARTIFACT_DIR-}"
audio_enabled="${PIXEL_SHELL_ENABLE_LINUX_AUDIO:-1}"
audio_package_ref="$repo#packages.${linux_system}.shadow-linux-audio-spike-aarch64-linux-gnu"
audio_out_link="$(pixel_dir)/shadow-linux-audio-spike-aarch64-linux-gnu-result"
audio_binary_name="shadow-linux-audio-spike"
audio_launcher_artifact="$host_bundle_dir/run-$audio_binary_name"
xkb_source_dir="$(runtime_bundle_xkb_source_dir)"
android_font_source_dir="$(runtime_bundle_android_font_source_dir)"
declare -a shell_runtime_source_inputs=()
supported_shell_app_ids=(counter camera timeline podcast cashu)
selected_shell_app_ids=()

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

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

shell_app_is_supported() {
  local app_id="$1"
  local supported_app_id

  for supported_app_id in "${supported_shell_app_ids[@]}"; do
    if [[ "$supported_app_id" == "$app_id" ]]; then
      return 0
    fi
  done
  return 1
}

shell_app_selected() {
  local app_id="$1"
  local selected_app_id

  for selected_app_id in "${selected_shell_app_ids[@]}"; do
    if [[ "$selected_app_id" == "$app_id" ]]; then
      return 0
    fi
  done
  return 1
}

append_selected_shell_app() {
  local app_id="$1"
  local selected_app_id

  for selected_app_id in "${selected_shell_app_ids[@]}"; do
    if [[ "$selected_app_id" == "$app_id" ]]; then
      return 0
    fi
  done
  selected_shell_app_ids+=("$app_id")
}

selected_shell_app_ids_csv="${PIXEL_SHELL_APP_IDS:-}"
if [[ -n "$selected_shell_app_ids_csv" ]]; then
  IFS=',' read -r -a requested_shell_app_ids <<<"$selected_shell_app_ids_csv"
  for requested_app_id in "${requested_shell_app_ids[@]}"; do
    requested_app_id="$(trim_whitespace "$requested_app_id")"
    if [[ -z "$requested_app_id" ]]; then
      continue
    fi
    if ! shell_app_is_supported "$requested_app_id"; then
      echo "pixel_prepare_shell_runtime_artifacts: unsupported PIXEL_SHELL_APP_IDS entry: $requested_app_id" >&2
      exit 1
    fi
    append_selected_shell_app "$requested_app_id"
  done
fi
if ((${#selected_shell_app_ids[@]} == 0)); then
  selected_shell_app_ids=("${supported_shell_app_ids[@]}")
fi
selected_shell_app_ids_csv="$(IFS=,; printf '%s' "${selected_shell_app_ids[*]}")"

manifest_app_field() {
  local app_id="$1"
  local field="$2"

  APP_MANIFEST_JSON="$app_manifest_json" APP_ID="$app_id" APP_FIELD="$field" python3 - <<'PY'
import json
import os

data = json.loads(os.environ["APP_MANIFEST_JSON"])
value = data["apps"].get(os.environ["APP_ID"], {}).get(os.environ["APP_FIELD"])
if isinstance(value, (dict, list)):
    print(json.dumps(value))
elif value is not None:
    print(value)
PY
}

copy_selected_bundle_artifact() {
  local app_id="$1"
  local source_path="$2"
  local artifact_path="$3"

  if ! shell_app_selected "$app_id"; then
    rm -f "$artifact_path"
    return 0
  fi
  if [[ -z "$source_path" || ! -f "$source_path" ]]; then
    echo "pixel_prepare_shell_runtime_artifacts: missing bundle source for selected app: $app_id" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$artifact_path")"
  cp "$source_path" "$artifact_path"
  chmod 0644 "$artifact_path"
}

copy_selected_host_bundle() {
  local app_id="$1"
  local artifact_path="$2"
  local device_bundle_path="$3"

  if ! shell_app_selected "$app_id"; then
    return 0
  fi
  cp "$artifact_path" "$host_bundle_dir/$(basename "$device_bundle_path")"
}

if [[ -n "$extra_bundle_dir" ]]; then
  extra_bundle_dir="$(normalize_runtime_bundle_input_path "$extra_bundle_dir")"
  if [[ ! -d "$extra_bundle_dir" ]]; then
    echo "pixel_prepare_shell_runtime_artifacts: extra bundle dir not found: $extra_bundle_dir" >&2
    exit 1
  fi
fi

app_manifest_json="$(
  runtime_build_args=(--profile pixel-shell --artifact-root "$app_artifact_root")
  if shell_app_selected podcast; then
    runtime_build_args+=(--include-podcast)
  fi
  for selected_app_id in "${selected_shell_app_ids[@]}"; do
    runtime_build_args+=(--include-app "$selected_app_id")
  done
  SHADOW_RUNTIME_APP_TIMELINE_CONFIG_JSON="$timeline_config_json" \
  SHADOW_PODCAST_PLAYER_EPISODE_IDS="$podcast_episode_ids" \
    "$SCRIPT_DIR/runtime_build_artifacts.sh" \
      "${runtime_build_args[@]}"
)"

counter_bundle_source_path="$(manifest_app_field counter effectiveBundlePath)"
camera_bundle_source_path="$(manifest_app_field camera effectiveBundlePath)"
timeline_bundle_source_path="$(manifest_app_field timeline effectiveBundlePath)"
podcast_bundle_source_path="$(manifest_app_field podcast effectiveBundlePath)"
cashu_bundle_source_path="$(manifest_app_field cashu effectiveBundlePath)"
podcast_asset_dir="$(manifest_app_field podcast extraAssetDir)"
podcast_config_json="$(manifest_app_field podcast runtimeAppConfig)"

copy_selected_bundle_artifact counter "$counter_bundle_source_path" "$counter_bundle_artifact"
copy_selected_bundle_artifact camera "$camera_bundle_source_path" "$camera_bundle_artifact"
copy_selected_bundle_artifact timeline "$timeline_bundle_source_path" "$timeline_bundle_artifact"
copy_selected_bundle_artifact podcast "$podcast_bundle_source_path" "$podcast_bundle_artifact"
copy_selected_bundle_artifact cashu "$cashu_bundle_source_path" "$cashu_bundle_artifact"

host_bundle_source_fingerprint="$(
  runtime_bundle_source_fingerprint \
    "pixel-shell-runtime $package_ref" \
    "$repo/flake.nix" \
    "$repo/flake.lock" \
    "${shell_runtime_source_inputs[@]}" \
    "$repo/rust/vendor/temporal_rs" \
    "$SCRIPT_DIR/pixel/pixel_prepare_shell_runtime_artifacts.sh" \
    "$SCRIPT_DIR/lib/pixel_runtime_linux_bundle_common.sh" \
    "$SCRIPT_DIR/runtime_build_artifacts.sh" \
    "$SCRIPT_DIR/runtime/runtime_build_artifacts.ts" \
    "$SCRIPT_DIR/runtime/runtime_prepare_app_bundle.ts" \
    "$SCRIPT_DIR/runtime/runtime_compile_solid.ts" \
    "$SCRIPT_DIR/runtime/prepare_podcast_player_demo_assets.sh" \
    "$xkb_source_dir" \
    "$android_font_source_dir" \
    "__pixel_shell_app_ids__${selected_shell_app_ids_csv}" \
    "${counter_bundle_source_path:-__counter_unselected__}" \
    "${camera_bundle_source_path:-__camera_unselected__}" \
    "${timeline_bundle_source_path:-__timeline_unselected__}" \
    "${podcast_bundle_source_path:-__podcast_unselected__}" \
    "${cashu_bundle_source_path:-__cashu_unselected__}" \
    "${podcast_asset_dir:-__podcast_assets_unselected__}" \
    "__pixel_shell_enable_linux_audio__${audio_enabled}" \
    "__pixel_shell_audio_package_ref__${audio_package_ref}" \
    "__pixel_shell_podcast_config__${podcast_config_json:-__podcast_unselected__}" \
    "${extra_bundle_dir:-__no_extra_bundle__}"
)"

host_bundle_cache_hit=0
if [[ "${PIXEL_FORCE_LINUX_BUNDLE_REBUILD-}" != 1 ]] \
  && [[ -d "$host_bundle_dir" ]] \
  && [[ -x "$host_launcher_artifact" ]] \
  && [[ -f "$host_bundle_dir/$host_binary_name" ]] \
  && { ! shell_app_selected counter || [[ -f "$host_bundle_dir/$(basename "$(pixel_runtime_counter_bundle_dst)")" ]]; } \
  && { ! shell_app_selected camera || [[ -f "$host_bundle_dir/$(basename "$(pixel_runtime_camera_bundle_dst)")" ]]; } \
  && { ! shell_app_selected timeline || [[ -f "$host_bundle_dir/$(basename "$(pixel_runtime_timeline_bundle_dst)")" ]]; } \
  && { ! shell_app_selected podcast || [[ -f "$host_bundle_dir/$(basename "$(pixel_runtime_podcast_bundle_dst)")" ]]; } \
  && { ! shell_app_selected cashu || [[ -f "$host_bundle_dir/$(basename "$(pixel_runtime_cashu_bundle_dst)")" ]]; } \
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
    pixel_retry_nix_build nix build --accept-flake-config "$audio_package_ref" --out-link "$audio_out_link"
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

rm -f \
  "$host_bundle_dir/$(basename "$(pixel_runtime_counter_bundle_dst)")" \
  "$host_bundle_dir/$(basename "$(pixel_runtime_camera_bundle_dst)")" \
  "$host_bundle_dir/$(basename "$(pixel_runtime_timeline_bundle_dst)")" \
  "$host_bundle_dir/$(basename "$(pixel_runtime_podcast_bundle_dst)")" \
  "$host_bundle_dir/$(basename "$(pixel_runtime_cashu_bundle_dst)")"
copy_selected_host_bundle counter "$counter_bundle_artifact" "$(pixel_runtime_counter_bundle_dst)"
copy_selected_host_bundle camera "$camera_bundle_artifact" "$(pixel_runtime_camera_bundle_dst)"
copy_selected_host_bundle timeline "$timeline_bundle_artifact" "$(pixel_runtime_timeline_bundle_dst)"
copy_selected_host_bundle podcast "$podcast_bundle_artifact" "$(pixel_runtime_podcast_bundle_dst)"
copy_selected_host_bundle cashu "$cashu_bundle_artifact" "$(pixel_runtime_cashu_bundle_dst)"
if shell_app_selected podcast && [[ -n "$podcast_asset_dir" ]]; then
  chmod -R u+w "$host_bundle_dir/assets" 2>/dev/null || true
  rm -rf "$host_bundle_dir/assets"
  cp -R "$podcast_asset_dir"/. "$host_bundle_dir"/
else
  chmod -R u+w "$host_bundle_dir/assets" 2>/dev/null || true
  rm -rf "$host_bundle_dir/assets"
fi
if shell_app_selected counter; then chmod 0644 "$host_bundle_dir/$(basename "$(pixel_runtime_counter_bundle_dst)")"; fi
if shell_app_selected camera; then chmod 0644 "$host_bundle_dir/$(basename "$(pixel_runtime_camera_bundle_dst)")"; fi
if shell_app_selected timeline; then chmod 0644 "$host_bundle_dir/$(basename "$(pixel_runtime_timeline_bundle_dst)")"; fi
if shell_app_selected podcast; then chmod 0644 "$host_bundle_dir/$(basename "$(pixel_runtime_podcast_bundle_dst)")"; fi
if shell_app_selected cashu; then chmod 0644 "$host_bundle_dir/$(basename "$(pixel_runtime_cashu_bundle_dst)")"; fi

runtime_helper_content_fingerprint="$(
  runtime_bundle_directory_fingerprint "$host_bundle_dir"
)"
python3 - "$runtime_manifest_path" "$runtime_helper_content_fingerprint" "$audio_enabled" "$podcast_config_json" "$timeline_config_json" "$counter_input_path" "$camera_input_path" "$timeline_input_path" "$podcast_input_path" "$podcast_asset_dir" "$cashu_input_path" "$extra_bundle_dir" "$selected_shell_app_ids_csv" <<'PY'
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
    selected_app_ids_csv,
) = sys.argv[1:14]
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
    "selectedAppIds": [app_id for app_id in selected_app_ids_csv.split(",") if app_id],
    "timelineConfigJson": timeline_config_json,
    "timelineInputPath": timeline_input_path,
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY

python3 - "$host_bundle_dir" "$counter_bundle_artifact" "$camera_bundle_artifact" "$timeline_bundle_artifact" "$podcast_bundle_artifact" "$cashu_bundle_artifact" "$host_bundle_cache_hit" "$selected_shell_app_ids_csv" <<'PY'
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
    selected_app_ids_csv,
) = sys.argv[1:9]
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
    "selectedAppIds": [app_id for app_id in selected_app_ids_csv.split(",") if app_id],
    "timelineBundleArtifact": os.path.abspath(timeline_bundle_artifact),
    "timelineBundleDevicePath": "/data/local/tmp/shadow-runtime-gnu/runtime-app-timeline-bundle.js",
}, indent=2))
PY
