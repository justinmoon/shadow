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
declare -a shell_app_bundle_artifacts=()
declare -a shell_app_bundle_destinations=()
declare -a shell_app_bundle_source_paths=()
declare -a shell_app_ids=()
declare -a shell_runtime_source_inputs=()
declare -a supported_shell_app_ids=()
selected_shell_app_ids=()

mapfile -t shell_runtime_source_inputs < <(
  printf '%s\n' "$repo/rust/Cargo.toml"
  printf '%s\n' "$repo/rust/Cargo.lock"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/runtime-camera-host"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/shadow-runtime-host"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/runtime-audio-host"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/runtime-cashu-host"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/runtime-nostr-host"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/shadow-runtime-protocol"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/shadow-linux-audio-spike"
)

podcast_episode_ids="${SHADOW_PODCAST_PLAYER_EPISODE_IDS:-00}"
app_artifact_root="${PIXEL_SHELL_APP_ARTIFACT_ROOT:-build/runtime/pixel-shell-app-artifacts}"
podcast_asset_dir=""
podcast_config_json=""

mapfile -t supported_shell_app_ids < <(pixel_runtime_shell_app_ids)
if ((${#supported_shell_app_ids[@]} == 0)); then
  echo "pixel_prepare_shell_runtime_artifacts: no shell apps found in runtime/apps.json" >&2
  exit 1
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
  SHADOW_PODCAST_PLAYER_EPISODE_IDS="$podcast_episode_ids" \
    "$SCRIPT_DIR/runtime_build_artifacts.sh" \
      "${runtime_build_args[@]}"
)"

shell_app_ids=("${selected_shell_app_ids[@]}")

mkdir -p "$(pixel_artifacts_dir)"
for app_id in "${shell_app_ids[@]}"; do
  bundle_source_path="$(manifest_app_field "$app_id" effectiveBundlePath)"
  bundle_artifact="$(pixel_runtime_app_bundle_artifact_for "$app_id")"
  bundle_destination="$(pixel_runtime_app_bundle_dst_for "$app_id")"

  cp "$bundle_source_path" "$bundle_artifact"
  chmod 0644 "$bundle_artifact"

  shell_app_bundle_source_paths+=("$bundle_source_path")
  shell_app_bundle_artifacts+=("$bundle_artifact")
  shell_app_bundle_destinations+=("$bundle_destination")
done
podcast_asset_dir="$(manifest_app_field podcast extraAssetDir)"
podcast_config_json="$(manifest_app_field podcast runtimeAppConfig)"

host_bundle_source_fingerprint="$(
  runtime_bundle_source_fingerprint \
    "pixel-shell-runtime $package_ref" \
    "$repo/flake.nix" \
    "$repo/flake.lock" \
    "$repo/runtime/apps.json" \
    "${shell_runtime_source_inputs[@]}" \
    "$repo/rust/vendor/temporal_rs" \
    "$SCRIPT_DIR/pixel/pixel_prepare_shell_runtime_artifacts.sh" \
    "$SCRIPT_DIR/lib/pixel_common.sh" \
    "$SCRIPT_DIR/lib/pixel_runtime_linux_bundle_common.sh" \
    "$SCRIPT_DIR/runtime_build_artifacts.sh" \
    "$SCRIPT_DIR/runtime/runtime_build_artifacts.ts" \
    "$SCRIPT_DIR/runtime/runtime_prepare_app_bundle.ts" \
    "$SCRIPT_DIR/runtime/runtime_compile_solid.ts" \
    "$SCRIPT_DIR/runtime/prepare_podcast_player_demo_assets.sh" \
    "$xkb_source_dir" \
    "$android_font_source_dir" \
    "__pixel_shell_app_ids__${selected_shell_app_ids_csv}" \
    "${shell_app_bundle_source_paths[@]}" \
    "${podcast_asset_dir:-__podcast_assets_unselected__}" \
    "__pixel_shell_enable_linux_audio__${audio_enabled}" \
    "__pixel_shell_audio_package_ref__${audio_package_ref}" \
    "__pixel_shell_podcast_config__${podcast_config_json:-__podcast_unselected__}" \
    "${extra_bundle_dir:-__no_extra_bundle__}"
)"

host_bundle_cache_hit=0
host_bundle_apps_present=1
for bundle_destination in "${shell_app_bundle_destinations[@]}"; do
  if [[ ! -f "$host_bundle_dir/$(basename "$bundle_destination")" ]]; then
    host_bundle_apps_present=0
    break
  fi
done
if [[ "${PIXEL_FORCE_LINUX_BUNDLE_REBUILD-}" != 1 ]] \
  && [[ -d "$host_bundle_dir" ]] \
  && [[ -x "$host_launcher_artifact" ]] \
  && [[ -f "$host_bundle_dir/$host_binary_name" ]] \
  && [[ "$host_bundle_apps_present" == "1" ]] \
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

declare -a host_bundle_app_paths=()
for app_id in "${supported_shell_app_ids[@]}"; do
  rm -f "$host_bundle_dir/$(basename "$(pixel_runtime_app_bundle_dst_for "$app_id")")"
done
for index in "${!shell_app_ids[@]}"; do
  host_bundle_app_path="$host_bundle_dir/$(basename "${shell_app_bundle_destinations[$index]}")"
  cp "${shell_app_bundle_artifacts[$index]}" "$host_bundle_app_path"
  host_bundle_app_paths+=("$host_bundle_app_path")
done
if shell_app_selected podcast && [[ -n "$podcast_asset_dir" ]]; then
  chmod -R u+w "$host_bundle_dir/assets" 2>/dev/null || true
  rm -rf "$host_bundle_dir/assets"
  cp -R "$podcast_asset_dir"/. "$host_bundle_dir"/
else
  chmod -R u+w "$host_bundle_dir/assets" 2>/dev/null || true
  rm -rf "$host_bundle_dir/assets"
fi
if ((${#host_bundle_app_paths[@]})); then
  chmod 0644 "${host_bundle_app_paths[@]}"
fi

runtime_helper_content_fingerprint="$(
  runtime_bundle_directory_fingerprint "$host_bundle_dir"
)"
APP_MANIFEST_JSON="$app_manifest_json" python3 - "$runtime_manifest_path" "$runtime_helper_content_fingerprint" "$audio_enabled" "$extra_bundle_dir" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

(
    manifest_path,
    content_fingerprint,
    audio_enabled,
    extra_bundle_dir,
) = sys.argv[1:5]
artifact_manifest = json.loads(os.environ["APP_MANIFEST_JSON"])
apps = {
    app_id: {
        "bundleEnv": app.get("bundleEnv"),
        "bundleFilename": app.get("bundleFilename"),
        "cacheDir": app.get("cacheDir"),
        "extraAssetDir": app.get("extraAssetDir"),
        "inputPath": app.get("inputPath"),
        "runtimeAppConfig": app.get("runtimeAppConfig"),
    }
    for app_id, app in artifact_manifest["apps"].items()
}
manifest = {
    "apps": apps,
    "contentFingerprint": content_fingerprint,
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "mode": "pixel-shell-runtime",
    "linuxAudioEnabled": audio_enabled == "1",
    "runtimeExtraBundleArtifactDir": os.path.abspath(extra_bundle_dir) if extra_bundle_dir else None,
    "selectedAppIds": sorted(apps.keys()),
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY

APP_MANIFEST_JSON="$app_manifest_json" python3 - "$host_bundle_dir" "$host_bundle_cache_hit" "$(pixel_runtime_host_launcher_dst)" <<'PY'
import json
import os
import sys

(
    host_bundle_dir,
    host_bundle_cache_hit,
    runtime_host_launcher_device_path,
) = sys.argv[1:4]
artifact_manifest = json.loads(os.environ["APP_MANIFEST_JSON"])

def camel_app_key(app_id):
    parts = app_id.split("-")
    return parts[0] + "".join(part[:1].upper() + part[1:] for part in parts[1:])

apps = {}
legacy = {}
for app_id, app in artifact_manifest["apps"].items():
    artifact = app["artifactBundlePath"] or app["effectiveBundlePath"]
    device_path = app["guestBundlePath"]
    apps[app_id] = {
        "bundleArtifact": os.path.abspath(artifact),
        "bundleDevicePath": device_path,
    }
    key = camel_app_key(app_id)
    legacy[f"{key}BundleArtifact"] = os.path.abspath(artifact)
    legacy[f"{key}BundleDevicePath"] = device_path

payload = {
    **legacy,
    "apps": apps,
    "mode": "pixel-shell-runtime",
    "runtimeHostBundleArtifactDir": os.path.abspath(host_bundle_dir),
    "runtimeHostBundleCacheHit": host_bundle_cache_hit == "1",
    "runtimeHostLauncherDevicePath": runtime_host_launcher_device_path,
    "selectedAppIds": sorted(apps.keys()),
}
print(json.dumps(payload, indent=2))
PY
