#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"

set +e
su_id="$(pixel_root_id "$serial")"
su_status="$?"
set -e

if [[ "$su_status" -eq 0 ]]; then
  printf 'root: yes\n'
  printf 'su_user: %s\n' "$su_id"
  exit 0
fi

cat <<'EOF'
root: no

If the phone just booted a patched Magisk image, open the Magisk app once.
If Magisk asks for additional setup or environment fix, accept it and let it reboot.
Then run:
  sc -t pixel root-check
EOF
exit 1
