#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

host_system="$(nix eval --impure --raw --expr builtins.currentSystem)"

suite_attr() {
  case "$1" in
    all) printf '%s\n' "uiCheck" ;;
    fmt) printf '%s\n' "uiCheckFmt" ;;
    core) printf '%s\n' "uiCheckCore" ;;
    apps) printf '%s\n' "uiCheckApps" ;;
    blitz-demo) printf '%s\n' "uiCheckBlitzDemo" ;;
    compositor) printf '%s\n' "uiCheckCompositor" ;;
    *) return 1 ;;
  esac
}

seen_attr() {
  local needle="$1"
  local existing
  for existing in "${check_attrs[@]:-}"; do
    if [[ "$existing" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

usage() {
  cat <<'EOF'
Usage: scripts/ui_check.sh [suite...]

Suites:
  all          Aggregate UI check suite (default)
  fmt          UI formatting
  core         shadow-ui-core tests
  apps         Rust demo and timeline compile checks
  blitz-demo   Blitz demo tests and compile checks
  compositor   Compositor guest tests and compositor compile checks

Use --list-suites to print the available suite names.
EOF
}

if (($# == 0)); then
  set -- all
fi

declare -a check_attrs=()

for suite in "$@"; do
  case "$suite" in
    --help|-h)
      usage
      exit 0
      ;;
    --list-suites)
      printf '%s\n' all fmt core apps blitz-demo compositor
      exit 0
      ;;
  esac

  if ! attr="$(suite_attr "$suite")"; then
    printf 'scripts/ui_check.sh: unknown suite %q\n' "$suite" >&2
    usage >&2
    exit 2
  fi
  if seen_attr ".#checks.${host_system}.${attr}"; then
    continue
  fi
  check_attrs+=(".#checks.${host_system}.${attr}")
done

nix build --accept-flake-config --no-link -L "${check_attrs[@]}"
