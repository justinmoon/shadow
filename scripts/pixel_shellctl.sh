#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
json=0

usage() {
  cat <<'EOF' >&2
usage: pixel_shellctl.sh {state [--json]|home|switcher|open <app>|tap <x> <y>}
EOF
  exit 1
}

request=''
case "${1-}" in
  state)
    if [[ "$#" -eq 2 && "${2-}" == "--json" ]]; then
      json=1
    elif [[ "$#" -ne 1 ]]; then
      usage
    fi
    request='state'
    ;;
  home)
    [[ "$#" -eq 1 ]] || usage
    request='home'
    ;;
  switcher)
    [[ "$#" -eq 1 ]] || usage
    request='switcher'
    ;;
  open)
    [[ "$#" -eq 2 ]] || usage
    request="launch $2"
    ;;
  tap)
    [[ "$#" -eq 3 ]] || usage
    request="tap $2 $3"
    ;;
  *)
    usage
    ;;
esac

if [[ "$request" == "state" && "$json" == "1" ]]; then
  response="$(pixel_shell_control_request "$serial" "$request")"
  CONTROL_STATE_RAW="$response" python3 - <<'PY'
import json
import os

state = {}
for line in os.environ["CONTROL_STATE_RAW"].splitlines():
    if "=" not in line:
        continue
    key, value = line.split("=", 1)
    state[key] = value

print(
    json.dumps(
        {
            "focused": state.get("focused") or None,
            "mapped": [item for item in state.get("mapped", "").split(",") if item],
            "launched": [item for item in state.get("launched", "").split(",") if item],
            "shelved": [item for item in state.get("shelved", "").split(",") if item],
            "windows": int(state.get("windows", "0")),
            "transport": state.get("transport") or None,
            "control_socket": state.get("control_socket") or None,
        },
        indent=2,
        sort_keys=True,
    )
)
PY
  exit 0
fi

pixel_shell_control_request "$serial" "$request"
