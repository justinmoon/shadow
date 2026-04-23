#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./bootimg_common.sh
source "$SCRIPT_DIR/lib/bootimg_common.sh"
ensure_bootimg_shell "$@"

INPUT_IMAGE="${PIXEL_BOOT_INPUT_IMAGE:-}"
KEY_PATH="${AVB_TEST_KEY_PATH:-}"
OUTPUT_IMAGE="${PIXEL_BOOT_CMDLINE_PROBE_IMAGE:-}"
KEEP_WORK_DIR=0
declare -a TOKENS=()
declare -a ANDROIDBOOT_ASSIGNMENTS=()

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_build_cmdline_probe.sh [--input PATH] [--key PATH] [--output PATH]
                                                       [--androidboot KEY=VALUE]
                                                       [--token TOKEN]
                                                       [--keep-work-dir]

Build a private stock-init sunfish boot.img that leaves the ramdisk unchanged and
appends one or more boot header cmdline tokens. `--androidboot KEY=VALUE` expands
to `androidboot.KEY=VALUE`, which later surfaces as `ro.boot.KEY=VALUE`.
EOF
}

default_output_image() {
  printf '%s/shadow-boot-cmdline-probe.img\n' "$(pixel_boot_dir)"
}

validate_androidboot_assignment() {
  local assignment key value
  assignment="${1:?validate_androidboot_assignment requires an assignment}"

  [[ "$assignment" == *=* ]] || {
    echo "pixel_boot_build_cmdline_probe: --androidboot must use KEY=VALUE" >&2
    exit 1
  }

  key="${assignment%%=*}"
  value="${assignment#*=}"

  [[ -n "$key" && -n "$value" ]] || {
    echo "pixel_boot_build_cmdline_probe: --androidboot requires a non-empty key and value" >&2
    exit 1
  }
  [[ "$key" =~ ^[A-Za-z0-9_.-]+$ ]] || {
    echo "pixel_boot_build_cmdline_probe: --androidboot key contains unsupported characters: $key" >&2
    exit 1
  }
  [[ "$value" =~ ^[A-Za-z0-9._:/+=,@-]+$ ]] || {
    echo "pixel_boot_build_cmdline_probe: --androidboot value contains unsupported characters: $value" >&2
    exit 1
  }
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
    --androidboot)
      ANDROIDBOOT_ASSIGNMENTS+=("${2:?missing value for --androidboot}")
      shift 2
      ;;
    --token)
      TOKENS+=("${2:?missing value for --token}")
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
      echo "pixel_boot_build_cmdline_probe: unknown argument: $1" >&2
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
pixel_boot_build_cmdline_probe: input image not found: $INPUT_IMAGE

Run 'sc root-prep' first to cache the stock sunfish boot.img.
EOF
  exit 1
}

if [[ -z "$KEY_PATH" ]]; then
  KEY_PATH="$(ensure_cached_avb_testkey)"
fi

if [[ -z "$OUTPUT_IMAGE" ]]; then
  OUTPUT_IMAGE="$(default_output_image)"
fi

if ((${#ANDROIDBOOT_ASSIGNMENTS[@]} == 0 && ${#TOKENS[@]} == 0)); then
  ANDROIDBOOT_ASSIGNMENTS=("shadow_probe=cmdline-probe")
fi

if ((${#ANDROIDBOOT_ASSIGNMENTS[@]})); then
  for assignment in "${ANDROIDBOOT_ASSIGNMENTS[@]}"; do
    validate_androidboot_assignment "$assignment"
    TOKENS+=("androidboot.$assignment")
  done
fi

build_args=(
  --stock-init
  --input "$INPUT_IMAGE"
  --key "$KEY_PATH"
  --output "$OUTPUT_IMAGE"
)

for token in "${TOKENS[@]}"; do
  build_args+=(--append-cmdline "$token")
done

if [[ "$KEEP_WORK_DIR" == "1" ]]; then
  build_args+=(--keep-work-dir)
fi

"$SCRIPT_DIR/pixel/pixel_boot_build.sh" "${build_args[@]}"

printf 'Probe mode: cmdline\n'
for token in "${TOKENS[@]}"; do
  printf 'Cmdline token: %s\n' "$token"
done
