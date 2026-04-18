#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
  cat <<'EOF'
usage: nightly.sh [--dry-run]

Run the broad validation lane:
  - just pre-commit
  - just smoke target=vm
  - just runtime-app-host-smokes (with the Linux URL smoke forced on)
  - just pixel-ci full
  - just pixel-ci cashu
  - scripts/ci/pixel_shell_keyboard_smoke.sh

Set PIXEL_SERIAL to target a specific rooted Pixel.
EOF
}

dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "nightly.sh: unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

run_step() {
  local label="$1"
  shift

  printf 'nightly: %s\n' "$label"
  if (( dry_run == 1 )); then
    printf 'nightly: command='
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

cd "$REPO_ROOT"

run_step "pre-commit" just pre-commit
run_step "vm smoke" just smoke target=vm
run_step "host runtime smokes" env SHADOW_RUNTIME_APP_HOST_INCLUDE_URL_SMOKE=1 just runtime-app-host-smokes
run_step "rooted Pixel full suite" just pixel-ci full
run_step "rooted Pixel cashu suite" just pixel-ci cashu
run_step "rooted Pixel keyboard smoke" "$SCRIPT_DIR/pixel_shell_keyboard_smoke.sh"
