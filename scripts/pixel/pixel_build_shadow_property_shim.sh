#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_PATH="${PIXEL_SHADOW_PROPERTY_SHIM_OUT:-}"
ANDROID_API="${PIXEL_SHADOW_PROPERTY_SHIM_ANDROID_API:-35}"
SOURCE_PATH="$SCRIPT_DIR/pixel/shadow_property_shim.c"
BUILD_ID_PATH=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_build_shadow_property_shim.sh [--output PATH]
                                                          [--android-api API]

Build the tiny Android/bionic arm64 property/log shim used by boot-owned
Wi-Fi helper probes when they are launched through Android's linker64.
EOF
}

property_shim_build_input_hash() {
  local clang_identity clang_path
  clang_identity="missing"
  if clang_path="$(find_android_clang 2>/dev/null)"; then
    clang_identity="$clang_path :: $("$clang_path" --version 2>/dev/null | sed -n '1p')"
  fi

  {
    printf 'android_api=%s\n' "$ANDROID_API"
    printf 'clang=%s\n' "$clang_identity"
    shasum -a 256 \
      "$SOURCE_PATH" \
      "$(repo_root)/scripts/pixel/pixel_build_shadow_property_shim.sh" \
      "$(repo_root)/flake.nix" \
      "$(repo_root)/flake.lock"
  } \
    | shasum -a 256 \
    | awk '{print $1}'
}

find_android_clang() {
  local clang_path prebuilt_dir

  if command -v "aarch64-linux-android${ANDROID_API}-clang" >/dev/null 2>&1; then
    command -v "aarch64-linux-android${ANDROID_API}-clang"
    return 0
  fi

  if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
    for prebuilt_dir in "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*; do
      clang_path="$prebuilt_dir/bin/aarch64-linux-android${ANDROID_API}-clang"
      if [[ -x "$clang_path" ]]; then
        printf '%s\n' "$clang_path"
        return 0
      fi
    done
  fi

  return 1
}

validate_property_shim() {
  local binary_path file_output
  binary_path="${1:?validate_property_shim requires a binary path}"

  [[ -f "$binary_path" ]] || {
    echo "pixel_build_shadow_property_shim: binary not found: $binary_path" >&2
    return 1
  }

  chmod 0755 "$binary_path" 2>/dev/null || true
  file_output="$(file "$binary_path")"
  printf '%s\n' "$file_output"
  if [[ "$file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_build_shadow_property_shim: expected an arm64 shared object, got: $file_output" >&2
    return 1
  fi
  if [[ "$file_output" != *"shared object"* ]]; then
    echo "pixel_build_shadow_property_shim: expected a shared object, got: $file_output" >&2
    return 1
  fi
  if ! grep -aFq -- 'shadow-property-shim' "$binary_path"; then
    echo "pixel_build_shadow_property_shim: binary is missing the shim sentinel" >&2
    return 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_PATH="${2:?missing value for --output}"
      shift 2
      ;;
    --android-api)
      ANDROID_API="${2:?missing value for --android-api}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "pixel_build_shadow_property_shim: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! "$ANDROID_API" =~ ^[0-9]+$ ]]; then
  echo "pixel_build_shadow_property_shim: Android API must be an integer: $ANDROID_API" >&2
  exit 1
fi

if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$(pixel_artifact_path shadow-property-shim)"
fi

pixel_prepare_dirs
mkdir -p "$(dirname "$OUTPUT_PATH")"
BUILD_ID_PATH="${OUTPUT_PATH}.build-id"

expected_build_id="$(property_shim_build_input_hash)"
if [[ -f "$OUTPUT_PATH" && -f "$BUILD_ID_PATH" ]]; then
  cached_build_id="$(tr -d '[:space:]' <"$BUILD_ID_PATH")"
  if [[ "$cached_build_id" == "$expected_build_id" ]]; then
    if validate_property_shim "$OUTPUT_PATH"; then
      printf 'Reusing cached shadow property shim -> %s\n' "$OUTPUT_PATH"
      exit 0
    fi

    echo "pixel_build_shadow_property_shim: cached binary is invalid; rebuilding: $OUTPUT_PATH" >&2
    rm -f "$OUTPUT_PATH" "$BUILD_ID_PATH"
  fi
fi

if ! clang_path="$(find_android_clang)"; then
  if [[ "${SHADOW_ANDROID_SHELL:-0}" != "1" ]]; then
    exec nix develop "$(repo_root)#android" --command "$0" \
      --output "$OUTPUT_PATH" \
      --android-api "$ANDROID_API"
  fi
  echo "pixel_build_shadow_property_shim: aarch64-linux-android${ANDROID_API}-clang not found" >&2
  exit 1
fi

tmp_path="$OUTPUT_PATH.tmp"
rm -f "$tmp_path"
"$clang_path" \
  -shared \
  -fPIC \
  -O2 \
  -g0 \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  "$SOURCE_PATH" \
  -ldl \
  -o "$tmp_path"
mv "$tmp_path" "$OUTPUT_PATH"
chmod 0755 "$OUTPUT_PATH"
validate_property_shim "$OUTPUT_PATH"
printf '%s\n' "$expected_build_id" >"$BUILD_ID_PATH"

printf 'Built shadow property shim -> %s\n' "$OUTPUT_PATH"
