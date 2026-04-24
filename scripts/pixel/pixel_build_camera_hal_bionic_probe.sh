#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_PATH="${PIXEL_CAMERA_HAL_BIONIC_PROBE_OUT:-}"
ANDROID_API="${PIXEL_CAMERA_HAL_BIONIC_PROBE_ANDROID_API:-35}"
SOURCE_PATH="$SCRIPT_DIR/pixel/pixel_camera_hal_bionic_probe.c"
BUILD_ID_PATH=""

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_build_camera_hal_bionic_probe.sh [--output PATH]
                                                            [--android-api API]

Build the tiny Android/bionic arm64 camera HAL probe helper. The Rust boot
probe launches this helper through /apex/com.android.runtime/bin/linker64 so
dlopen happens in bionic while Rust keeps ownership of boot orchestration and
recovered artifacts.
EOF
}

camera_hal_bionic_probe_build_input_hash() {
  shasum -a 256 \
    "$SOURCE_PATH" \
    "$(repo_root)/scripts/pixel/pixel_build_camera_hal_bionic_probe.sh" \
    "$(repo_root)/flake.nix" \
    "$(repo_root)/flake.lock" \
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

validate_probe_binary() {
  local binary_path file_output
  binary_path="${1:?validate_probe_binary requires a binary path}"

  [[ -f "$binary_path" ]] || {
    echo "pixel_build_camera_hal_bionic_probe: binary not found: $binary_path" >&2
    return 1
  }

  chmod 0755 "$binary_path" 2>/dev/null || true
  [[ -x "$binary_path" ]] || {
    echo "pixel_build_camera_hal_bionic_probe: binary is not executable: $binary_path" >&2
    return 1
  }

  file_output="$(file "$binary_path")"
  printf '%s\n' "$file_output"
  if [[ "$file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_build_camera_hal_bionic_probe: expected an arm64 binary, got: $file_output" >&2
    return 1
  fi
  if [[ "$file_output" != *"dynamically linked"* ]]; then
    echo "pixel_build_camera_hal_bionic_probe: expected a bionic dynamic binary, got: $file_output" >&2
    return 1
  fi
  if ! grep -aFq -- 'shadow-camera-hal-bionic-probe' "$binary_path"; then
    echo "pixel_build_camera_hal_bionic_probe: binary is missing the helper sentinel" >&2
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
      echo "pixel_build_camera_hal_bionic_probe: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! "$ANDROID_API" =~ ^[0-9]+$ ]]; then
  echo "pixel_build_camera_hal_bionic_probe: Android API must be an integer: $ANDROID_API" >&2
  exit 1
fi

if [[ -z "$OUTPUT_PATH" ]]; then
  OUTPUT_PATH="$(pixel_artifact_path camera-hal-bionic-probe)"
fi

pixel_prepare_dirs
mkdir -p "$(dirname "$OUTPUT_PATH")"
BUILD_ID_PATH="${OUTPUT_PATH}.build-id"

expected_build_id="$(camera_hal_bionic_probe_build_input_hash)"
if [[ -f "$OUTPUT_PATH" && -f "$BUILD_ID_PATH" ]]; then
  cached_build_id="$(tr -d '[:space:]' <"$BUILD_ID_PATH")"
  if [[ "$cached_build_id" == "$expected_build_id" ]]; then
    if validate_probe_binary "$OUTPUT_PATH"; then
      printf 'Reusing cached camera HAL bionic probe -> %s\n' "$OUTPUT_PATH"
      exit 0
    fi

    echo "pixel_build_camera_hal_bionic_probe: cached binary is invalid; rebuilding: $OUTPUT_PATH" >&2
    rm -f "$OUTPUT_PATH" "$BUILD_ID_PATH"
  fi
fi

if ! clang_path="$(find_android_clang)"; then
  if [[ "${SHADOW_ANDROID_SHELL:-0}" != "1" ]]; then
    exec nix develop "$(repo_root)#android" --command "$0" \
      --output "$OUTPUT_PATH" \
      --android-api "$ANDROID_API"
  fi
  echo "pixel_build_camera_hal_bionic_probe: aarch64-linux-android${ANDROID_API}-clang not found" >&2
  exit 1
fi

tmp_path="$OUTPUT_PATH.tmp"
rm -f "$tmp_path"
"$clang_path" \
  -fPIE \
  -pie \
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
validate_probe_binary "$OUTPUT_PATH"
printf '%s\n' "$expected_build_id" >"$BUILD_ID_PATH"

printf 'Built camera HAL bionic probe -> %s\n' "$OUTPUT_PATH"
