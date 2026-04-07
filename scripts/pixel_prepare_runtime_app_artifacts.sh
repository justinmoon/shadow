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
input_path="${PIXEL_RUNTIME_APP_INPUT_PATH:-runtime/app-counter/app.tsx}"
cache_dir="${PIXEL_RUNTIME_APP_CACHE_DIR:-build/runtime/pixel-counter}"
bundle_artifact="$(pixel_runtime_app_bundle_artifact)"
host_bundle_dir="$(pixel_runtime_host_bundle_artifact_dir)"
host_bundle_out_link="$(pixel_dir)/shadow-runtime-host-aarch64-linux-gnu-result"
host_binary_name="shadow-runtime-host"
host_launcher_artifact="$host_bundle_dir/run-shadow-runtime-host"
package_ref="$repo#shadow-runtime-host-aarch64-linux-gnu"
audio_enabled="${PIXEL_RUNTIME_ENABLE_LINUX_AUDIO:-0}"
audio_package_ref="$repo#shadow-linux-audio-spike-aarch64-linux-gnu"
audio_out_link="$(pixel_dir)/shadow-linux-audio-spike-aarch64-linux-gnu-result"
audio_binary_name="shadow-linux-audio-spike"
audio_launcher_artifact="$host_bundle_dir/run-$audio_binary_name"
extra_bundle_dir="${PIXEL_RUNTIME_EXTRA_BUNDLE_ARTIFACT_DIR-}"
host_bundle_manifest_path="$host_bundle_dir/.bundle-manifest.json"
runtime_manifest_path="$host_bundle_dir/.runtime-bundle-manifest.json"
bundle_json=""
bundle_source_path=""
bundle_dir=""
bundle_asset_dir=""
host_bundle_cache_hit=0
host_bundle_source_fingerprint=""
runtime_helper_content_fingerprint=""

bundle_json="$(
  nix develop "$repo"#runtime -c deno run --quiet \
    --allow-env --allow-read --allow-write --allow-run \
    "$repo/scripts/runtime_prepare_app_bundle.ts" \
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
print(os.path.abspath(data["bundlePath"]))
'
)"
bundle_dir="$(
  printf '%s\n' "$bundle_json" | python3 -c '
import json
import os
import sys

data = json.load(sys.stdin)
print(os.path.abspath(data["bundleDir"]))
'
)"
bundle_asset_dir="$(
  printf '%s\n' "$bundle_json" | python3 -c '
import json
import os
import sys

data = json.load(sys.stdin)
asset_dir = data.get("assetDir")
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

host_bundle_source_fingerprint="$(
  runtime_bundle_source_fingerprint \
    "$package_ref" \
    "$repo/flake.nix" \
    "$repo/flake.lock" \
    "$repo/rust/shadow-runtime-host" \
    "$repo/rust/shadow-runtime-host/Cargo.lock" \
    "$repo/rust/runtime-audio-host" \
    "$repo/rust/runtime-nostr-host" \
    "$repo/rust/shadow-linux-audio-spike" \
    "$repo/rust/vendor/temporal_rs" \
    "$SCRIPT_DIR/pixel_prepare_runtime_app_artifacts.sh" \
    "$SCRIPT_DIR/pixel_runtime_linux_bundle_common.sh" \
    "${bundle_asset_dir:-__no_bundle_assets__}" \
    "${extra_bundle_dir:-__no_extra_bundle__}" \
    "__pixel_runtime_enable_linux_audio__${audio_enabled}" \
    "__pixel_runtime_audio_package_ref__${audio_package_ref}"
)"

if [[ "${PIXEL_FORCE_LINUX_BUNDLE_REBUILD-}" != 1 ]] \
  && [[ -d "$host_bundle_dir" ]] \
  && [[ -x "$host_launcher_artifact" ]] \
  && [[ -f "$host_bundle_dir/$host_binary_name" ]] \
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
    nix build --accept-flake-config "$audio_package_ref" --out-link "$audio_out_link"
    cp "$audio_out_link/bin/$audio_binary_name" "$host_bundle_dir/$audio_binary_name"
    chmod 0755 "$host_bundle_dir/$audio_binary_name"
    append_runtime_closure_from_package_ref "$audio_package_ref"
  fi
  fill_linux_bundle_runtime_deps "$host_bundle_dir"
  if [[ "$audio_enabled" == "1" ]]; then
    copy_closure_dir_into_bundle "share/alsa" "$host_bundle_dir/share/alsa"
    mkdir -p "$host_bundle_dir/lib/alsa-lib"
    copy_closure_dir_into_bundle "lib/alsa-lib" "$host_bundle_dir/lib/alsa-lib" optional
  fi

  if [[ -n "$bundle_asset_dir" && -d "$bundle_asset_dir" ]]; then
    chmod -R u+w "$host_bundle_dir" 2>/dev/null || true
    rm -rf "$host_bundle_dir/assets"
    cp -R "$bundle_asset_dir" "$host_bundle_dir/assets"
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
export SHADOW_RUNTIME_AUDIO_BACKEND="\${SHADOW_RUNTIME_AUDIO_BACKEND:-linux_spike}"
export SHADOW_RUNTIME_AUDIO_SPIKE_BINARY="\$DIR/run-$audio_binary_name"
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

python3 - "$bundle_artifact" "$bundle_dir" "$bundle_asset_dir" "$host_bundle_dir" "$input_path" "$extra_bundle_dir" "$host_bundle_cache_hit" <<'PY'
import json
import os
import sys

bundle_artifact, bundle_dir, bundle_asset_dir, host_bundle_dir, input_path, extra_bundle_dir, host_bundle_cache_hit = sys.argv[1:8]
print(json.dumps({
    "runtimeHostBundleCacheHit": host_bundle_cache_hit == "1",
    "runtimeHelperContentFingerprint": json.load(open(os.path.join(host_bundle_dir, ".runtime-bundle-manifest.json"), "r", encoding="utf-8"))["contentFingerprint"],
    "inputPath": input_path,
    "runtimeBundleAssetDir": os.path.abspath(bundle_asset_dir) if bundle_asset_dir else None,
    "runtimeBundleDir": os.path.abspath(bundle_dir),
    "runtimeExtraBundleArtifactDir": os.path.abspath(extra_bundle_dir) if extra_bundle_dir else None,
    "runtimeAppBundleArtifact": os.path.abspath(bundle_artifact),
    "runtimeAppBundleDevicePath": "/data/local/tmp/shadow-runtime-gnu/runtime-app-bundle.js",
    "runtimeHostBundleArtifactDir": os.path.abspath(host_bundle_dir),
    "runtimeHostBinaryDevicePath": "/data/local/tmp/shadow-runtime-gnu/shadow-runtime-host",
    "runtimeHostLauncherDevicePath": "/data/local/tmp/shadow-runtime-gnu/run-shadow-runtime-host",
}, indent=2))
PY
