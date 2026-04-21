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
host_bundle_dir="$(pixel_shell_system_bundle_artifact_dir)"
host_bundle_out_link="$(pixel_dir)/shadow-system-shell-aarch64-linux-gnu-result"
host_binary_name="shadow-system"
host_launcher_artifact="$host_bundle_dir/run-shadow-system"
compositor_out_link="$(pixel_dir)/shadow-compositor-guest-aarch64-linux-gnu-result"
compositor_binary_name="shadow-compositor-guest"
compositor_launcher_artifact="$host_bundle_dir/run-shadow-compositor-guest"
host_bundle_manifest_path="$host_bundle_dir/.bundle-manifest.json"
runtime_manifest_path="$host_bundle_dir/.runtime-bundle-manifest.json"
package_ref="$repo#packages.${linux_system}.shadow-system"
compositor_package_ref="$repo#packages.${linux_system}.shadow-compositor-guest-aarch64-linux-gnu"
extra_bundle_binary_name="shadow-blitz-demo"
extra_bundle_dir="$(pixel_artifact_path shadow-blitz-demo-gpu-gnu)"
extra_bundle_package_ref="$repo#packages.${linux_system}.shadow-blitz-demo-aarch64-linux-gnu-gpu"
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
declare -a runtime_app_ids=()
declare -a shell_runtime_source_inputs=()
declare -a supported_runtime_app_ids=()
selected_runtime_app_ids=()

mapfile -t shell_runtime_source_inputs < <(
  printf '%s\n' "$repo/ui/Cargo.toml"
  printf '%s\n' "$repo/ui/Cargo.lock"
  printf '%s\n' "$repo/rust/Cargo.toml"
  printf '%s\n' "$repo/rust/Cargo.lock"
  runtime_bundle_cargo_package_source_inputs "$repo/ui/apps/shadow-blitz-demo"
  runtime_bundle_cargo_package_source_inputs "$repo/ui/crates/shadow-compositor-common"
  runtime_bundle_cargo_package_source_inputs "$repo/ui/crates/shadow-compositor-guest"
  runtime_bundle_cargo_package_source_inputs "$repo/ui/crates/shadow-ui-core"
  runtime_bundle_cargo_package_source_inputs "$repo/ui/crates/shadow-ui-software"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/runtime-camera-host"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/shadow-sdk"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/shadow-system"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/shadow-runtime-protocol"
  runtime_bundle_cargo_package_source_inputs "$repo/rust/shadow-linux-audio-spike"
  printf '%s\n' "$repo/ui/third_party/anyrender_vello"
  printf '%s\n' "$repo/ui/third_party/wgpu_context"
  printf '%s\n' "$repo/ui/third_party/winit"
)

podcast_episode_ids="${SHADOW_PODCAST_PLAYER_EPISODE_IDS:-00}"
app_artifact_root="${PIXEL_SHELL_APP_ARTIFACT_ROOT:-build/runtime/pixel-shell-app-artifacts}"
podcast_asset_dir=""
podcast_config_json=""
extra_bundle_fingerprint="__no_extra_bundle__"

mapfile -t supported_runtime_app_ids < <(pixel_runtime_shell_app_ids)

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

runtime_app_is_supported() {
  local app_id="$1"
  local supported_app_id

  for supported_app_id in "${supported_runtime_app_ids[@]}"; do
    if [[ "$supported_app_id" == "$app_id" ]]; then
      return 0
    fi
  done
  return 1
}

runtime_app_selected() {
  local app_id="$1"
  local selected_app_id

  for selected_app_id in "${selected_runtime_app_ids[@]}"; do
    if [[ "$selected_app_id" == "$app_id" ]]; then
      return 0
    fi
  done
  return 1
}

append_selected_runtime_app() {
  local app_id="$1"
  local selected_app_id

  for selected_app_id in "${selected_runtime_app_ids[@]}"; do
    if [[ "$selected_app_id" == "$app_id" ]]; then
      return 0
    fi
  done
  selected_runtime_app_ids+=("$app_id")
}

selected_shell_app_ids_csv="${PIXEL_SHELL_APP_IDS:-}"
if [[ -n "$selected_shell_app_ids_csv" ]]; then
  IFS=',' read -r -a requested_shell_app_ids <<<"$selected_shell_app_ids_csv"
  for requested_app_id in "${requested_shell_app_ids[@]}"; do
    requested_app_id="$(trim_whitespace "$requested_app_id")"
    if [[ -z "$requested_app_id" ]]; then
      continue
    fi
    if ! runtime_app_is_supported "$requested_app_id"; then
      echo "pixel_prepare_shell_runtime_artifacts: unsupported TypeScript runtime app in PIXEL_SHELL_APP_IDS: $requested_app_id" >&2
      exit 1
    fi
    append_selected_runtime_app "$requested_app_id"
  done
fi
if ((${#selected_runtime_app_ids[@]} == 0)); then
  selected_runtime_app_ids=("${supported_runtime_app_ids[@]}")
fi
selected_shell_app_ids_csv="$(IFS=,; printf '%s' "${selected_runtime_app_ids[*]}")"

cached_shell_app_manifest_json() {
  local manifest_path
  manifest_path="$app_artifact_root/artifact-manifest.json"

  if [[ ! -f "$manifest_path" ]]; then
    return 1
  fi

  SELECTED_APPS_CSV="$selected_shell_app_ids_csv" MANIFEST_PATH="$manifest_path" python3 - <<'PY'
import json
import os
import sys

manifest_path = os.environ["MANIFEST_PATH"]
selected = [
    app_id
    for app_id in os.environ.get("SELECTED_APPS_CSV", "").split(",")
    if app_id
]

with open(manifest_path, "r", encoding="utf-8") as handle:
    data = json.load(handle)

if data.get("profile") != "pixel-shell":
    raise SystemExit(1)

apps = data.get("apps", {})
for app_id in selected:
    app_entry = apps.get(app_id)
    if not isinstance(app_entry, dict):
        raise SystemExit(1)
    bundle_path = app_entry.get("effectiveBundlePath")
    if not bundle_path or not os.path.isfile(bundle_path):
        raise SystemExit(1)

print(json.dumps(data))
PY
}

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

extra_bundle_dir="$(normalize_runtime_bundle_input_path "$extra_bundle_dir")"
if [[ ! -d "$extra_bundle_dir" ]]; then
  echo "pixel_prepare_shell_runtime_artifacts: missing GPU bundle dir: $extra_bundle_dir" >&2
  exit 1
fi
require_runtime_bundle_entry \
  "$extra_bundle_dir" \
  "$extra_bundle_binary_name" \
  "pixel_prepare_shell_runtime_artifacts"
extra_bundle_fingerprint="$(runtime_bundle_directory_fingerprint "$extra_bundle_dir")"

if app_manifest_json="$(cached_shell_app_manifest_json)"; then
  printf 'Shell runtime app artifact cacheHit -> %s\n' "$app_artifact_root"
else
  app_manifest_json="$(
    runtime_build_args=(--profile pixel-shell --artifact-root "$app_artifact_root")
    if runtime_app_selected podcast; then
      runtime_build_args+=(--include-podcast)
    fi
    for selected_app_id in "${selected_runtime_app_ids[@]}"; do
      runtime_build_args+=(--include-app "$selected_app_id")
    done
    if ((${#selected_runtime_app_ids[@]})); then
      SHADOW_PODCAST_PLAYER_EPISODE_IDS="$podcast_episode_ids" \
        "$SCRIPT_DIR/runtime_build_artifacts.sh" \
          "${runtime_build_args[@]}"
    else
      printf '{\n  "apps": {}\n}\n'
    fi
  )"
fi

runtime_app_ids=("${selected_runtime_app_ids[@]}")

mkdir -p "$(pixel_artifacts_dir)"
for app_id in "${runtime_app_ids[@]}"; do
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
    "__pixel_shell_compositor_package_ref__${compositor_package_ref}" \
    "__extra_bundle_dir__${extra_bundle_dir:-}" \
    "__extra_bundle_package_ref__${extra_bundle_package_ref:-}" \
    "__extra_bundle_fingerprint__${extra_bundle_fingerprint}"
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
  && [[ -x "$compositor_launcher_artifact" ]] \
  && [[ -f "$host_bundle_dir/$host_binary_name" ]] \
  && [[ -f "$host_bundle_dir/$compositor_binary_name" ]] \
  && [[ "$host_bundle_apps_present" == "1" ]] \
  && [[ -d "$host_bundle_dir/share/X11/xkb" ]] \
  && [[ ! -L "$host_bundle_dir/share/X11/xkb" ]] \
  && runtime_bundle_manifest_matches "$host_bundle_manifest_path" "$host_bundle_source_fingerprint"; then
  host_bundle_cache_hit=1
  if [[ ! -f "$host_bundle_dir/$extra_bundle_binary_name" ]]; then
    host_bundle_cache_hit=0
  fi
  if [[ "$audio_enabled" == "1" ]] \
    && { [[ ! -x "$audio_launcher_artifact" ]] || [[ ! -f "$host_bundle_dir/$audio_binary_name" ]]; }; then
    host_bundle_cache_hit=0
  fi
fi
if [[ "$host_bundle_cache_hit" == "1" ]]; then
  printf 'Shell system bundle cacheHit -> %s\n' "$host_bundle_dir"
else
  stage_system_linux_bundle "$package_ref" "$host_bundle_out_link" "$host_bundle_dir" "$host_binary_name"
  pixel_retry_nix_build nix build --accept-flake-config "$compositor_package_ref" --out-link "$compositor_out_link"
  cp "$compositor_out_link/bin/$compositor_binary_name" "$host_bundle_dir/$compositor_binary_name"
  chmod 0755 "$host_bundle_dir/$compositor_binary_name"
  append_runtime_closure_from_package_ref "$compositor_package_ref"
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

  chmod -R u+w "$host_bundle_dir" 2>/dev/null || true
  cp -R "$extra_bundle_dir"/. "$host_bundle_dir"/
  append_runtime_closure_from_package_ref "$extra_bundle_package_ref"
  fill_linux_bundle_runtime_deps "$host_bundle_dir"

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
if [ "\$#" -lt 1 ]; then
  echo "usage: $host_binary_name <args>" >&2
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
if command -v chroot >/dev/null 2>&1 && [ "\$(id -u)" = 0 ]; then
  rewrite_dir_env_path() {
    var_name="\$1"
    case "\$var_name" in
      HOME) value="\${HOME-}" ;;
      XDG_CACHE_HOME) value="\${XDG_CACHE_HOME-}" ;;
      XDG_CONFIG_HOME) value="\${XDG_CONFIG_HOME-}" ;;
      XKB_CONFIG_ROOT) value="\${XKB_CONFIG_ROOT-}" ;;
      MESA_SHADER_CACHE_DIR) value="\${MESA_SHADER_CACHE_DIR-}" ;;
      VK_ICD_FILENAMES) value="\${VK_ICD_FILENAMES-}" ;;
      SHADOW_LINUX_LD_PRELOAD) value="\${SHADOW_LINUX_LD_PRELOAD-}" ;;
      SHADOW_RUNTIME_APP_BUNDLE_PATH) value="\${SHADOW_RUNTIME_APP_BUNDLE_PATH-}" ;;
      SHADOW_SYSTEM_BINARY_PATH) value="\${SHADOW_SYSTEM_BINARY_PATH-}" ;;
      SHADOW_SYSTEM_STAGE_LOADER_PATH) value="\${SHADOW_SYSTEM_STAGE_LOADER_PATH-}" ;;
      SHADOW_SYSTEM_STAGE_LIBRARY_PATH) value="\${SHADOW_SYSTEM_STAGE_LIBRARY_PATH-}" ;;
      *) value="" ;;
    esac
    case "\$value" in
      "\$DIR"/*)
        value="/\${value#\$DIR/}"
        export "\$var_name=\$value"
        ;;
    esac
  }
  for var_name in \
    HOME \
    XDG_CACHE_HOME \
    XDG_CONFIG_HOME \
    XKB_CONFIG_ROOT \
    MESA_SHADER_CACHE_DIR \
    VK_ICD_FILENAMES \
    SHADOW_LINUX_LD_PRELOAD \
    SHADOW_RUNTIME_APP_BUNDLE_PATH \
    SHADOW_SYSTEM_BINARY_PATH \
    SHADOW_SYSTEM_STAGE_LOADER_PATH \
    SHADOW_SYSTEM_STAGE_LIBRARY_PATH
  do
    rewrite_dir_env_path "\$var_name"
  done
  if [ "\$#" -eq 2 ] && [ "\$1" = "--session" ]; then
    case "\$2" in
      "\$DIR"/*) set -- "\$1" "/\${2#\$DIR/}" ;;
    esac
  fi
  exec chroot "\$DIR" "/lib/$PIXEL_RUNTIME_STAGE_LOADER_NAME" --library-path /lib "/$host_binary_name" "\$@"
fi
exec "\$DIR/lib/$PIXEL_RUNTIME_STAGE_LOADER_NAME" --library-path "\$DIR/lib" "\$DIR/$host_binary_name" "\$@"
EOF
  fi
  chmod 0755 "$host_launcher_artifact"

  cat >"$compositor_launcher_artifact" <<EOF
#!/system/bin/sh
DIR=\$(cd "\$(dirname "\$0")" && pwd)
export HOME="\${HOME:-\$DIR/home}"
export XDG_CACHE_HOME="\${XDG_CACHE_HOME:-\$HOME/.cache}"
export XDG_CONFIG_HOME="\${XDG_CONFIG_HOME:-\$HOME/.config}"
export MESA_SHADER_CACHE_DIR="\${MESA_SHADER_CACHE_DIR:-\$XDG_CACHE_HOME/mesa}"
export LD_LIBRARY_PATH="\$DIR/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export LIBGL_DRIVERS_PATH="\$DIR/lib/dri\${LIBGL_DRIVERS_PATH:+:\$LIBGL_DRIVERS_PATH}"
export __EGL_VENDOR_LIBRARY_DIRS="\${__EGL_VENDOR_LIBRARY_DIRS:-\$DIR/share/glvnd/egl_vendor.d}"
export VK_ICD_FILENAMES="\${VK_ICD_FILENAMES:-\$DIR/share/vulkan/icd.d/freedreno_icd.aarch64.json}"
export XKB_CONFIG_EXTRA_PATH="\${XKB_CONFIG_EXTRA_PATH:-\$DIR/etc/xkb}"
export XKB_CONFIG_ROOT="\${XKB_CONFIG_ROOT:-\$DIR/share/X11/xkb}"
mkdir -p "\$HOME" "\$XDG_CACHE_HOME" "\$XDG_CONFIG_HOME" "\$MESA_SHADER_CACHE_DIR"
exec "\$DIR/lib/$PIXEL_RUNTIME_STAGE_LOADER_NAME" --library-path "\$DIR/lib" "\$DIR/$compositor_binary_name" "\$@"
EOF
  chmod 0755 "$compositor_launcher_artifact"

  write_runtime_bundle_manifest \
    "$host_bundle_manifest_path" \
    "$host_bundle_source_fingerprint" \
    "$package_ref"
fi

declare -a host_bundle_app_paths=()
for app_id in "${supported_runtime_app_ids[@]}"; do
  rm -f "$host_bundle_dir/$(basename "$(pixel_runtime_app_bundle_dst_for "$app_id")")"
done
for index in "${!runtime_app_ids[@]}"; do
  host_bundle_app_path="$host_bundle_dir/$(basename "${shell_app_bundle_destinations[$index]}")"
  cp "${shell_app_bundle_artifacts[$index]}" "$host_bundle_app_path"
  host_bundle_app_paths+=("$host_bundle_app_path")
done
if runtime_app_selected podcast && [[ -n "$podcast_asset_dir" ]]; then
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

APP_MANIFEST_JSON="$app_manifest_json" python3 - "$host_bundle_dir" "$host_bundle_cache_hit" "$(pixel_system_launcher_dst)" <<'PY'
import json
import os
import sys

(
    host_bundle_dir,
    host_bundle_cache_hit,
    system_launcher_device_path,
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
    "systemBundleArtifactDir": os.path.abspath(host_bundle_dir),
    "systemBundleCacheHit": host_bundle_cache_hit == "1",
    "systemLauncherDevicePath": system_launcher_device_path,
    "selectedAppIds": sorted(apps.keys()),
}
print(json.dumps(payload, indent=2))
PY
