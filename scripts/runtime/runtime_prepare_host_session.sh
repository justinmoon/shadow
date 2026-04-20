#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INPUT_PATH="${SHADOW_RUNTIME_APP_INPUT_PATH:-}"
CACHE_DIR="${SHADOW_RUNTIME_APP_CACHE_DIR:-}"
runtime_flake_ref=""
system_package_attr="shadow-system"
system_binary_path="${SHADOW_RUNTIME_SYSTEM_BINARY_PATH:-}"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --flake-ref)
        runtime_flake_ref="${2:-}"
        shift 2
        ;;
      --system-package)
        system_package_attr="${2:-}"
        shift 2
        ;;
      --system-binary-path)
        system_binary_path="${2:-}"
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

builder_args=(
  --profile single
  --app-id app
)
if [[ -n "$runtime_flake_ref" ]]; then
  builder_args+=(--flake-ref "$REPO_FLAKE_REF")
fi
if [[ -n "$system_binary_path" ]]; then
  if [[ -n "$system_package_attr" ]]; then
    builder_args+=(--system-package "$system_package_attr")
  fi
  builder_args+=(--system-binary-path "$system_binary_path")
elif [[ -n "$system_package_attr" ]]; then
  builder_args+=(--system-package "$system_package_attr")
fi
if [[ -n "$INPUT_PATH" ]]; then
  builder_args+=(--input "$INPUT_PATH")
fi
if [[ -n "$CACHE_DIR" ]]; then
  builder_args+=(--cache-dir "$CACHE_DIR")
fi

manifest_json="$(
  "$SCRIPT_DIR/runtime_build_artifacts.sh" "${builder_args[@]}"
)"

bundle_path="$(
  printf '%s\n' "$manifest_json" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(data["apps"]["app"]["effectiveBundlePath"])
'
)"
bundle_dir="$(
  printf '%s\n' "$manifest_json" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(data["apps"]["app"]["effectiveBundleDir"])
'
)"
system_binary_path="$(
  printf '%s\n' "$manifest_json" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(data["systemBinaryPath"])
'
)"
input_path="$(
  printf '%s\n' "$manifest_json" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(data["apps"]["app"]["inputPath"])
'
)"
cache_dir="$(
  printf '%s\n' "$manifest_json" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
print(data["apps"]["app"]["cacheDir"])
'
)"
viewport_width=""
viewport_height=""
while IFS='=' read -r key value; do
  case "$key" in
    viewport_width)
      viewport_width="$value"
      ;;
    viewport_height)
      viewport_height="$value"
      ;;
  esac
done < <(python3 "$SCRIPT_DIR/runtime/runtime_viewport.py")

if [[ -z "$viewport_width" || -z "$viewport_height" ]]; then
  echo "runtime_prepare_host_session.sh: failed to read runtime viewport" >&2
  exit 1
fi

python3 - "$bundle_path" "$bundle_dir" "$system_binary_path" "$input_path" "$cache_dir" "$system_package_attr" "$viewport_width" "$viewport_height" <<'PY'
import json
import os
import shlex
import sys

bundle_path, bundle_dir, system_binary_path, input_path, cache_dir, package_attr, viewport_width, viewport_height = sys.argv[1:9]
system_env = {
    "SHADOW_APP_SURFACE_WIDTH": viewport_width,
    "SHADOW_APP_SURFACE_HEIGHT": viewport_height,
    "SHADOW_APP_SAFE_AREA_LEFT": "0",
    "SHADOW_APP_SAFE_AREA_TOP": "0",
    "SHADOW_APP_SAFE_AREA_RIGHT": "0",
    "SHADOW_APP_SAFE_AREA_BOTTOM": "0",
    "SHADOW_BLITZ_SURFACE_WIDTH": viewport_width,
    "SHADOW_BLITZ_SURFACE_HEIGHT": viewport_height,
    "SHADOW_BLITZ_SAFE_AREA_LEFT": "0",
    "SHADOW_BLITZ_SAFE_AREA_TOP": "0",
    "SHADOW_BLITZ_SAFE_AREA_RIGHT": "0",
    "SHADOW_BLITZ_SAFE_AREA_BOTTOM": "0",
}
wrapper_path = os.path.join(os.path.abspath(cache_dir), "shadow-system-launch.sh")
os.makedirs(os.path.dirname(wrapper_path), exist_ok=True)
with open(wrapper_path, "w", encoding="utf-8") as wrapper:
    wrapper.write("#!/usr/bin/env bash\n")
    wrapper.write("set -euo pipefail\n")
    for key, value in system_env.items():
        wrapper.write(f"export {key}={shlex.quote(value)}\n")
    wrapper.write(f"exec {shlex.quote(system_binary_path)} \"$@\"\n")
os.chmod(wrapper_path, 0o755)
print(json.dumps({
    "bundlePath": bundle_path,
    "bundleDir": bundle_dir,
    "cacheDir": cache_dir,
    "inputPath": input_path,
    "systemBinaryPath": wrapper_path,
    "systemBinaryName": os.path.basename(system_binary_path),
    "systemEnv": system_env,
    "systemExecPath": system_binary_path,
    "systemPackageAttr": package_attr,
}, indent=2))
PY
