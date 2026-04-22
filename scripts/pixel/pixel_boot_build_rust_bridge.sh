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
CHILD_BINARY="${PIXEL_HELLO_INIT_RUST_CHILD_BIN:-}"
CHILD_ENTRY="${PIXEL_HELLO_INIT_RUST_CHILD_ENTRY:-hello-init-child}"
KEY_PATH="${AVB_TEST_KEY_PATH:-}"
OUTPUT_IMAGE="${PIXEL_BOOT_RUST_BRIDGE_IMAGE:-}"
KEEP_WORK_DIR=0

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_build_rust_bridge.sh --input PATH [--shim PATH]
                                                     [--child PATH] [--child-entry NAME]
                                                     [--key PATH] [--output PATH]
                                                     [--keep-work-dir]

Repack an already-proven owned-userspace boot image so Rust uses a no_std exact-path
PID 1 shim at /system/bin/init and launches the full Rust hello-init as /hello-init-child.
If the input image has a companion .hello-init.json, clone it to the output image path so
post-boot recovery still knows the expected run token and metadata paths.
EOF
}

default_output_image() {
  local input_path base_name extension stem
  input_path="${1:?default_output_image requires an input path}"
  base_name="$(basename "$input_path")"
  extension=""
  stem="$base_name"
  if [[ "$base_name" == *.img ]]; then
    extension=".img"
    stem="${base_name%.img}"
  fi
  printf '%s/%s-rust-bridge%s\n' "$(pixel_boot_dir)" "$stem" "$extension"
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

  python3 - "$source_metadata" "$destination_metadata" "$OUTPUT_IMAGE" "$CHILD_ENTRY" <<'PY'
import json
import sys
from pathlib import Path

source_metadata = Path(sys.argv[1])
destination_metadata = Path(sys.argv[2])
output_image = sys.argv[3]
child_entry = sys.argv[4]

payload = json.loads(source_metadata.read_text(encoding="utf-8"))
payload["image"] = output_image
payload["hello_init_child_path"] = f"/{child_entry}"
payload["hello_init_impl"] = "rust-bridge"
payload["hello_init_mode"] = "rust-bridge"
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
    --child)
      CHILD_BINARY="${2:?missing value for --child}"
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

if [[ -z "$KEY_PATH" ]]; then
  KEY_PATH="$(ensure_cached_avb_testkey)"
fi

if [[ -z "$SHIM_BINARY" ]]; then
  SHIM_BINARY="$(pixel_boot_dir)/hello-init-rust-shim"
  build_or_copy_rust_binary "path:$(repo_root)#hello-init-rust-shim-device" "$SHIM_BINARY" "hello-init-shim"
fi

if [[ -z "$CHILD_BINARY" ]]; then
  CHILD_BINARY="$(pixel_boot_dir)/hello-init-rust"
  build_or_copy_rust_binary "path:$(repo_root)#hello-init-rust-device" "$CHILD_BINARY" "hello-init"
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
printf 'Shim binary: %s\n' "$SHIM_BINARY"
printf 'Child binary: %s\n' "$CHILD_BINARY"
printf 'Child entry path: /%s\n' "$CHILD_ENTRY"
