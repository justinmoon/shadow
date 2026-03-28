#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

INPUT_IMAGE="${INIT_BOOT_SRC:-$(cached_init_boot_image)}"
KEY_PATH="${AVB_TEST_KEY_PATH:-$(cached_avb_testkey)}"
OUTPUT_IMAGE="${INIT_BOOT_OUT:-$(build_dir)/init_boot.repacked.img}"
WORK_DIR=""

usage() {
  cat <<'EOF'
Usage: scripts/init_boot_repack.sh [--input PATH] [--key PATH] [--output PATH]

Rebuild init_boot.img without modifying its ramdisk contents.
EOF
}

cleanup() {
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
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
    --output)
      OUTPUT_IMAGE="${2:?missing value for --output}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "init_boot_repack: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$INPUT_IMAGE" || ! -f "$KEY_PATH" ]]; then
  "$SCRIPT_DIR/artifacts_fetch.sh"
fi

[[ -f "$INPUT_IMAGE" ]] || {
  echo "init_boot_repack: input image not found: $INPUT_IMAGE" >&2
  exit 1
}
[[ -f "$KEY_PATH" ]] || {
  echo "init_boot_repack: AVB key not found: $KEY_PATH" >&2
  exit 1
}

mkdir -p "$(dirname "$OUTPUT_IMAGE")"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-init-boot-XXXXXX")"
trap cleanup EXIT

LOCAL_INPUT="${WORK_DIR}/init_boot.img"
LOCAL_KEY="${WORK_DIR}/avb_testkey_rsa4096.pem"
LOCAL_OUTPUT="${WORK_DIR}/init_boot.repacked.img"

cp "$INPUT_IMAGE" "$LOCAL_INPUT"
cp "$KEY_PATH" "$LOCAL_KEY"

printf 'Repacking %s locally\n' "$INPUT_IMAGE"
printf '  workdir: %s\n' "$WORK_DIR"

LOCAL_SCRIPT="$(cat <<EOF
set -euo pipefail
cd "$WORK_DIR"
unpack_bootimg --boot_img "$LOCAL_INPUT" --format=mkbootimg > mkbootimg_args.txt
filtered_args=\$(sed 's|--output [^ ]*||g' mkbootimg_args.txt)
eval "set -- \$filtered_args"
mkbootimg "\$@" --output "$LOCAL_OUTPUT"
info="\$(avbtool info_image --image "$LOCAL_INPUT")"
partition_size="\$(python3 - <<'PY'
import pathlib
print(pathlib.Path("$LOCAL_INPUT").stat().st_size)
PY
)"
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
  --image "$LOCAL_OUTPUT" \
  --partition_size "\$partition_size" \
  --partition_name init_boot \
  --hash_algorithm "\$hash_algorithm" \
  --salt "\$salt" \
  --algorithm "\$algorithm" \
  --key "$LOCAL_KEY" \
  --rollback_index "\$rollback_index" \
  --rollback_index_location "\$rollback_index_location" \
  --flags "\$flags" \
  "\${prop_args[@]}"
avbtool info_image --image "$LOCAL_OUTPUT" > repacked.avb.info
EOF
)"

bash -lc "$LOCAL_SCRIPT"
cp "$LOCAL_OUTPUT" "$OUTPUT_IMAGE"

printf 'Wrote repacked image: %s\n' "$OUTPUT_IMAGE"
