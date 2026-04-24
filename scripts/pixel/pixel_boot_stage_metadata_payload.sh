#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"

RUN_TOKEN="${PIXEL_HELLO_INIT_RUN_TOKEN:-${PIXEL_ORANGE_GPU_RUN_TOKEN:-}}"
PAYLOAD_VERSION="${PIXEL_BOOT_PAYLOAD_VERSION:-shadow-payload-probe-v1}"
PAYLOAD_LABEL="${PIXEL_BOOT_PAYLOAD_LABEL:-metadata-partition-probe}"
PAYLOAD_ROOT="${PIXEL_BOOT_PAYLOAD_ROOT:-}"
OUTPUT_DIR="${PIXEL_BOOT_PAYLOAD_STAGE_DIR:-}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_stage_metadata_payload.sh [--serial SERIAL]
                                                        [--run-token TOKEN]
                                                        [--version VERSION]
                                                        [--label LABEL]
                                                        [--payload-root PATH]
                                                        [--output-dir DIR]
                                                        [--dry-run]

Stage the smallest Shadow-owned payload probe under /metadata before booting a
payload-partition-probe image. The boot image expects:
  /metadata/shadow-payload/by-token/<run-token>/manifest.env
EOF
}

sha256_file() {
  local path
  path="${1:?sha256_file requires a path}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{ print $1 }'
  else
    shasum -a 256 "$path" | awk '{ print $1 }'
  fi
}

assert_safe_token() {
  local label value
  label="${1:?assert_safe_token requires a label}"
  value="${2:?assert_safe_token requires a value}"
  if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "pixel_boot_stage_metadata_payload: unsupported $label: $value" >&2
    exit 1
  fi
}

assert_payload_root() {
  local value
  value="${1:?assert_payload_root requires a value}"
  case "$value" in
    /metadata/shadow-payload/by-token/*)
      ;;
    *)
      echo "pixel_boot_stage_metadata_payload: payload root must stay under /metadata/shadow-payload/by-token: $value" >&2
      exit 1
      ;;
  esac
  if [[ "$value" == *"'"* || "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *" "* ]]; then
    echo "pixel_boot_stage_metadata_payload: payload root contains unsupported characters: $value" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)
      PIXEL_SERIAL="${2:?missing value for --serial}"
      shift 2
      ;;
    --run-token)
      RUN_TOKEN="${2:?missing value for --run-token}"
      shift 2
      ;;
    --version)
      PAYLOAD_VERSION="${2:?missing value for --version}"
      shift 2
      ;;
    --label)
      PAYLOAD_LABEL="${2:?missing value for --label}"
      shift 2
      ;;
    --payload-root)
      PAYLOAD_ROOT="${2:?missing value for --payload-root}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:?missing value for --output-dir}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "pixel_boot_stage_metadata_payload: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$RUN_TOKEN" ]]; then
  echo "pixel_boot_stage_metadata_payload: --run-token or PIXEL_HELLO_INIT_RUN_TOKEN is required" >&2
  exit 1
fi
assert_safe_token run-token "$RUN_TOKEN"
assert_safe_token version "$PAYLOAD_VERSION"
assert_safe_token label "$PAYLOAD_LABEL"

if [[ -z "$PAYLOAD_ROOT" ]]; then
  PAYLOAD_ROOT="/metadata/shadow-payload/by-token/$RUN_TOKEN"
fi
assert_payload_root "$PAYLOAD_ROOT"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-metadata-payload.XXXXXX")"
else
  mkdir -p "$OUTPUT_DIR"
fi

PAYLOAD_TEXT_PATH="$OUTPUT_DIR/payload.txt"
MANIFEST_PATH="$OUTPUT_DIR/manifest.env"

{
  printf 'shadow_payload_probe=1\n'
  printf 'run_token=%s\n' "$RUN_TOKEN"
  printf 'label=%s\n' "$PAYLOAD_LABEL"
  printf 'version=%s\n' "$PAYLOAD_VERSION"
} >"$PAYLOAD_TEXT_PATH"

PAYLOAD_FINGERPRINT="sha256:$(sha256_file "$PAYLOAD_TEXT_PATH")"
{
  printf 'schema=metadata-shadow-payload-v1\n'
  printf 'payload_source=metadata\n'
  printf 'payload_version=%s\n' "$PAYLOAD_VERSION"
  printf 'payload_fingerprint=%s\n' "$PAYLOAD_FINGERPRINT"
  printf 'payload_root=%s\n' "$PAYLOAD_ROOT"
  printf 'payload_marker=payload.txt\n'
  printf 'run_token=%s\n' "$RUN_TOKEN"
  printf 'label=%s\n' "$PAYLOAD_LABEL"
} >"$MANIFEST_PATH"

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'Dry run: true\n'
  printf 'Run token: %s\n' "$RUN_TOKEN"
  printf 'Payload root: %s\n' "$PAYLOAD_ROOT"
  printf 'Payload version: %s\n' "$PAYLOAD_VERSION"
  printf 'Payload fingerprint: %s\n' "$PAYLOAD_FINGERPRINT"
  printf 'Manifest: %s\n' "$MANIFEST_PATH"
  printf 'Payload marker: %s\n' "$PAYLOAD_TEXT_PATH"
  exit 0
fi

serial="$(pixel_resolve_serial)"
root_id="$(pixel_root_id "$serial" 2>/dev/null || true)"
if [[ -z "$root_id" ]]; then
  echo "pixel_boot_stage_metadata_payload: root shell unavailable on $serial" >&2
  exit 1
fi

REMOTE_TMP="/data/local/tmp/shadow-metadata-payload-$RUN_TOKEN"
pixel_adb "$serial" shell "rm -rf '$REMOTE_TMP' && mkdir -p '$REMOTE_TMP'" >/dev/null
pixel_adb "$serial" push "$MANIFEST_PATH" "$REMOTE_TMP/manifest.env" >/dev/null
pixel_adb "$serial" push "$PAYLOAD_TEXT_PATH" "$REMOTE_TMP/payload.txt" >/dev/null

pixel_root_shell "$serial" "
set -eu
test -d /metadata
mkdir -p '$PAYLOAD_ROOT'
cp '$REMOTE_TMP/manifest.env' '$PAYLOAD_ROOT/manifest.env'
cp '$REMOTE_TMP/payload.txt' '$PAYLOAD_ROOT/payload.txt'
chmod 0644 '$PAYLOAD_ROOT/manifest.env' '$PAYLOAD_ROOT/payload.txt'
sync
" >/dev/null

printf 'Serial: %s\n' "$serial"
printf 'Root id: %s\n' "$root_id"
printf 'Run token: %s\n' "$RUN_TOKEN"
printf 'Payload root: %s\n' "$PAYLOAD_ROOT"
printf 'Payload version: %s\n' "$PAYLOAD_VERSION"
printf 'Payload fingerprint: %s\n' "$PAYLOAD_FINGERPRINT"
printf 'Manifest: %s\n' "$MANIFEST_PATH"
printf 'Payload marker: %s\n' "$PAYLOAD_TEXT_PATH"
printf 'Remote payload root: %s\n' "$PAYLOAD_ROOT"
