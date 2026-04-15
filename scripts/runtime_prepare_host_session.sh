#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INPUT_PATH="${SHADOW_RUNTIME_APP_INPUT_PATH:-runtime/app-counter/app.tsx}"
CACHE_DIR="${SHADOW_RUNTIME_APP_CACHE_DIR:-build/runtime/app-counter-host}"
runtime_flake_ref=""
runtime_host_package_attr="shadow-runtime-host"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --flake-ref)
        runtime_flake_ref="${2:-}"
        shift 2
        ;;
      --runtime-host-package)
        runtime_host_package_attr="${2:-}"
        shift 2
        ;;
      *)
        echo "runtime_prepare_host_session.sh: unsupported argument $1" >&2
        exit 1
        ;;
    esac
  done
}

parse_args "$@"
REPO_FLAKE_REF="${runtime_flake_ref:-${REPO_ROOT}}"

cd "$REPO_ROOT"

bundle_json="$(
  nix develop --accept-flake-config "${REPO_FLAKE_REF}#runtime" -c deno run --quiet \
    --allow-env --allow-read --allow-write --allow-run \
    scripts/runtime_prepare_app_bundle.ts \
    --input "$INPUT_PATH" \
    --cache-dir "$CACHE_DIR"
)"

bundle_path="$(
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

runtime_host_prefix="$(
  nix build --accept-flake-config "${REPO_FLAKE_REF}#${runtime_host_package_attr}" --no-link --print-out-paths
)"
runtime_host_binary_path="${runtime_host_prefix}/bin/shadow-runtime-host"

python3 - "$bundle_path" "$bundle_dir" "$runtime_host_binary_path" "$INPUT_PATH" "$CACHE_DIR" "$runtime_host_package_attr" <<'PY'
import json
import os
import sys

bundle_path, bundle_dir, runtime_host_binary_path, input_path, cache_dir, package_attr = sys.argv[1:7]
print(json.dumps({
    "bundlePath": bundle_path,
    "bundleDir": bundle_dir,
    "cacheDir": cache_dir,
    "inputPath": input_path,
    "runtimeHostPackageAttr": package_attr,
    "runtimeHostBinaryPath": runtime_host_binary_path,
    "runtimeHostBinaryName": os.path.basename(runtime_host_binary_path),
}, indent=2))
PY
