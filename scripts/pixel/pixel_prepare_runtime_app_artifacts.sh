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
input_path="${PIXEL_RUNTIME_APP_INPUT_PATH:-runtime/app-counter/app.tsx}"
cache_dir="${PIXEL_RUNTIME_APP_CACHE_DIR:-build/runtime/pixel-counter}"
bundle_artifact="$(pixel_runtime_app_bundle_artifact)"
host_bundle_dir="$(pixel_runtime_host_bundle_artifact_dir)"
asset_artifact_dir="$(pixel_runtime_app_asset_artifact_dir)"
host_bundle_out_link="$(pixel_dir)/shadow-runtime-host-aarch64-linux-gnu-result"
host_binary_name="shadow-runtime-host"
host_launcher_artifact="$host_bundle_dir/run-shadow-runtime-host"
package_ref="$repo#packages.${linux_system}.shadow-runtime-host"
audio_enabled="${PIXEL_RUNTIME_ENABLE_LINUX_AUDIO:-0}"
audio_package_ref="$repo#packages.${linux_system}.shadow-linux-audio-spike-aarch64-linux-gnu"
audio_out_link="$(pixel_dir)/shadow-linux-audio-spike-aarch64-linux-gnu-result"
audio_binary_name="shadow-linux-audio-spike"
audio_launcher_artifact="$host_bundle_dir/run-$audio_binary_name"
extra_bundle_dir="${PIXEL_RUNTIME_EXTRA_BUNDLE_ARTIFACT_DIR-}"
extra_asset_dir="${PIXEL_RUNTIME_APP_EXTRA_ASSET_DIR-}"
host_bundle_manifest_path="$host_bundle_dir/.bundle-manifest.json"
runtime_manifest_path="$host_bundle_dir/.runtime-bundle-manifest.json"
asset_manifest_path="$asset_artifact_dir/.runtime-assets-manifest.json"
bundle_json=""
bundle_source_path=""
bundle_dir=""
bundle_asset_dir=""
host_bundle_cache_hit=0
host_bundle_source_fingerprint=""
runtime_helper_content_fingerprint=""
asset_cache_hit=0
asset_source_fingerprint=""
asset_content_fingerprint=""
xkb_source_dir="$(runtime_bundle_xkb_source_dir)"
android_font_source_dir="$(runtime_bundle_android_font_source_dir)"
declare -a runtime_host_source_inputs=()

mapfile -t runtime_host_source_inputs < <(
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

runtime_asset_directory_fingerprint() {
  local dir="$1"

  (
    cd "$dir"
    find . -type f ! -name '.runtime-assets-manifest.json' | LC_ALL=C sort | while IFS= read -r file; do
      file="${file#./}"
      printf 'file %s %s\n' "$(runtime_bundle_file_hash "$dir/$file")" "$file"
    done
  ) | shasum -a 256 | awk '{print $1}'
}

bundle_json="$(
  "$SCRIPT_DIR/runtime_build_artifacts.sh" \
    --profile single \
    --app-id app \
    --input "$input_path" \
    --cache-dir "$cache_dir"
)"
printf '%s\n' "$bundle_json"

bundle_source_path="$(
  printf '%s\n' "$bundle_json" | python3 -c '
import json
import os
import sys

data = json.load(sys.stdin)
print(data["apps"]["app"]["effectiveBundlePath"])
'
)"
bundle_dir="$(
  printf '%s\n' "$bundle_json" | python3 -c '
import json
import os
import sys

data = json.load(sys.stdin)
print(data["apps"]["app"]["effectiveBundleDir"])
'
)"
bundle_asset_dir="$(
  printf '%s\n' "$bundle_json" | python3 -c '
import json
import os
import sys

data = json.load(sys.stdin)
asset_dir = data["apps"]["app"].get("assetDir")
print(os.path.abspath(asset_dir) if asset_dir else "")
'
)"

mkdir -p "$(dirname "$bundle_artifact")"
cp "$bundle_source_path" "$bundle_artifact"
chmod 0644 "$bundle_artifact"

if [[ -n "$extra_bundle_dir" ]]; then
  extra_bundle_dir="$(normalize_runtime_bundle_input_path "$extra_bundle_dir")"
  if [[ ! -d "$extra_bundle_dir" ]]; then
    echo "pixel_prepare_runtime_app_artifacts: extra bundle dir not found: $extra_bundle_dir" >&2
    exit 1
  fi
fi
if [[ -n "$extra_asset_dir" ]]; then
  extra_asset_dir="$(normalize_runtime_bundle_input_path "$extra_asset_dir")"
  if [[ ! -d "$extra_asset_dir" ]]; then
    echo "pixel_prepare_runtime_app_artifacts: extra asset dir not found: $extra_asset_dir" >&2
    exit 1
  fi
fi

host_bundle_source_fingerprint="$(
  runtime_bundle_source_fingerprint \
    "$package_ref" \
    "$repo/flake.nix" \
    "$repo/flake.lock" \
    "${runtime_host_source_inputs[@]}" \
    "$repo/rust/vendor/temporal_rs" \
    "$SCRIPT_DIR/pixel/pixel_prepare_runtime_app_artifacts.sh" \
    "$SCRIPT_DIR/lib/pixel_runtime_linux_bundle_common.sh" \
    "$SCRIPT_DIR/runtime_build_artifacts.sh" \
    "$SCRIPT_DIR/runtime/runtime_build_artifacts.ts" \
    "$SCRIPT_DIR/runtime/runtime_prepare_app_bundle.ts" \
    "$SCRIPT_DIR/runtime/runtime_compile_solid.ts" \
    "$xkb_source_dir" \
    "$android_font_source_dir" \
    "${extra_bundle_dir:-__no_extra_bundle__}" \
    "__pixel_runtime_enable_linux_audio__${audio_enabled}" \
    "__pixel_runtime_audio_package_ref__${audio_package_ref}"
)"

if [[ "${PIXEL_FORCE_LINUX_BUNDLE_REBUILD-}" != 1 ]] \
  && [[ -d "$host_bundle_dir" ]] \
  && [[ -x "$host_launcher_artifact" ]] \
  && [[ -f "$host_bundle_dir/$host_binary_name" ]] \
  && [[ -d "$host_bundle_dir/share/X11/xkb" ]] \
  && [[ ! -L "$host_bundle_dir/share/X11/xkb" ]] \
  && runtime_bundle_manifest_matches "$host_bundle_manifest_path" "$host_bundle_source_fingerprint"; then
  host_bundle_cache_hit=1
  if [[ "$audio_enabled" == "1" ]] \
    && { [[ ! -x "$audio_launcher_artifact" ]] || [[ ! -f "$host_bundle_dir/$audio_binary_name" ]]; }; then
    host_bundle_cache_hit=0
  fi
  if [[ "$host_bundle_cache_hit" == "1" ]]; then
    printf 'Runtime host bundle cacheHit -> %s\n' "$host_bundle_dir"
  fi
fi

if [[ "$host_bundle_cache_hit" != "1" ]]; then
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

if [[ -f "$runtime_manifest_path" ]]; then
  runtime_helper_content_fingerprint="$(
    python3 - "$runtime_manifest_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    print(json.load(handle).get("contentFingerprint", ""))
PY
  )"
fi

if [[ -z "$runtime_helper_content_fingerprint" || "$host_bundle_cache_hit" != "1" ]]; then
  runtime_helper_content_fingerprint="$(
    runtime_bundle_directory_fingerprint "$host_bundle_dir"
  )"
  python3 - "$runtime_manifest_path" "$runtime_helper_content_fingerprint" "$input_path" "$bundle_asset_dir" "$extra_bundle_dir" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

manifest_path, content_fingerprint, input_path, bundle_asset_dir, extra_bundle_dir = sys.argv[1:6]
manifest = {
    "contentFingerprint": content_fingerprint,
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "inputPath": input_path,
    "runtimeBundleAssetDir": os.path.abspath(bundle_asset_dir) if bundle_asset_dir else None,
    "runtimeExtraBundleArtifactDir": os.path.abspath(extra_bundle_dir) if extra_bundle_dir else None,
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY
fi

if [[ -n "$bundle_asset_dir" || -n "$extra_asset_dir" ]]; then
  asset_source_fingerprint="$(
    {
      printf 'script %s\n' "$(runtime_bundle_file_hash "$SCRIPT_DIR/pixel/pixel_prepare_runtime_app_artifacts.sh")"
      if [[ -n "$bundle_asset_dir" && -d "$bundle_asset_dir" ]]; then
        printf 'bundle_assets %s\n' "$(runtime_bundle_directory_fingerprint "$bundle_asset_dir")"
      else
        printf 'bundle_assets none\n'
      fi
      if [[ -n "$extra_asset_dir" && -d "$extra_asset_dir" ]]; then
        printf 'extra_assets %s\n' "$(runtime_bundle_directory_fingerprint "$extra_asset_dir")"
      else
        printf 'extra_assets none\n'
      fi
    } | shasum -a 256 | awk '{print $1}'
  )"
  if [[ "${PIXEL_FORCE_LINUX_BUNDLE_REBUILD-}" != 1 ]] \
    && [[ -d "$asset_artifact_dir" ]] \
    && runtime_bundle_manifest_matches "$asset_manifest_path" "$asset_source_fingerprint"; then
    asset_content_fingerprint="$(
      python3 - "$asset_manifest_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    print(json.load(handle).get("contentFingerprint", ""))
PY
    )"
    if [[ -n "$asset_content_fingerprint" ]] \
      && [[ "$(runtime_asset_directory_fingerprint "$asset_artifact_dir")" == "$asset_content_fingerprint" ]]; then
      asset_cache_hit=1
      printf 'Runtime app assets cacheHit -> %s\n' "$asset_artifact_dir"
    fi
  fi

  if [[ "$asset_cache_hit" != "1" ]]; then
    rm -rf "$asset_artifact_dir"
    mkdir -p "$asset_artifact_dir"
    if [[ -n "$bundle_asset_dir" && -d "$bundle_asset_dir" ]]; then
      cp -R "$bundle_asset_dir"/. "$asset_artifact_dir"/
    fi
    if [[ -n "$extra_asset_dir" ]]; then
      cp -R "$extra_asset_dir"/. "$asset_artifact_dir"/
    fi
    asset_content_fingerprint="$(
      runtime_asset_directory_fingerprint "$asset_artifact_dir"
    )"
    python3 - "$asset_manifest_path" "$asset_source_fingerprint" "$asset_content_fingerprint" "$bundle_asset_dir" "$extra_asset_dir" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

manifest_path, fingerprint, content_fingerprint, bundle_asset_dir, extra_asset_dir = sys.argv[1:6]
manifest = {
    "contentFingerprint": content_fingerprint,
    "fingerprint": fingerprint,
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "runtimeBundleAssetDir": os.path.abspath(bundle_asset_dir) if bundle_asset_dir else None,
    "runtimeExtraAssetDir": os.path.abspath(extra_asset_dir) if extra_asset_dir else None,
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY
  fi

  if [[ -z "$asset_content_fingerprint" && -f "$asset_manifest_path" ]]; then
    asset_content_fingerprint="$(
      python3 - "$asset_manifest_path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    print(json.load(handle).get("contentFingerprint", ""))
PY
    )"
  fi
else
  rm -rf "$asset_artifact_dir"
fi

python3 - "$bundle_artifact" "$bundle_dir" "$bundle_asset_dir" "$host_bundle_dir" "$input_path" "$extra_bundle_dir" "$host_bundle_cache_hit" "$asset_artifact_dir" "$asset_cache_hit" "$asset_content_fingerprint" "$extra_asset_dir" <<'PY'
import json
import os
import sys

(
    bundle_artifact,
    bundle_dir,
    bundle_asset_dir,
    host_bundle_dir,
    input_path,
    extra_bundle_dir,
    host_bundle_cache_hit,
    asset_artifact_dir,
    asset_cache_hit,
    asset_content_fingerprint,
    extra_asset_dir,
) = sys.argv[1:12]
print(json.dumps({
    "runtimeAppAssetArtifactDir": os.path.abspath(asset_artifact_dir) if asset_artifact_dir else None,
    "runtimeAppAssetsCacheHit": asset_cache_hit == "1",
    "runtimeAppAssetsContentFingerprint": asset_content_fingerprint or None,
    "runtimeHostBundleCacheHit": host_bundle_cache_hit == "1",
    "runtimeHelperContentFingerprint": json.load(open(os.path.join(host_bundle_dir, ".runtime-bundle-manifest.json"), "r", encoding="utf-8"))["contentFingerprint"],
    "inputPath": input_path,
    "runtimeBundleAssetDir": os.path.abspath(bundle_asset_dir) if bundle_asset_dir else None,
    "runtimeBundleDir": os.path.abspath(bundle_dir),
    "runtimeExtraAssetDir": os.path.abspath(extra_asset_dir) if extra_asset_dir else None,
    "runtimeExtraBundleArtifactDir": os.path.abspath(extra_bundle_dir) if extra_bundle_dir else None,
    "runtimeAppBundleArtifact": os.path.abspath(bundle_artifact),
    "runtimeAppBundleDevicePath": "/data/local/tmp/shadow-runtime-gnu/runtime-app-bundle.js",
    "runtimeHostBundleArtifactDir": os.path.abspath(host_bundle_dir),
    "runtimeHostBinaryDevicePath": "/data/local/tmp/shadow-runtime-gnu/shadow-runtime-host",
    "runtimeHostLauncherDevicePath": "/data/local/tmp/shadow-runtime-gnu/run-shadow-runtime-host",
}, indent=2))
PY
