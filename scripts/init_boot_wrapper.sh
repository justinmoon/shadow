#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

INPUT_IMAGE="${INIT_BOOT_SRC:-$(cached_init_boot_image)}"
KEY_PATH="${AVB_TEST_KEY_PATH:-$(cached_avb_testkey)}"
DEFAULT_WRAPPER_BINARY="$(build_dir)/init-wrapper"
WRAPPER_BINARY="${INIT_WRAPPER_BIN:-$DEFAULT_WRAPPER_BINARY}"
OUTPUT_IMAGE="${INIT_BOOT_OUT:-$(build_dir)/init_boot.wrapper.img}"
REMOTE_TMP=""
declare -a EXTRA_BIN_SPECS=()
declare -a EXTRA_BIN_REMOTE_SPECS=()
WRAPPER_BINARY_OVERRIDDEN=0

if [[ -n "${INIT_WRAPPER_BIN:-}" ]]; then
  WRAPPER_BINARY_OVERRIDDEN=1
fi

usage() {
  cat <<'EOF'
Usage: scripts/init_boot_wrapper.sh [--input PATH] [--key PATH] [--wrapper PATH] [--output PATH] [--extra-bin GUEST=HOST]
       scripts/init_boot_wrapper.sh [--extra-bin-remote GUEST=REMOTE_PATH]

Rebuild init_boot.img with a Rust /init wrapper that chainloads /init.stock.
EOF
}

cleanup() {
  if [[ -n "$REMOTE_TMP" ]]; then
    remote_shell "rm -rf $(printf '%q' "$REMOTE_TMP")" >/dev/null 2>&1 || true
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)
      INPUT_IMAGE="${2:?missing value for --input}"
      shift 2
      ;;
    --key)
      KEY_PATH="${2:?missing value for --key}"
      shift 2
      ;;
    --wrapper)
      WRAPPER_BINARY="${2:?missing value for --wrapper}"
      WRAPPER_BINARY_OVERRIDDEN=1
      shift 2
      ;;
    --output)
      OUTPUT_IMAGE="${2:?missing value for --output}"
      shift 2
      ;;
    --extra-bin)
      EXTRA_BIN_SPECS+=("${2:?missing value for --extra-bin}")
      shift 2
      ;;
    --extra-bin-remote)
      EXTRA_BIN_REMOTE_SPECS+=("${2:?missing value for --extra-bin-remote}")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "init_boot_wrapper: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$INPUT_IMAGE" || ! -f "$KEY_PATH" ]]; then
  "$SCRIPT_DIR/artifacts_fetch.sh"
fi

if (( WRAPPER_BINARY_OVERRIDDEN == 0 )); then
  "$SCRIPT_DIR/build_init_wrapper.sh"
fi

[[ -f "$INPUT_IMAGE" ]] || {
  echo "init_boot_wrapper: input image not found: $INPUT_IMAGE" >&2
  exit 1
}
[[ -f "$KEY_PATH" ]] || {
  echo "init_boot_wrapper: AVB key not found: $KEY_PATH" >&2
  exit 1
}
[[ -f "$WRAPPER_BINARY" ]] || {
  echo "init_boot_wrapper: wrapper binary not found: $WRAPPER_BINARY" >&2
  exit 1
}

mkdir -p "$(dirname "$OUTPUT_IMAGE")"

REMOTE_TMP="$(remote_shell 'mktemp -d "${TMPDIR:-/tmp}/shadow-init-boot-wrapper-XXXXXX"')"
trap cleanup EXIT

REMOTE_INPUT="${REMOTE_TMP}/init_boot.img"
REMOTE_KEY="${REMOTE_TMP}/avb_testkey_rsa4096.pem"
REMOTE_WRAPPER="${REMOTE_TMP}/init-wrapper"
REMOTE_CPIO_EDIT="${REMOTE_TMP}/cpio_edit.py"
REMOTE_OUTPUT="${REMOTE_TMP}/init_boot.wrapper.img"
declare -a REMOTE_EXTRA_ARGS=()
declare -a REMOTE_EXEC_PATHS=()
declare -a REMOTE_EXISTENCE_PATHS=()

copy_to_remote "$INPUT_IMAGE" "$REMOTE_INPUT"
copy_to_remote "$KEY_PATH" "$REMOTE_KEY"
copy_to_remote "$WRAPPER_BINARY" "$REMOTE_WRAPPER"
copy_to_remote "$SCRIPT_DIR/cpio_edit.py" "$REMOTE_CPIO_EDIT"

for spec in "${EXTRA_BIN_SPECS[@]}"; do
  guest_path="${spec%%=*}"
  archive_path="${guest_path#/}"
  host_path="${spec#*=}"
  if [[ -z "$guest_path" || -z "$archive_path" || -z "$host_path" || "$guest_path" == "$host_path" ]]; then
    echo "init_boot_wrapper: expected --extra-bin guest-path=host-path, got: $spec" >&2
    exit 1
  fi
  if [[ ! -f "$host_path" ]]; then
    echo "init_boot_wrapper: extra binary not found: $host_path" >&2
    exit 1
  fi

  remote_name="$(basename "$guest_path")"
  remote_extra="${REMOTE_TMP}/${remote_name}"
  copy_to_remote "$host_path" "$remote_extra"
  REMOTE_EXTRA_ARGS+=("--add" "${archive_path}=${remote_extra}")
  REMOTE_EXEC_PATHS+=("$remote_extra")
  REMOTE_EXISTENCE_PATHS+=("$remote_extra")
done

for spec in "${EXTRA_BIN_REMOTE_SPECS[@]}"; do
  guest_path="${spec%%=*}"
  archive_path="${guest_path#/}"
  remote_path="${spec#*=}"
  if [[ -z "$guest_path" || -z "$archive_path" || -z "$remote_path" || "$guest_path" == "$remote_path" ]]; then
    echo "init_boot_wrapper: expected --extra-bin-remote guest-path=remote-path, got: $spec" >&2
    exit 1
  fi
  REMOTE_EXTRA_ARGS+=("--add" "${archive_path}=${remote_path}")
  REMOTE_EXISTENCE_PATHS+=("$remote_path")
done

printf 'Repacking %s with Rust init wrapper on %s\n' "$INPUT_IMAGE" "$REMOTE_HOST"
printf '  wrapper: %s\n' "$WRAPPER_BINARY"
printf '  remote workdir: %s\n' "$REMOTE_TMP"
for spec in "${EXTRA_BIN_SPECS[@]}"; do
  printf '  extra: %s\n' "$spec"
done
for spec in "${EXTRA_BIN_REMOTE_SPECS[@]}"; do
  printf '  extra-remote: %s\n' "$spec"
done

extra_add_args=()
for value in "${REMOTE_EXTRA_ARGS[@]}"; do
  extra_add_args+=("$(printf '%q' "$value")")
done
extra_add_args_joined="${extra_add_args[*]}"

remote_exec_args=()
for value in "${REMOTE_EXEC_PATHS[@]}"; do
  remote_exec_args+=("$(printf '%q' "$value")")
done
remote_exec_args_joined="${remote_exec_args[*]}"

remote_extra_paths=()
for value in "${REMOTE_EXISTENCE_PATHS[@]}"; do
  remote_extra_paths+=("$(printf '%q' "$value")")
done
remote_extra_paths_joined="${remote_extra_paths[*]}"

REMOTE_SCRIPT="$(cat <<EOF
set -euo pipefail
cd "$REMOTE_TMP"
chmod 0755 "$REMOTE_WRAPPER" "$REMOTE_CPIO_EDIT"
for path in ${remote_exec_args_joined}; do
  if [[ -n "\$path" && -f "\$path" ]]; then
    chmod 0755 "\$path"
  fi
done
for path in ${remote_extra_paths_joined}; do
  if [[ -n "\$path" && ! -f "\$path" ]]; then
    echo "init_boot_wrapper: remote extra binary not found: \$path" >&2
    exit 1
  fi
done
unpack_bootimg --boot_img "$REMOTE_INPUT" --format=mkbootimg > mkbootimg_args.txt

case "\$(file -b out/ramdisk)" in
  *LZ4*)
    lz4 -d out/ramdisk ramdisk.cpio
    ;;
  *gzip*)
    gzip -dc out/ramdisk > ramdisk.cpio
    ;;
  *)
    cp out/ramdisk ramdisk.cpio
    ;;
esac

python3 "$REMOTE_CPIO_EDIT" \
  --input ramdisk.cpio \
  --output ramdisk.modified.cpio \
  --rename init=init.stock \
  --add init="$REMOTE_WRAPPER" \
  ${extra_add_args_joined}

lz4 -l -9 ramdisk.modified.cpio ramdisk.modified

filtered_args=\$(sed 's|--ramdisk [^ ]*|--ramdisk ramdisk.modified|g; s|--output [^ ]*||g' mkbootimg_args.txt)
eval "set -- \$filtered_args"
mkbootimg "\$@" --output "$REMOTE_OUTPUT"

info="\$(avbtool info_image --image "$REMOTE_INPUT")"
partition_size="\$(stat -c %s "$REMOTE_INPUT")"
algorithm="\$(printf '%s\n' "\$info" | awk -F': *' '/^Algorithm:/{print \$2; exit}')"
rollback_index="\$(printf '%s\n' "\$info" | awk -F': *' '/^Rollback Index:/{print \$2; exit}')"
rollback_index_location="\$(printf '%s\n' "\$info" | awk -F': *' '/^Rollback Index Location:/{print \$2; exit}')"
hash_algorithm="\$(printf '%s\n' "\$info" | awk -F': *' '/^[[:space:]]+Hash Algorithm:/{print \$2; exit}')"
salt="\$(printf '%s\n' "\$info" | awk -F': *' '/^[[:space:]]+Salt:/{print \$2; exit}')"
flags="\$(printf '%s\n' "\$info" | awk -F': *' '/^Flags:/{print \$2; exit}')"

prop_args=()
while IFS= read -r prop_line; do
  key="\$(printf '%s\n' "\$prop_line" | sed -E "s/^[[:space:]]*Prop: ([^ ]+) -> '.*$/\\1/")"
  value="\$(printf '%s\n' "\$prop_line" | sed -E "s/^[[:space:]]*Prop: [^ ]+ -> '(.*)'$/\\1/")"
  prop_args+=("--prop" "\${key}:\${value}")
done < <(printf '%s\n' "\$info" | grep -E '^[[:space:]]+Prop: ')

avbtool add_hash_footer \
  --image "$REMOTE_OUTPUT" \
  --partition_size "\$partition_size" \
  --partition_name init_boot \
  --hash_algorithm "\$hash_algorithm" \
  --salt "\$salt" \
  --algorithm "\$algorithm" \
  --key "$REMOTE_KEY" \
  --rollback_index "\$rollback_index" \
  --rollback_index_location "\$rollback_index_location" \
  --flags "\$flags" \
  "\${prop_args[@]}"
EOF
)"

remote_nix_bash "$REMOTE_SCRIPT"

if is_local_host; then
  cp "$REMOTE_OUTPUT" "$OUTPUT_IMAGE"
else
  scp -q "${REMOTE_HOST}:${REMOTE_OUTPUT}" "$OUTPUT_IMAGE"
fi

printf 'Wrote wrapper image: %s\n' "$OUTPUT_IMAGE"
