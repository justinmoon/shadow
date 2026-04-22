#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./bootimg_common.sh
source "$SCRIPT_DIR/lib/bootimg_common.sh"
ensure_bootimg_shell "$@"

INPUT_IMAGE="${PIXEL_BOOT_INPUT_IMAGE:-}"
SHIM_BINARY="${PIXEL_HELLO_INIT_RUST_SHIM_BIN:-}"
SHIM_MODE="${PIXEL_HELLO_INIT_RUST_SHIM_MODE:-exec}"
CHILD_BINARY="${PIXEL_HELLO_INIT_RUST_CHILD_BIN:-}"
CHILD_PROFILE="${PIXEL_HELLO_INIT_RUST_CHILD_PROFILE:-hello}"
CHILD_ENTRY="${PIXEL_HELLO_INIT_RUST_CHILD_ENTRY:-hello-init-child}"
KEY_PATH="${AVB_TEST_KEY_PATH:-}"
OUTPUT_IMAGE="${PIXEL_BOOT_RUST_BRIDGE_IMAGE:-}"
KEEP_WORK_DIR=0
CHILD_PROFILE_EXPLICIT=0
DEFAULT_CHILD_ENTRY="hello-init-child"

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_build_rust_bridge.sh --input PATH [--shim PATH]
                                                     [--shim-mode fork|exec]
                                                     [--child PATH] [--child-profile hello|std-probe|std-minimal-probe|std-nomain-probe|nostd-probe]
                                                     [--key PATH] [--output PATH]
                                                     [--keep-work-dir]

Repack an already-proven owned-userspace boot image so Rust uses a no_std exact-path
PID 1 shim at /system/bin/init and launches a Rust child at /hello-init-child.
If the input image has a companion .hello-init.json, clone it to the output image path so
post-boot recovery still knows the expected run token and metadata paths.
EOF
}

assert_shim_mode_word() {
  local value
  value="${1:?assert_shim_mode_word requires a value}"

  case "$value" in
    fork|exec)
      ;;
    *)
      echo "pixel_boot_build_rust_bridge: unsupported shim mode: $value" >&2
      exit 1
      ;;
  esac
}

assert_child_profile_word() {
  local value
  value="${1:?assert_child_profile_word requires a value}"

  case "$value" in
    hello|std-probe|std-minimal-probe|std-nomain-probe|nostd-probe)
      ;;
    *)
      echo "pixel_boot_build_rust_bridge: unsupported child profile: $value" >&2
      exit 1
      ;;
  esac
}

default_output_image() {
  local input_path base_name extension stem suffix
  input_path="${1:?default_output_image requires an input path}"
  base_name="$(basename "$input_path")"
  extension=""
  stem="$base_name"
  if [[ "$base_name" == *.img ]]; then
    extension=".img"
    stem="${base_name%.img}"
  fi
  suffix="-rust-bridge"
  if [[ "$SHIM_MODE" != "exec" ]]; then
    suffix+="-${SHIM_MODE}"
  fi
  if [[ "$CHILD_PROFILE" != "hello" ]]; then
    suffix+="-${CHILD_PROFILE}"
  fi
  printf '%s/%s%s%s\n' "$(pixel_boot_dir)" "$stem" "$suffix" "$extension"
}

default_shim_binary() {
  case "$SHIM_MODE" in
    fork)
      printf '%s\n' "${PIXEL_HELLO_INIT_RUST_SHIM_DEFAULT_BIN:-$(pixel_boot_dir)/hello-init-rust-shim}"
      ;;
    exec)
      printf '%s\n' "${PIXEL_HELLO_INIT_RUST_SHIM_EXEC_DEFAULT_BIN:-$(pixel_boot_dir)/hello-init-rust-shim-exec}"
      ;;
  esac
}

default_shim_package_ref() {
  case "$SHIM_MODE" in
    fork)
      printf 'path:%s#hello-init-rust-shim-device\n' "$(repo_root)"
      ;;
    exec)
      printf 'path:%s#hello-init-rust-shim-exec-device\n' "$(repo_root)"
      ;;
  esac
}

default_shim_binary_name() {
  case "$SHIM_MODE" in
    fork)
      printf 'hello-init-shim\n'
      ;;
    exec)
      printf 'hello-init-shim-exec\n'
      ;;
  esac
}

default_child_binary() {
  case "$CHILD_PROFILE" in
    hello)
      printf '%s\n' "${PIXEL_HELLO_INIT_RUST_CHILD_DEFAULT_BIN:-$(pixel_boot_dir)/hello-init-rust}"
      ;;
    std-probe)
      printf '%s\n' "${PIXEL_HELLO_INIT_RUST_CHILD_STD_PROBE_DEFAULT_BIN:-$(pixel_boot_dir)/hello-init-rust-probe}"
      ;;
    std-minimal-probe)
      printf '%s\n' "${PIXEL_HELLO_INIT_RUST_CHILD_STD_MINIMAL_PROBE_DEFAULT_BIN:-$(pixel_boot_dir)/hello-init-rust-std-minimal-probe}"
      ;;
    std-nomain-probe)
      printf '%s\n' "${PIXEL_HELLO_INIT_RUST_CHILD_STD_NOMAIN_PROBE_DEFAULT_BIN:-$(pixel_boot_dir)/hello-init-rust-std-nomain-probe}"
      ;;
    nostd-probe)
      printf '%s\n' "${PIXEL_HELLO_INIT_RUST_CHILD_NOSTD_PROBE_DEFAULT_BIN:-$(pixel_boot_dir)/hello-init-rust-nostd-probe}"
      ;;
  esac
}

default_child_package_ref() {
  case "$CHILD_PROFILE" in
    hello)
      printf 'path:%s#hello-init-rust-device\n' "$(repo_root)"
      ;;
    std-probe)
      printf 'path:%s#hello-init-rust-probe-device\n' "$(repo_root)"
      ;;
    std-minimal-probe)
      printf 'path:%s#hello-init-rust-std-minimal-probe-device\n' "$(repo_root)"
      ;;
    std-nomain-probe)
      printf 'path:%s#hello-init-rust-std-nomain-probe-device\n' "$(repo_root)"
      ;;
    nostd-probe)
      printf 'path:%s#hello-init-rust-nostd-probe-device\n' "$(repo_root)"
      ;;
  esac
}

default_child_binary_name() {
  case "$CHILD_PROFILE" in
    hello)
      printf 'hello-init\n'
      ;;
    std-probe)
      printf 'hello-init-probe\n'
      ;;
    std-minimal-probe)
      printf 'hello-init-std-minimal-probe\n'
      ;;
    std-nomain-probe)
      printf 'hello-init-std-nomain-probe\n'
      ;;
    nostd-probe)
      printf 'hello-init-nostd-probe\n'
      ;;
  esac
}

effective_child_profile() {
  if [[ -n "$CHILD_BINARY" && "$CHILD_PROFILE_EXPLICIT" != "1" ]]; then
    printf 'custom\n'
    return
  fi
  printf '%s\n' "$CHILD_PROFILE"
}

build_or_copy_rust_binary() {
  local package_ref destination binary_name store_path
  package_ref="${1:?build_or_copy_rust_binary requires a package ref}"
  destination="${2:?build_or_copy_rust_binary requires a destination}"
  binary_name="${3:?build_or_copy_rust_binary requires a binary name}"

  mkdir -p "$(dirname "$destination")"
  store_path="$(
    pixel_retry_nix_build_print_out_paths nix build --no-link --print-out-paths "$package_ref"
  )"
  cp "$store_path/bin/$binary_name" "$destination"
  chmod 0755 "$destination"
}

assert_rust_bridge_binary() {
  local binary_path file_output
  binary_path="${1:?assert_rust_bridge_binary requires a binary path}"

  file_output="$(file "$binary_path")"
  if [[ "$file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_boot_build_rust_bridge: expected an arm64 binary, got: $file_output" >&2
    exit 1
  fi
  if [[ "$file_output" == *"dynamically linked"* ]]; then
    echo "pixel_boot_build_rust_bridge: expected a static binary, got a dynamic one: $file_output" >&2
    exit 1
  fi
  if ! grep -aFq -- 'shadow-owned-init-role:hello-init' "$binary_path"; then
    echo "pixel_boot_build_rust_bridge: binary is missing the hello-init role sentinel: $binary_path" >&2
    exit 1
  fi
  if ! grep -aFq -- 'shadow-owned-init-impl:rust-static' "$binary_path"; then
    echo "pixel_boot_build_rust_bridge: binary is missing the rust-static implementation sentinel: $binary_path" >&2
    exit 1
  fi
  if ! grep -aFq -- 'shadow-owned-init-config:/shadow-init.cfg' "$binary_path"; then
    echo "pixel_boot_build_rust_bridge: binary is missing the config-path sentinel: $binary_path" >&2
    exit 1
  fi
}

clone_companion_metadata() {
  local source_metadata destination_metadata
  source_metadata="${1:?clone_companion_metadata requires a source metadata path}"
  destination_metadata="${2:?clone_companion_metadata requires a destination metadata path}"

  python3 - "$source_metadata" "$destination_metadata" "$OUTPUT_IMAGE" "$CHILD_ENTRY" "$SHIM_MODE" "$(effective_child_profile)" <<'PY'
import json
import sys
from pathlib import Path

source_metadata = Path(sys.argv[1])
destination_metadata = Path(sys.argv[2])
output_image = sys.argv[3]
child_entry = sys.argv[4]
shim_mode = sys.argv[5]
child_profile = sys.argv[6]

payload = json.loads(source_metadata.read_text(encoding="utf-8"))
payload["image"] = output_image
payload["hello_init_child_path"] = f"/{child_entry}"
payload["hello_init_impl"] = "rust-bridge"
payload["hello_init_mode"] = "rust-bridge"
payload["hello_init_child_profile"] = child_profile
payload["hello_init_shim_mode"] = shim_mode
payload["metadata_probe_fingerprint_path"] = ""
payload["metadata_probe_timeout_class_path"] = ""
destination_metadata.write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      INPUT_IMAGE="${2:?missing value for --input}"
      shift 2
      ;;
    --shim)
      SHIM_BINARY="${2:?missing value for --shim}"
      shift 2
      ;;
    --shim-mode)
      SHIM_MODE="${2:?missing value for --shim-mode}"
      shift 2
      ;;
    --child)
      CHILD_BINARY="${2:?missing value for --child}"
      shift 2
      ;;
    --child-profile)
      CHILD_PROFILE="${2:?missing value for --child-profile}"
      CHILD_PROFILE_EXPLICIT=1
      shift 2
      ;;
    --child-entry)
      CHILD_ENTRY="${2:?missing value for --child-entry}"
      shift 2
      ;;
    --key)
      KEY_PATH="${2:?missing value for --key}"
      shift 2
      ;;
    --output)
      OUTPUT_IMAGE="${2:?missing value for --output}"
      shift 2
      ;;
    --keep-work-dir)
      KEEP_WORK_DIR=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "pixel_boot_build_rust_bridge: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -n "$INPUT_IMAGE" ]] || {
  echo "pixel_boot_build_rust_bridge: --input is required" >&2
  exit 1
}
[[ -f "$INPUT_IMAGE" ]] || {
  echo "pixel_boot_build_rust_bridge: input image not found: $INPUT_IMAGE" >&2
  exit 1
}
assert_shim_mode_word "$SHIM_MODE"
assert_child_profile_word "$CHILD_PROFILE"

if [[ "$CHILD_ENTRY" != "$DEFAULT_CHILD_ENTRY" ]]; then
  echo "pixel_boot_build_rust_bridge: unsupported child entry: $CHILD_ENTRY" >&2
  echo "pixel_boot_build_rust_bridge: the current Rust shims always exec /$DEFAULT_CHILD_ENTRY" >&2
  exit 1
fi

if [[ -z "$KEY_PATH" ]]; then
  KEY_PATH="$(ensure_cached_avb_testkey)"
fi

if [[ -z "$SHIM_BINARY" ]]; then
  SHIM_BINARY="$(default_shim_binary)"
  build_or_copy_rust_binary "$(default_shim_package_ref)" "$SHIM_BINARY" "$(default_shim_binary_name)"
fi

if [[ -z "$CHILD_BINARY" ]]; then
  CHILD_BINARY="$(default_child_binary)"
  build_or_copy_rust_binary "$(default_child_package_ref)" "$CHILD_BINARY" "$(default_child_binary_name)"
fi

assert_rust_bridge_binary "$SHIM_BINARY"
assert_rust_bridge_binary "$CHILD_BINARY"

if [[ -z "$OUTPUT_IMAGE" ]]; then
  OUTPUT_IMAGE="$(default_output_image "$INPUT_IMAGE")"
fi

mkdir -p "$(dirname "$OUTPUT_IMAGE")"
build_args=(
  --stock-init
  --input "$INPUT_IMAGE"
  --key "$KEY_PATH"
  --output "$OUTPUT_IMAGE"
  --replace "system/bin/init=$SHIM_BINARY"
  --add "$CHILD_ENTRY=$CHILD_BINARY"
)
if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  build_args+=(--keep-work-dir)
fi

"$SCRIPT_DIR/pixel/pixel_boot_build.sh" "${build_args[@]}"

if [[ -f "$INPUT_IMAGE.hello-init.json" ]]; then
  clone_companion_metadata "$INPUT_IMAGE.hello-init.json" "$OUTPUT_IMAGE.hello-init.json"
  printf 'Copied companion metadata: %s\n' "$OUTPUT_IMAGE.hello-init.json"
fi

printf 'Rust bridge input: %s\n' "$INPUT_IMAGE"
printf 'Rust bridge output: %s\n' "$OUTPUT_IMAGE"
printf 'Shim mode: %s\n' "$SHIM_MODE"
printf 'Shim binary: %s\n' "$SHIM_BINARY"
printf 'Child profile: %s\n' "$(effective_child_profile)"
printf 'Child binary: %s\n' "$CHILD_BINARY"
printf 'Child entry path: /%s\n' "$CHILD_ENTRY"
