#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

FOLLOW=0
KIND="${CF_LOG_KIND:-all}"
LINES="${CF_LOG_LINES:-120}"
INSTANCE="$(active_instance_name)"

usage() {
  cat <<'EOF'
Usage: scripts/cf_logs.sh [--follow] [--kind launcher|kernel|console|all] [--lines N]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --follow)
      FOLLOW=1
      shift
      ;;
    --kind)
      KIND="${2:?missing value for --kind}"
      shift 2
      ;;
    --lines)
      LINES="${2:?missing value for --lines}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "cf_logs: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$INSTANCE" ]]; then
  echo "cf_logs: no recorded instance" >&2
  exit 1
fi

remote_bash <<EOF
set -euo pipefail
instance="$INSTANCE"
kind="$KIND"
lines="$LINES"
follow="$FOLLOW"
launcher_log="$(launcher_log_path "$INSTANCE")"
kernel_log="$(kernel_log_path "$INSTANCE")"
kernel_log_fallback="$(kernel_log_fallback_path "$INSTANCE")"
console_log="$(console_log_path "$INSTANCE")"
print_one() {
  local label="\$1"
  local path="\$2"
  if [[ ! -f "\$path" ]]; then
    echo "==== \$label (\$path missing) ===="
    return
  fi
  echo "==== \$label (\$path) ===="
  if [[ "\$follow" == "1" ]]; then
    exec sudo tail -n "\$lines" -F "\$path"
  else
    sudo tail -n "\$lines" "\$path"
  fi
}
if [[ "\$kind" == "launcher" ]]; then
  print_one launcher "\$launcher_log"
  exit 0
fi
if [[ "\$kind" == "kernel" ]]; then
  if [[ -f "\$kernel_log" ]]; then
    print_one kernel "\$kernel_log"
  else
    print_one kernel "\$kernel_log_fallback"
  fi
  exit 0
fi
if [[ "\$kind" == "console" ]]; then
  print_one console "\$console_log"
  exit 0
fi
print_one launcher "\$launcher_log"
echo
if [[ -f "\$kernel_log" ]]; then
  print_one kernel "\$kernel_log"
else
  print_one kernel "\$kernel_log_fallback"
fi
echo
print_one console "\$console_log"
EOF
