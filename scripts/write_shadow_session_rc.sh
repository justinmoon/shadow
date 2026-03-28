#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

MODE="${SHADOW_SESSION_MODE:-}"
OUTPUT_PATH="${SHADOW_SESSION_RC_OUT:-}"
TRIGGER="${SHADOW_SESSION_TRIGGER:-property:sys.boot_completed=1}"
declare -a SETENV_SPECS=()

usage() {
  cat <<'EOF'
Usage: scripts/write_shadow_session_rc.sh --mode MODE --output PATH [--trigger EXPR] [--setenv KEY=VALUE]

Write an Android init rc fragment that starts /shadow-session in the requested mode.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:?missing value for --mode}"
      shift 2
      ;;
    --output)
      OUTPUT_PATH="${2:?missing value for --output}"
      shift 2
      ;;
    --trigger)
      TRIGGER="${2:?missing value for --trigger}"
      shift 2
      ;;
    --setenv)
      SETENV_SPECS+=("${2:?missing value for --setenv}")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "write_shadow_session_rc: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$MODE" || -z "$OUTPUT_PATH" ]]; then
  usage >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

setenv_lines=""
for spec in "${SETENV_SPECS[@]}"; do
  key="${spec%%=*}"
  value="${spec#*=}"
  if [[ -z "$key" || -z "$value" || "$key" == "$value" ]]; then
    echo "write_shadow_session_rc: expected --setenv KEY=VALUE, got: $spec" >&2
    exit 1
  fi
  setenv_lines+="    setenv ${key} ${value}"$'\n'
done

printf '%s\n' \
  "on ${TRIGGER}" \
  "    start shadow-session" \
  "" \
  "service shadow-session /shadow-session" \
  "    class late_start" \
  "    user root" \
  "    group root system graphics input shell" \
  "    seclabel u:r:init:s0" \
  "    disabled" \
  "    oneshot" \
  "    setenv SHADOW_SESSION_MODE ${MODE}" \
  "${setenv_lines%$'\n'}" \
  >"$OUTPUT_PATH"

printf 'Wrote shadow session rc: %s\n' "$OUTPUT_PATH"
