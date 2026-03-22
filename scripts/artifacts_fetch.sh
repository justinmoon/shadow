#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

FORCE=0

usage() {
  cat <<'EOF'
Usage: scripts/artifacts_fetch.sh [--force]

Fetch and cache the stock Cuttlefish boot artifacts locally.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "artifacts_fetch: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

mkdir -p "$(stock_images_dir)" "$(keys_dir)" "$(build_dir)"

fetch_remote_file() {
  local remote_path local_path
  remote_path="$1"
  local_path="$2"
  if [[ "$FORCE" == "0" && -f "$local_path" ]]; then
    printf 'Using cached %s\n' "$local_path"
    return
  fi
  printf 'Fetching %s -> %s\n' "$remote_path" "$local_path"
  if is_local_host; then
    cp "$remote_path" "$local_path"
  else
    scp -q "${REMOTE_HOST}:${remote_path}" "$local_path"
  fi
}

fetch_remote_file "/var/lib/cuttlefish/images/boot.img" "$(cached_boot_image)"
fetch_remote_file "/var/lib/cuttlefish/images/init_boot.img" "$(cached_init_boot_image)"

if [[ "$FORCE" == "1" || ! -f "$(cached_avb_testkey)" ]]; then
  printf 'Fetching official AVB test key -> %s\n' "$(cached_avb_testkey)"
  python3 - "$(cached_avb_testkey)" "$GOOGLESOURCE_AVB_TESTKEY_URL" <<'PY'
import base64
import pathlib
import sys
import urllib.request

out_path = pathlib.Path(sys.argv[1])
url = sys.argv[2]
raw = urllib.request.urlopen(url).read()
decoded = base64.b64decode(raw)
if not decoded.startswith(b"-----BEGIN RSA PRIVATE KEY-----"):
    raise SystemExit("downloaded AVB key did not look like a PEM private key")
out_path.write_bytes(decoded)
PY
  chmod 600 "$(cached_avb_testkey)"
else
  printf 'Using cached %s\n' "$(cached_avb_testkey)"
fi

printf 'Cached boot image: %s\n' "$(cached_boot_image)"
printf 'Cached init_boot image: %s\n' "$(cached_init_boot_image)"
printf 'Cached AVB key: %s\n' "$(cached_avb_testkey)"
