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
input_path="${PIXEL_RUNTIME_APP_INPUT_PATH:-runtime/app-compile-smoke/app.tsx}"
cache_dir="${PIXEL_RUNTIME_APP_CACHE_DIR:-build/runtime/pixel-app}"
bundle_artifact="$(pixel_runtime_app_bundle_artifact)"
host_bundle_dir="$(pixel_runtime_host_bundle_artifact_dir)"
host_bundle_out_link="$(pixel_dir)/deno-core-smoke-aarch64-linux-gnu-result"
host_binary_name="deno-core-smoke"
host_launcher_artifact="$host_bundle_dir/run-deno-core-smoke"
package_ref="$repo#deno-core-smoke-aarch64-linux-gnu"
bundle_json=""
bundle_source_path=""

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

mkdir -p "$(dirname "$bundle_artifact")"
cp "$bundle_source_path" "$bundle_artifact"
chmod 0644 "$bundle_artifact"

stage_deno_core_linux_bundle "$package_ref" "$host_bundle_out_link" "$host_bundle_dir" "$host_binary_name"

cat >"$host_launcher_artifact" <<EOF
#!/system/bin/sh
DIR=\$(cd "\$(dirname "\$0")" && pwd)
exec "\$DIR/lib/$PIXEL_RUNTIME_STAGE_LOADER_NAME" --library-path "\$DIR/lib" "\$DIR/$host_binary_name" "\$@"
EOF
chmod 0755 "$host_launcher_artifact"

python3 - "$bundle_artifact" "$host_bundle_dir" "$input_path" <<'PY'
import json
import os
import sys

bundle_artifact, host_bundle_dir, input_path = sys.argv[1:4]
print(json.dumps({
    "inputPath": input_path,
    "runtimeAppBundleArtifact": os.path.abspath(bundle_artifact),
    "runtimeAppBundleDevicePath": "/data/local/tmp/shadow-runtime-gnu/runtime-app-bundle.js",
    "runtimeHostBundleArtifactDir": os.path.abspath(host_bundle_dir),
    "runtimeHostBinaryDevicePath": "/data/local/tmp/shadow-runtime-gnu/deno-core-smoke",
    "runtimeHostLauncherDevicePath": "/data/local/tmp/shadow-runtime-gnu/run-deno-core-smoke",
}, indent=2))
PY
