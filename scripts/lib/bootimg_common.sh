BOOTIMG_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shadow_common.sh
source "$BOOTIMG_COMMON_DIR/shadow_common.sh"

bootimg_file_size_bytes() {
  python3 - "$1" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).stat().st_size)
PY
}

bootimg_prepare_work_dir() {
  local prefix
  prefix="${1:-shadow-bootimg}"
  mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX"
}

bootimg_unpack_to_dir() {
  local input_image output_dir
  input_image="$1"
  output_dir="$2"
  input_image="$(
    python3 - "$input_image" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).resolve())
PY
  )"

  mkdir -p "$output_dir"
  (
    cd "$output_dir"
    unpack_bootimg --boot_img "$input_image" --format=mkbootimg >mkbootimg_args.txt
  )
}

bootimg_detect_ramdisk_compression() {
  case "$(file -b "$1" 2>/dev/null)" in
    *LZ4*)
      printf 'lz4\n'
      ;;
    *gzip*)
      printf 'gzip\n'
      ;;
    *)
      printf 'none\n'
      ;;
  esac
}

bootimg_decompress_ramdisk() {
  local input_ramdisk output_cpio compression
  input_ramdisk="$1"
  output_cpio="$2"
  compression="$(bootimg_detect_ramdisk_compression "$input_ramdisk")"

  case "$compression" in
    lz4)
      lz4 -d "$input_ramdisk" "$output_cpio" >/dev/null
      ;;
    gzip)
      gzip -dc "$input_ramdisk" >"$output_cpio"
      ;;
    none)
      cp "$input_ramdisk" "$output_cpio"
      ;;
    *)
      echo "bootimg: unsupported ramdisk compression: $compression" >&2
      return 1
      ;;
  esac

  printf '%s\n' "$compression"
}

bootimg_compress_ramdisk() {
  local compression input_cpio output_ramdisk
  compression="$1"
  input_cpio="$2"
  output_ramdisk="$3"

  case "$compression" in
    lz4)
      lz4 -l -9 "$input_cpio" "$output_ramdisk" >/dev/null
      ;;
    gzip)
      gzip -n -9 -c "$input_cpio" >"$output_ramdisk"
      ;;
    none)
      cp "$input_cpio" "$output_ramdisk"
      ;;
    *)
      echo "bootimg: unsupported ramdisk compression: $compression" >&2
      return 1
      ;;
  esac
}

bootimg_repack_from_args_file() {
  local args_file ramdisk_path output_image filtered_args
  args_file="$1"
  ramdisk_path="$2"
  output_image="$3"
  filtered_args="$(sed "s|--ramdisk [^ ]*|--ramdisk $ramdisk_path|g; s|--output [^ ]*||g" "$args_file")"
  eval "set -- $filtered_args"
  mkbootimg "$@" --output "$output_image"
}

bootimg_reapply_avb_footer() {
  local source_image output_image key_path partition_name info partition_size
  local algorithm rollback_index rollback_index_location hash_algorithm salt flags
  local prop_line key value
  local -a prop_args
  source_image="$1"
  output_image="$2"
  key_path="$3"
  partition_name="$4"

  if ! info="$(avbtool info_image --image "$source_image" 2>/dev/null)"; then
    return 0
  fi
  if [[ ! -f "$key_path" ]]; then
    echo "bootimg: AVB key not found: $key_path" >&2
    return 1
  fi

  partition_size="$(bootimg_file_size_bytes "$source_image")"
  algorithm="$(printf '%s\n' "$info" | awk -F': *' '/^Algorithm:/{print $2; exit}')"
  rollback_index="$(printf '%s\n' "$info" | awk -F': *' '/^Rollback Index:/{print $2; exit}')"
  rollback_index_location="$(printf '%s\n' "$info" | awk -F': *' '/^Rollback Index Location:/{print $2; exit}')"
  hash_algorithm="$(printf '%s\n' "$info" | awk -F': *' '/^[[:space:]]+Hash Algorithm:/{print $2; exit}')"
  salt="$(printf '%s\n' "$info" | awk -F': *' '/^[[:space:]]+Salt:/{print $2; exit}')"
  flags="$(printf '%s\n' "$info" | awk -F': *' '/^Flags:/{print $2; exit}')"

  prop_args=()
  while IFS= read -r prop_line; do
    [[ -n "$prop_line" ]] || continue
    key="$(printf '%s\n' "$prop_line" | sed -E "s/^[[:space:]]*Prop: ([^ ]+) -> '.*$/\\1/")"
    value="$(printf '%s\n' "$prop_line" | sed -E "s/^[[:space:]]*Prop: [^ ]+ -> '(.*)'$/\\1/")"
    prop_args+=("--prop" "${key}:${value}")
  done < <(printf '%s\n' "$info" | grep -E '^[[:space:]]+Prop: ' || true)

  avbtool add_hash_footer \
    --image "$output_image" \
    --partition_size "$partition_size" \
    --partition_name "$partition_name" \
    --hash_algorithm "$hash_algorithm" \
    --salt "$salt" \
    --algorithm "$algorithm" \
    --key "$key_path" \
    --rollback_index "$rollback_index" \
    --rollback_index_location "$rollback_index_location" \
    --flags "$flags" \
    "${prop_args[@]}"
}
