#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./bootimg_common.sh
source "$SCRIPT_DIR/lib/bootimg_common.sh"
ensure_bootimg_shell "$@"

INPUT_IMAGE="${PIXEL_BOOT_INPUT_IMAGE:-}"
HELLO_INIT_BINARY="${PIXEL_HELLO_INIT_BIN:-}"
ORANGE_INIT_BINARY="${PIXEL_ORANGE_INIT_BIN:-}"
KEY_PATH="${AVB_TEST_KEY_PATH:-}"
OUTPUT_IMAGE="${PIXEL_BOOT_ORANGE_INIT_IMAGE:-}"
HOLD_SECS="${PIXEL_HELLO_INIT_HOLD_SECS:-3}"
REBOOT_TARGET="${PIXEL_HELLO_INIT_REBOOT_TARGET:-bootloader}"
DEV_MOUNT="${PIXEL_ORANGE_INIT_DEV_MOUNT:-tmpfs}"
MOUNT_DEV="${PIXEL_HELLO_INIT_MOUNT_DEV:-true}"
MOUNT_PROC="${PIXEL_HELLO_INIT_MOUNT_PROC:-true}"
MOUNT_SYS="${PIXEL_HELLO_INIT_MOUNT_SYS:-true}"
LOG_KMSG="${PIXEL_HELLO_INIT_LOG_KMSG:-true}"
LOG_PMSG="${PIXEL_HELLO_INIT_LOG_PMSG:-true}"
RUN_TOKEN="${PIXEL_HELLO_INIT_RUN_TOKEN:-${PIXEL_ORANGE_INIT_RUN_TOKEN:-}}"
DRI_BOOTSTRAP="${PIXEL_ORANGE_INIT_DRI_BOOTSTRAP:-sunfish-card0-renderD128}"
KEEP_WORK_DIR=0
WORK_DIR=""
CONFIG_ENTRY="shadow-init.cfg"
PAYLOAD_ENTRY="orange-init"
METADATA_SUFFIX=".hello-init.json"

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_build_orange_init.sh [--input PATH] [--init PATH]
                                                     [--orange-init PATH] [--key PATH]
                                                     [--output PATH] [--hold-secs N]
                                                     [--reboot-target TARGET]
                                                     [--run-token TOKEN]
                                                     [--dev-mount devtmpfs|tmpfs]
                                                     [--mount-dev true|false]
                                                     [--mount-proc true|false]
                                                     [--mount-sys true|false]
                                                     [--log-kmsg true|false]
                                                     [--log-pmsg true|false]
                                                     [--dri-bootstrap none|sunfish-card0-renderD128]
                                                     [--keep-work-dir]

Build a private stock-kernel sunfish boot.img whose real first-stage userspace is
hello-init PID 1 at system/bin/init and whose ramdisk contains /orange-init.
EOF
}

default_output_image() {
  printf '%s/shadow-boot-orange-init.img\n' "$(pixel_boot_dir)"
}

default_hello_init_binary() {
  printf '%s\n' "${PIXEL_HELLO_INIT_DEFAULT_BIN:-$(pixel_boot_dir)/hello-init}"
}

default_orange_init_binary() {
  printf '%s\n' "${PIXEL_ORANGE_INIT_DEFAULT_BIN:-$(pixel_boot_dir)/orange-init}"
}

hello_init_metadata_path() {
  local image_path
  image_path="${1:?hello_init_metadata_path requires an image path}"
  printf '%s%s\n' "$image_path" "$METADATA_SUFFIX"
}

generate_run_token() {
  python3 - <<'PY'
import secrets

print(secrets.token_hex(16))
PY
}

assert_input_matches_stock_boot() {
  local stock_image
  stock_image="$(pixel_resolve_stock_boot_img)"

  if ! cmp -s "$INPUT_IMAGE" "$stock_image"; then
    cat <<EOF >&2
pixel_boot_build_orange_init: input image must match the cached stock boot image exactly

Input image: $INPUT_IMAGE
Stock image: $stock_image
EOF
    exit 1
  fi
}

assert_stock_root_init_shape() {
  local unpack_dir ramdisk_cpio
  unpack_dir="$WORK_DIR/input-unpacked"
  ramdisk_cpio="$WORK_DIR/input-ramdisk.cpio"

  bootimg_unpack_to_dir "$INPUT_IMAGE" "$unpack_dir"
  bootimg_decompress_ramdisk "$unpack_dir/out/ramdisk" "$ramdisk_cpio" >/dev/null

  PYTHONPATH="$SCRIPT_DIR/lib" python3 - "$ramdisk_cpio" <<'PY'
from pathlib import Path
import stat
import sys

from cpio_edit import read_cpio

ramdisk_cpio = Path(sys.argv[1])
entries = {entry.name: entry for entry in read_cpio(ramdisk_cpio).without_trailer()}

init_entry = entries.get("init")
if init_entry is None:
    raise SystemExit(
        "pixel_boot_build_orange_init: missing root init entry in ramdisk"
    )
if not stat.S_ISLNK(init_entry.mode):
    raise SystemExit(
        "pixel_boot_build_orange_init: expected stock root /init symlink to "
        "/system/bin/init, found non-symlink entry"
    )

target = init_entry.data.decode("utf-8", errors="surrogateescape")
if target != "/system/bin/init":
    raise SystemExit(
        "pixel_boot_build_orange_init: expected stock root /init symlink target "
        f"/system/bin/init, found {target!r}"
    )

system_init_entry = entries.get("system/bin/init")
if system_init_entry is None:
    raise SystemExit(
        "pixel_boot_build_orange_init: missing system/bin/init entry in ramdisk"
    )
if stat.S_ISLNK(system_init_entry.mode):
    raise SystemExit(
        "pixel_boot_build_orange_init: expected stock system/bin/init to be a "
        "regular file, found a symlink"
    )
PY
}

assert_binary_sentinel() {
  local binary_path sentinel message
  binary_path="${1:?assert_binary_sentinel requires a binary path}"
  sentinel="${2:?assert_binary_sentinel requires a sentinel}"
  message="${3:?assert_binary_sentinel requires a message}"

  if ! grep -aFq -- "$sentinel" "$binary_path"; then
    echo "pixel_boot_build_orange_init: $message" >&2
    exit 1
  fi
}

assert_hello_variant() {
  local binary_path file_output
  binary_path="${1:?assert_hello_variant requires a binary path}"

  file_output="$(file "$binary_path")"
  if [[ "$file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_boot_build_orange_init: expected an arm64 hello-init binary, got: $file_output" >&2
    exit 1
  fi
  if [[ "$file_output" == *"dynamically linked"* ]]; then
    echo "pixel_boot_build_orange_init: expected a static hello-init binary, got a dynamic one: $file_output" >&2
    exit 1
  fi

  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-role:hello-init' \
    "binary is missing the hello-init role sentinel"
  if ! grep -aFq -- 'shadow-owned-init-impl:c-static' "$binary_path" && \
     ! grep -aFq -- 'shadow-owned-init-impl:rust-static' "$binary_path"; then
    echo "pixel_boot_build_orange_init: binary is missing a supported static hello-init implementation sentinel" >&2
    exit 1
  fi
  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-config:/shadow-init.cfg' \
    "binary is missing the expected config-path sentinel"
}

assert_orange_variant() {
  local binary_path file_output
  binary_path="${1:?assert_orange_variant requires a binary path}"

  file_output="$(file "$binary_path")"
  if [[ "$file_output" != *"ARM aarch64"* ]]; then
    echo "pixel_boot_build_orange_init: expected an arm64 orange-init binary, got: $file_output" >&2
    exit 1
  fi
  if [[ "$file_output" == *"dynamically linked"* ]]; then
    echo "pixel_boot_build_orange_init: expected a static orange-init binary, got a dynamic one: $file_output" >&2
    exit 1
  fi

  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-role:orange-init' \
    "binary is missing the orange-init role sentinel"
  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-impl:drm-rect-device' \
    "binary is missing the drm-rect-device implementation sentinel"
  assert_binary_sentinel \
    "$binary_path" \
    'shadow-owned-init-path:/orange-init' \
    "binary is missing the orange-init payload-path sentinel"
}

assert_safe_word() {
  local label value max_length
  label="${1:?assert_safe_word requires a label}"
  value="${2:?assert_safe_word requires a value}"
  max_length="${3:?assert_safe_word requires a max length}"

  if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "pixel_boot_build_orange_init: unsupported $label value: $value" >&2
    exit 1
  fi
  if ((${#value} > max_length)); then
    echo "pixel_boot_build_orange_init: $label value exceeds max length $max_length: $value" >&2
    exit 1
  fi
}

assert_bool_word() {
  local label value
  label="${1:?assert_bool_word requires a label}"
  value="${2:?assert_bool_word requires a value}"

  case "$value" in
    true|false)
      ;;
    *)
      echo "pixel_boot_build_orange_init: $label must be true or false: $value" >&2
      exit 1
      ;;
  esac
}

assert_dev_mount_word() {
  local value
  value="${1:?assert_dev_mount_word requires a value}"

  case "$value" in
    devtmpfs|tmpfs)
      ;;
    *)
      echo "pixel_boot_build_orange_init: dev-mount must be devtmpfs or tmpfs: $value" >&2
      exit 1
      ;;
  esac
}

assert_dri_bootstrap_word() {
  local value
  value="${1:?assert_dri_bootstrap_word requires a value}"

  case "$value" in
    none|sunfish-card0-renderD128)
      ;;
    *)
      echo "pixel_boot_build_orange_init: unsupported dri-bootstrap value: $value" >&2
      exit 1
      ;;
  esac
}

render_config() {
  local output_path
  output_path="${1:?render_config requires an output path}"

  cat >"$output_path" <<EOF
# Generated by pixel_boot_build_orange_init.sh
payload=orange-init
hold_seconds=$HOLD_SECS
reboot_target=$REBOOT_TARGET
run_token=$RUN_TOKEN
EOF

  if [[ "$DEV_MOUNT" != "devtmpfs" ]]; then
    printf 'dev_mount=%s\n' "$DEV_MOUNT" >>"$output_path"
  fi
  if [[ "$MOUNT_DEV" != "true" ]]; then
    printf 'mount_dev=%s\n' "$MOUNT_DEV" >>"$output_path"
  fi
  if [[ "$MOUNT_PROC" != "true" ]]; then
    printf 'mount_proc=%s\n' "$MOUNT_PROC" >>"$output_path"
  fi
  if [[ "$MOUNT_SYS" != "true" ]]; then
    printf 'mount_sys=%s\n' "$MOUNT_SYS" >>"$output_path"
  fi
  if [[ "$LOG_KMSG" != "true" ]]; then
    printf 'log_kmsg=%s\n' "$LOG_KMSG" >>"$output_path"
  fi
  if [[ "$LOG_PMSG" != "true" ]]; then
    printf 'log_pmsg=%s\n' "$LOG_PMSG" >>"$output_path"
  fi
  printf 'dri_bootstrap=%s\n' "$DRI_BOOTSTRAP" >>"$output_path"
}

write_metadata() {
  local metadata_path
  metadata_path="$(hello_init_metadata_path "$OUTPUT_IMAGE")"

  python3 - \
    "$metadata_path" \
    "$OUTPUT_IMAGE" \
    "$HOLD_SECS" \
    "$REBOOT_TARGET" \
    "$RUN_TOKEN" \
    "$DEV_MOUNT" \
    "$MOUNT_DEV" \
    "$MOUNT_PROC" \
    "$MOUNT_SYS" \
    "$LOG_KMSG" \
    "$LOG_PMSG" \
    "$DRI_BOOTSTRAP" <<'PY'
import json
import sys
from pathlib import Path

(
    metadata_path,
    image_path,
    hold_seconds,
    reboot_target,
    run_token,
    dev_mount,
    mount_dev,
    mount_proc,
    mount_sys,
    log_kmsg,
    log_pmsg,
    dri_bootstrap,
) = sys.argv[1:]


def parse_bool(raw: str) -> bool:
    return raw == "true"


payload_json = {
    "kind": "orange_init_build",
    "image": image_path,
    "payload": "orange-init",
    "hold_seconds": int(hold_seconds),
    "reboot_target": reboot_target,
    "run_token": run_token,
    "dev_mount": dev_mount,
    "mount_dev": parse_bool(mount_dev),
    "mount_proc": parse_bool(mount_proc),
    "mount_sys": parse_bool(mount_sys),
    "log_kmsg": parse_bool(log_kmsg),
    "log_pmsg": parse_bool(log_pmsg),
    "dri_bootstrap": dri_bootstrap,
}

Path(metadata_path).write_text(
    json.dumps(payload_json, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

cleanup() {
  if [[ "$KEEP_WORK_DIR" == "1" ]]; then
    return 0
  fi
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      INPUT_IMAGE="${2:?missing value for --input}"
      shift 2
      ;;
    --init)
      HELLO_INIT_BINARY="${2:?missing value for --init}"
      shift 2
      ;;
    --orange-init)
      ORANGE_INIT_BINARY="${2:?missing value for --orange-init}"
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
    --hold-secs)
      HOLD_SECS="${2:?missing value for --hold-secs}"
      shift 2
      ;;
    --reboot-target)
      REBOOT_TARGET="${2:?missing value for --reboot-target}"
      shift 2
      ;;
    --run-token)
      RUN_TOKEN="${2:?missing value for --run-token}"
      shift 2
      ;;
    --dev-mount)
      DEV_MOUNT="${2:?missing value for --dev-mount}"
      shift 2
      ;;
    --mount-dev)
      MOUNT_DEV="${2:?missing value for --mount-dev}"
      shift 2
      ;;
    --mount-proc)
      MOUNT_PROC="${2:?missing value for --mount-proc}"
      shift 2
      ;;
    --mount-sys)
      MOUNT_SYS="${2:?missing value for --mount-sys}"
      shift 2
      ;;
    --log-kmsg)
      LOG_KMSG="${2:?missing value for --log-kmsg}"
      shift 2
      ;;
    --log-pmsg)
      LOG_PMSG="${2:?missing value for --log-pmsg}"
      shift 2
      ;;
    --dri-bootstrap)
      DRI_BOOTSTRAP="${2:?missing value for --dri-bootstrap}"
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
      echo "pixel_boot_build_orange_init: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$INPUT_IMAGE" ]]; then
  INPUT_IMAGE="$(pixel_resolve_stock_boot_img || true)"
fi

[[ -f "$INPUT_IMAGE" ]] || {
  cat <<EOF >&2
pixel_boot_build_orange_init: input image not found: $INPUT_IMAGE

Run 'sc root-prep' first to cache the stock sunfish boot.img.
EOF
  exit 1
}

if [[ ! "$HOLD_SECS" =~ ^[0-9]+$ ]]; then
  echo "pixel_boot_build_orange_init: hold seconds must be an integer: $HOLD_SECS" >&2
  exit 1
fi
if (( HOLD_SECS > 3600 )); then
  echo "pixel_boot_build_orange_init: hold seconds must be <= 3600: $HOLD_SECS" >&2
  exit 1
fi
assert_safe_word reboot-target "$REBOOT_TARGET" 31
assert_dev_mount_word "$DEV_MOUNT"
assert_bool_word mount-dev "$MOUNT_DEV"
assert_bool_word mount-proc "$MOUNT_PROC"
assert_bool_word mount-sys "$MOUNT_SYS"
assert_bool_word log-kmsg "$LOG_KMSG"
assert_bool_word log-pmsg "$LOG_PMSG"
assert_dri_bootstrap_word "$DRI_BOOTSTRAP"
if [[ -z "$RUN_TOKEN" ]]; then
  RUN_TOKEN="$(generate_run_token)"
fi
assert_safe_word run-token "$RUN_TOKEN" 63

if [[ -z "$KEY_PATH" ]]; then
  KEY_PATH="$(ensure_cached_avb_testkey)"
fi

pixel_prepare_dirs
if [[ -z "$OUTPUT_IMAGE" ]]; then
  OUTPUT_IMAGE="$(default_output_image)"
fi
mkdir -p "$(dirname "$OUTPUT_IMAGE")"
WORK_DIR="$(bootimg_prepare_work_dir shadow-pixel-boot-orange-init)"
assert_input_matches_stock_boot
assert_stock_root_init_shape

if [[ -z "$HELLO_INIT_BINARY" ]]; then
  HELLO_INIT_BINARY="$(default_hello_init_binary)"
  "$SCRIPT_DIR/pixel/pixel_build_hello_init.sh" --output "$HELLO_INIT_BINARY"
fi

[[ -f "$HELLO_INIT_BINARY" ]] || {
  echo "pixel_boot_build_orange_init: hello-init binary not found: $HELLO_INIT_BINARY" >&2
  exit 1
}

if [[ -z "$ORANGE_INIT_BINARY" ]]; then
  ORANGE_INIT_BINARY="$(default_orange_init_binary)"
  "$SCRIPT_DIR/pixel/pixel_build_orange_init.sh" --output "$ORANGE_INIT_BINARY"
fi

[[ -f "$ORANGE_INIT_BINARY" ]] || {
  echo "pixel_boot_build_orange_init: orange-init binary not found: $ORANGE_INIT_BINARY" >&2
  exit 1
}

assert_hello_variant "$HELLO_INIT_BINARY"
assert_orange_variant "$ORANGE_INIT_BINARY"

CONFIG_PATH="$WORK_DIR/$CONFIG_ENTRY"
render_config "$CONFIG_PATH"

build_args=(
  --stock-init
  --input "$INPUT_IMAGE"
  --key "$KEY_PATH"
  --output "$OUTPUT_IMAGE"
  --replace "system/bin/init=$HELLO_INIT_BINARY"
  --add "$CONFIG_ENTRY=$CONFIG_PATH"
  --add "$PAYLOAD_ENTRY=$ORANGE_INIT_BINARY"
)

if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  build_args+=(--keep-work-dir)
fi

"$SCRIPT_DIR/pixel/pixel_boot_build.sh" "${build_args[@]}"
write_metadata

printf 'Owned userspace mode: orange-init\n'
printf 'Root init path: preserve stock /init -> /system/bin/init symlink\n'
printf 'System init mutation: replace system/bin/init with hello-init PID 1\n'
printf 'Payload contract: hello-init executes /orange-init when payload=orange-init\n'
printf 'Payload path: /%s\n' "$PAYLOAD_ENTRY"
printf 'Config path: /%s\n' "$CONFIG_ENTRY"
printf 'Hold seconds: %s\n' "$HOLD_SECS"
printf 'Reboot target: %s\n' "$REBOOT_TARGET"
printf 'Run token: %s\n' "$RUN_TOKEN"
printf 'Dev mount style: %s\n' "$DEV_MOUNT"
printf 'Mount /dev: %s\n' "$MOUNT_DEV"
printf 'Mount proc: %s\n' "$MOUNT_PROC"
printf 'Mount sys: %s\n' "$MOUNT_SYS"
printf 'Log kmsg: %s\n' "$LOG_KMSG"
printf 'Log pmsg: %s\n' "$LOG_PMSG"
printf 'DRI bootstrap: %s\n' "$DRI_BOOTSTRAP"
printf 'Metadata path: %s\n' "$(hello_init_metadata_path "$OUTPUT_IMAGE")"
if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  printf 'Kept orange-init workdir: %s\n' "$WORK_DIR"
fi
