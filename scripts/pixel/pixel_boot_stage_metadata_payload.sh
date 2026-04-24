#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"

ORIGINAL_ARGS=("$@")
RUN_TOKEN="${PIXEL_HELLO_INIT_RUN_TOKEN:-${PIXEL_ORANGE_GPU_RUN_TOKEN:-}}"
PAYLOAD_VERSION="${PIXEL_BOOT_PAYLOAD_VERSION:-shadow-payload-probe-v1}"
PAYLOAD_LABEL="${PIXEL_BOOT_PAYLOAD_LABEL:-metadata-partition-probe}"
PAYLOAD_SOURCE="${PIXEL_BOOT_PAYLOAD_SOURCE:-metadata}"
PAYLOAD_ROOT="${PIXEL_BOOT_PAYLOAD_ROOT:-}"
MANIFEST_ROOT="${PIXEL_BOOT_PAYLOAD_MANIFEST_ROOT:-}"
OUTPUT_DIR="${PIXEL_BOOT_PAYLOAD_STAGE_DIR:-}"
SHADOW_LOGICAL_SIZE_MIB="${PIXEL_BOOT_SHADOW_LOGICAL_SIZE_MIB:-256}"
SETUP_SHADOW_LOGICAL=1
EXTRA_PAYLOAD_PATHS=()
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: scripts/pixel/pixel_boot_stage_metadata_payload.sh [--serial SERIAL]
                                                        [--run-token TOKEN]
                                                        [--version VERSION]
                                                        [--label LABEL]
                                                        [--source SOURCE]
                                                        [--payload-root PATH]
                                                        [--manifest-root PATH]
                                                        [--shadow-logical-size-mib N]
                                                        [--skip-shadow-logical-setup]
                                                        [--extra-payload PATH[:REMOTE_NAME]]
                                                        [--output-dir DIR]
                                                        [--dry-run]

Stage a Shadow-owned payload probe before booting a payload-partition-probe
image. By default both the control manifest and payload marker live under:
  /metadata/shadow-payload/by-token/<run-token>/

Use --payload-root /data/local/tmp/shadow-payload/by-token/<run-token> with
--manifest-root /metadata/shadow-payload/by-token/<run-token> to prove a large
userdata-backed payload root while keeping /metadata as the control plane.

Use --source shadow-logical-partition to create, format, mount, and stage a
Shadow-owned dynamic logical partition named shadow_payload_<slot>. That lane
uses /shadow-payload as both the payload root and manifest root.

Optional --extra-payload entries copy real payload files or directories under
the same payload root for capacity/handoff proofing. PID1 validates the marker
payload today; extra payloads are staged and listed in extra-payloads.tsv.
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
    /metadata/shadow-payload/by-token/*|/data/local/tmp/shadow-payload/by-token/*|/shadow-payload)
      ;;
    *)
      echo "pixel_boot_stage_metadata_payload: payload root must stay under /metadata/shadow-payload/by-token, /data/local/tmp/shadow-payload/by-token, or be /shadow-payload: $value" >&2
      exit 1
      ;;
  esac
  if [[ "$value" == *"'"* || "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *" "* ]]; then
    echo "pixel_boot_stage_metadata_payload: payload root contains unsupported characters: $value" >&2
    exit 1
  fi
}

assert_manifest_root() {
  local value
  value="${1:?assert_manifest_root requires a value}"
  case "$value" in
    /metadata/shadow-payload/by-token/*|/shadow-payload)
      ;;
    *)
      echo "pixel_boot_stage_metadata_payload: manifest root must stay under /metadata/shadow-payload/by-token or be /shadow-payload: $value" >&2
      exit 1
      ;;
  esac
  if [[ "$value" == *"'"* || "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *" "* ]]; then
    echo "pixel_boot_stage_metadata_payload: payload root contains unsupported characters: $value" >&2
    exit 1
  fi
}

assert_relative_payload_name() {
  local value
  value="${1:?assert_relative_payload_name requires a value}"
  case "$value" in
    ""|/*|.*|*"/.."*|*".."*|*"'"*|*$'\n'*|*$'\r'*|*" "*)
      echo "pixel_boot_stage_metadata_payload: unsupported extra payload remote name: $value" >&2
      exit 1
      ;;
  esac
}

assert_positive_integer() {
  local label value
  label="${1:?assert_positive_integer requires a label}"
  value="${2:?assert_positive_integer requires a value}"
  if [[ ! "$value" =~ ^[0-9]+$ || "$value" -lt 1 ]]; then
    echo "pixel_boot_stage_metadata_payload: unsupported $label: $value" >&2
    exit 1
  fi
}

device_slot_suffix() {
  local serial slot
  serial="${1:?device_slot_suffix requires a serial}"
  slot="$(pixel_adb "$serial" shell getprop ro.boot.slot_suffix | tr -d '\r\n')"
  if [[ -z "$slot" ]]; then
    slot="$(pixel_adb "$serial" shell getprop ro.boot.slot | tr -d '\r\n')"
    case "$slot" in
      a|b)
        slot="_$slot"
        ;;
    esac
  fi
  case "$slot" in
    _a|_b)
      printf '%s\n' "$slot"
      ;;
    *)
      echo "pixel_boot_stage_metadata_payload: unable to determine active slot suffix for $serial: $slot" >&2
      return 1
      ;;
  esac
}

stage_shadow_logical_partition() {
  local serial slot_suffix partition_name size_bytes remote_tmp
  serial="${1:?stage_shadow_logical_partition requires a serial}"
  remote_tmp="${2:?stage_shadow_logical_partition requires remote tmp}"
  slot_suffix="$(device_slot_suffix "$serial")"
  partition_name="shadow_payload$slot_suffix"
  size_bytes=$((SHADOW_LOGICAL_SIZE_MIB * 1024 * 1024))

  printf 'Preparing Shadow logical payload partition: %s (%s MiB)\n' "$partition_name" "$SHADOW_LOGICAL_SIZE_MIB" >&2
  pixel_adb "$serial" reboot fastboot >/dev/null
  pixel_wait_for_fastboot "$serial" 90
  pixel_fastboot "$serial" delete-logical-partition "$partition_name" >/dev/null 2>&1 || true
  pixel_fastboot "$serial" create-logical-partition "$partition_name" "$size_bytes" >/dev/null
  pixel_fastboot "$serial" reboot >/dev/null
  pixel_wait_for_adb "$serial" 180
  pixel_wait_for_boot_completed "$serial" 240

  pixel_root_shell "$serial" "
set -eu
partition_name='$partition_name'
block='/dev/block/mapper/'\"\$partition_name\"
for _ in \$(seq 1 30); do
  [ -b \"\$block\" ] && break
  sleep 1
done
[ -b \"\$block\" ]
if command -v mke2fs >/dev/null 2>&1; then
  mke2fs -t ext4 -F \"\$block\" >/dev/null
elif command -v mkfs.ext4 >/dev/null 2>&1; then
  mkfs.ext4 -F \"\$block\" >/dev/null
else
  echo 'missing mke2fs or mkfs.ext4' >&2
  exit 1
fi
mkdir -p /mnt/shadow_payload
umount /mnt/shadow_payload >/dev/null 2>&1 || true
mount -t ext4 \"\$block\" /mnt/shadow_payload
rm -rf /mnt/shadow_payload/*
cp '$remote_tmp/manifest.env' /mnt/shadow_payload/manifest.env
cp '$remote_tmp/payload.txt' /mnt/shadow_payload/payload.txt
cp '$remote_tmp/extra-payloads.tsv' /mnt/shadow_payload/extra-payloads.tsv
if [ -d '$remote_tmp/extra-payloads' ]; then
  mkdir -p /mnt/shadow_payload/extra-payloads
  cp -R '$remote_tmp/extra-payloads'/. /mnt/shadow_payload/extra-payloads/
fi
chmod 0644 /mnt/shadow_payload/manifest.env /mnt/shadow_payload/payload.txt /mnt/shadow_payload/extra-payloads.tsv
sync
umount /mnt/shadow_payload
" >/dev/null

  printf '%s\n' "$partition_name"
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
    --source)
      PAYLOAD_SOURCE="${2:?missing value for --source}"
      shift 2
      ;;
    --payload-root)
      PAYLOAD_ROOT="${2:?missing value for --payload-root}"
      shift 2
      ;;
    --manifest-root)
      MANIFEST_ROOT="${2:?missing value for --manifest-root}"
      shift 2
      ;;
    --shadow-logical-size-mib)
      SHADOW_LOGICAL_SIZE_MIB="${2:?missing value for --shadow-logical-size-mib}"
      shift 2
      ;;
    --skip-shadow-logical-setup)
      SETUP_SHADOW_LOGICAL=0
      shift
      ;;
    --extra-payload)
      EXTRA_PAYLOAD_PATHS+=("${2:?missing value for --extra-payload}")
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
assert_safe_token source "$PAYLOAD_SOURCE"
assert_positive_integer shadow-logical-size-mib "$SHADOW_LOGICAL_SIZE_MIB"

case "$PAYLOAD_SOURCE" in
  metadata)
    ;;
  shadow-logical-partition)
    if [[ -z "$PAYLOAD_ROOT" ]]; then
      PAYLOAD_ROOT="/shadow-payload"
    fi
    if [[ -z "$MANIFEST_ROOT" ]]; then
      MANIFEST_ROOT="/shadow-payload"
    fi
    ;;
  *)
    echo "pixel_boot_stage_metadata_payload: unsupported source: $PAYLOAD_SOURCE" >&2
    exit 1
    ;;
esac

if [[ -z "$PAYLOAD_ROOT" ]]; then
  PAYLOAD_ROOT="/metadata/shadow-payload/by-token/$RUN_TOKEN"
fi
assert_payload_root "$PAYLOAD_ROOT"
if [[ -z "$MANIFEST_ROOT" ]]; then
  MANIFEST_ROOT="$PAYLOAD_ROOT"
fi
assert_manifest_root "$MANIFEST_ROOT"

if [[ "$PAYLOAD_SOURCE" == "shadow-logical-partition" ]]; then
  if [[ "$PAYLOAD_ROOT" != "/shadow-payload" || "$MANIFEST_ROOT" != "/shadow-payload" ]]; then
    echo "pixel_boot_stage_metadata_payload: shadow-logical-partition requires --payload-root /shadow-payload and --manifest-root /shadow-payload" >&2
    exit 1
  fi
elif [[ "$PAYLOAD_ROOT" == "/shadow-payload" || "$MANIFEST_ROOT" == "/shadow-payload" ]]; then
  echo "pixel_boot_stage_metadata_payload: /shadow-payload requires --source shadow-logical-partition" >&2
  exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-metadata-payload.XXXXXX")"
else
  mkdir -p "$OUTPUT_DIR"
fi

PAYLOAD_TEXT_PATH="$OUTPUT_DIR/payload.txt"
MANIFEST_PATH="$OUTPUT_DIR/manifest.env"
EXTRA_DIR="$OUTPUT_DIR/extra-payloads"
EXTRA_MANIFEST_PATH="$OUTPUT_DIR/extra-payloads.tsv"

{
  printf 'shadow_payload_probe=1\n'
  printf 'run_token=%s\n' "$RUN_TOKEN"
  printf 'label=%s\n' "$PAYLOAD_LABEL"
  printf 'version=%s\n' "$PAYLOAD_VERSION"
} >"$PAYLOAD_TEXT_PATH"

PAYLOAD_FINGERPRINT="sha256:$(sha256_file "$PAYLOAD_TEXT_PATH")"
{
  printf 'schema=metadata-shadow-payload-v1\n'
  printf 'payload_source=%s\n' "$PAYLOAD_SOURCE"
  printf 'payload_version=%s\n' "$PAYLOAD_VERSION"
  printf 'payload_fingerprint=%s\n' "$PAYLOAD_FINGERPRINT"
  printf 'payload_root=%s\n' "$PAYLOAD_ROOT"
  printf 'payload_marker=payload.txt\n'
  printf 'run_token=%s\n' "$RUN_TOKEN"
  printf 'label=%s\n' "$PAYLOAD_LABEL"
} >"$MANIFEST_PATH"

mkdir -p "$EXTRA_DIR"
: >"$EXTRA_MANIFEST_PATH"
if [[ "${#EXTRA_PAYLOAD_PATHS[@]}" -gt 0 ]]; then
  for entry in "${EXTRA_PAYLOAD_PATHS[@]}"; do
    source_path="$entry"
    remote_name=""
    if [[ "$entry" == *:* ]]; then
      source_path="${entry%%:*}"
      remote_name="${entry#*:}"
    fi
    [[ -e "$source_path" ]] || {
      echo "pixel_boot_stage_metadata_payload: extra payload source not found: $source_path" >&2
      exit 1
    }
    if [[ -z "$remote_name" ]]; then
      remote_name="$(basename "$source_path")"
    fi
    assert_relative_payload_name "$remote_name"
    destination_path="$EXTRA_DIR/$remote_name"
    mkdir -p "$(dirname "$destination_path")"
    rm -rf "$destination_path"
    if [[ -d "$source_path" ]]; then
      mkdir -p "$destination_path"
      cp -R "$source_path"/. "$destination_path"/
    else
      cp "$source_path" "$destination_path"
    fi
    printf '%s\t%s\t%s\n' "$remote_name" "$(sha256_file "$destination_path" 2>/dev/null || printf 'directory')" "$source_path" >>"$EXTRA_MANIFEST_PATH"
  done
fi

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'Dry run: true\n'
  printf 'Run token: %s\n' "$RUN_TOKEN"
  printf 'Payload root: %s\n' "$PAYLOAD_ROOT"
  printf 'Manifest root: %s\n' "$MANIFEST_ROOT"
  printf 'Payload version: %s\n' "$PAYLOAD_VERSION"
  printf 'Payload source: %s\n' "$PAYLOAD_SOURCE"
  printf 'Shadow logical setup: %s\n' "$SETUP_SHADOW_LOGICAL"
  printf 'Shadow logical size MiB: %s\n' "$SHADOW_LOGICAL_SIZE_MIB"
  printf 'Payload fingerprint: %s\n' "$PAYLOAD_FINGERPRINT"
  printf 'Manifest: %s\n' "$MANIFEST_PATH"
  printf 'Payload marker: %s\n' "$PAYLOAD_TEXT_PATH"
  printf 'Extra payload manifest: %s\n' "$EXTRA_MANIFEST_PATH"
  exit 0
fi

serial="$(pixel_resolve_serial)"
pixel_require_host_lock "$serial" "$0" "${ORIGINAL_ARGS[@]}"
root_id="$(pixel_root_id "$serial" 2>/dev/null || true)"
if [[ -z "$root_id" ]]; then
  echo "pixel_boot_stage_metadata_payload: root shell unavailable on $serial" >&2
  exit 1
fi

REMOTE_TMP="/data/local/tmp/shadow-metadata-payload-$RUN_TOKEN"
pixel_adb "$serial" shell "rm -rf '$REMOTE_TMP' && mkdir -p '$REMOTE_TMP'" >/dev/null
pixel_adb "$serial" push "$MANIFEST_PATH" "$REMOTE_TMP/manifest.env" >/dev/null
pixel_adb "$serial" push "$PAYLOAD_TEXT_PATH" "$REMOTE_TMP/payload.txt" >/dev/null
pixel_adb "$serial" push "$EXTRA_MANIFEST_PATH" "$REMOTE_TMP/extra-payloads.tsv" >/dev/null
if [[ -n "$(find "$EXTRA_DIR" -mindepth 1 -print -quit)" ]]; then
  pixel_adb "$serial" push "$EXTRA_DIR" "$REMOTE_TMP/extra-payloads" >/dev/null
fi

shadow_logical_partition=""
if [[ "$PAYLOAD_SOURCE" == "shadow-logical-partition" && "$SETUP_SHADOW_LOGICAL" == "1" ]]; then
  shadow_logical_partition="$(stage_shadow_logical_partition "$serial" "$REMOTE_TMP")"
elif [[ "$PAYLOAD_SOURCE" == "shadow-logical-partition" ]]; then
  shadow_logical_partition="shadow_payload$(device_slot_suffix "$serial")"
  pixel_root_shell "$serial" "
set -eu
block='/dev/block/mapper/$shadow_logical_partition'
[ -b \"\$block\" ]
mkdir -p /mnt/shadow_payload
umount /mnt/shadow_payload >/dev/null 2>&1 || true
mount -t ext4 \"\$block\" /mnt/shadow_payload
rm -rf /mnt/shadow_payload/*
cp '$REMOTE_TMP/manifest.env' /mnt/shadow_payload/manifest.env
cp '$REMOTE_TMP/payload.txt' /mnt/shadow_payload/payload.txt
cp '$REMOTE_TMP/extra-payloads.tsv' /mnt/shadow_payload/extra-payloads.tsv
if [ -d '$REMOTE_TMP/extra-payloads' ]; then
  mkdir -p /mnt/shadow_payload/extra-payloads
  cp -R '$REMOTE_TMP/extra-payloads'/. /mnt/shadow_payload/extra-payloads/
fi
chmod 0644 /mnt/shadow_payload/manifest.env /mnt/shadow_payload/payload.txt /mnt/shadow_payload/extra-payloads.tsv
sync
umount /mnt/shadow_payload
" >/dev/null
else
  pixel_root_shell "$serial" "
set -eu
test -d /metadata
mkdir -p '$MANIFEST_ROOT' '$PAYLOAD_ROOT'
cp '$REMOTE_TMP/manifest.env' '$MANIFEST_ROOT/manifest.env'
cp '$REMOTE_TMP/payload.txt' '$PAYLOAD_ROOT/payload.txt'
cp '$REMOTE_TMP/extra-payloads.tsv' '$MANIFEST_ROOT/extra-payloads.tsv'
if [ -d '$REMOTE_TMP/extra-payloads' ]; then
  rm -rf '$PAYLOAD_ROOT/extra-payloads'
  mkdir -p '$PAYLOAD_ROOT/extra-payloads'
  cp -R '$REMOTE_TMP/extra-payloads'/. '$PAYLOAD_ROOT/extra-payloads'/
fi
chmod 0644 '$MANIFEST_ROOT/manifest.env' '$PAYLOAD_ROOT/payload.txt' '$MANIFEST_ROOT/extra-payloads.tsv'
sync
" >/dev/null
fi

printf 'Serial: %s\n' "$serial"
printf 'Root id: %s\n' "$root_id"
printf 'Run token: %s\n' "$RUN_TOKEN"
printf 'Payload root: %s\n' "$PAYLOAD_ROOT"
printf 'Manifest root: %s\n' "$MANIFEST_ROOT"
printf 'Payload version: %s\n' "$PAYLOAD_VERSION"
printf 'Payload source: %s\n' "$PAYLOAD_SOURCE"
if [[ -n "$shadow_logical_partition" ]]; then
  printf 'Shadow logical partition: %s\n' "$shadow_logical_partition"
  printf 'Shadow logical size MiB: %s\n' "$SHADOW_LOGICAL_SIZE_MIB"
fi
printf 'Payload fingerprint: %s\n' "$PAYLOAD_FINGERPRINT"
printf 'Manifest: %s\n' "$MANIFEST_PATH"
printf 'Payload marker: %s\n' "$PAYLOAD_TEXT_PATH"
printf 'Extra payload manifest: %s\n' "$EXTRA_MANIFEST_PATH"
printf 'Remote payload root: %s\n' "$PAYLOAD_ROOT"
printf 'Remote manifest root: %s\n' "$MANIFEST_ROOT"
