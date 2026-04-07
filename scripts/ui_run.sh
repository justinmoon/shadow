#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

target="desktop"
app="timeline"
hold="1"

parse_args() {
  local positional=()
  local arg
  local target_set=0
  local app_set=0
  local hold_set=0

  target="desktop"
  app="timeline"
  hold="1"

  for arg in "$@"; do
    case "$arg" in
      target=*)
        target="${arg#target=}"
        target_set=1
        ;;
      app=*)
        app="${arg#app=}"
        app_set=1
        ;;
      hold=*)
        hold="${arg#hold=}"
        hold_set=1
        ;;
      *)
        positional+=("$arg")
        ;;
    esac
  done

  for arg in "${positional[@]}"; do
    if (( !target_set )); then
      target="$arg"
      target_set=1
      continue
    fi
    if (( !app_set )); then
      app="$arg"
      app_set=1
      continue
    fi
    if (( !hold_set )); then
      hold="$arg"
      hold_set=1
      continue
    fi
  done
}

resolve_target() {
  case "$target" in
    desktop|vm|pixel)
      ;;
    *)
      export PIXEL_SERIAL="$target"
      target="pixel"
      ;;
  esac
}

parse_args "$@"
resolve_target

exec_or_echo() {
  local command="$1"
  shift || true
  local env_assignment

  if [[ -n "${SHADOW_UI_RUN_ECHO_EXEC-}" ]]; then
    for env_assignment in "$@"; do
      printf 'env=%s\n' "$env_assignment"
    done
    printf 'command=%s\n' "$command"
    return 0
  fi

  if [[ "$#" -gt 0 ]]; then
    exec env "$@" "$command"
  fi

  exec "$command"
}

run_desktop() {
  cd "$REPO_ROOT"
  nix develop .#ui -c cargo run --manifest-path ui/Cargo.toml -p shadow-ui-desktop
}

run_vm() {
  if [[ "$app" != "timeline" ]]; then
    echo "ui-run: target=vm ignores app=$app; the full shell decides what to show" >&2
  fi
  exec "$SCRIPT_DIR/ui_vm_run.sh"
}

run_pixel() {
  local -a shell_env=()

  case "$app" in
    shell)
      echo "ui-run: target=pixel launches the full home shell" >&2
      ;;
    timeline)
      echo "ui-run: target=pixel launches the full home shell and asks it to open timeline" >&2
      shell_env=("PIXEL_SHELL_START_APP_ID=timeline")
      ;;
    *)
      echo "ui-run: target=pixel currently supports app=shell or app=timeline" >&2
      exit 1
      ;;
  esac

  if [[ "$hold" == "1" ]]; then
    exec_or_echo "$SCRIPT_DIR/pixel_shell_drm_hold.sh" "${shell_env[@]}"
    return 0
  fi

  exec_or_echo "$SCRIPT_DIR/pixel_shell_drm.sh" "${shell_env[@]}"
}

case "$target" in
  desktop)
    run_desktop
    ;;
  vm)
    run_vm
    ;;
  pixel)
    run_pixel
    ;;
  *)
    echo "ui-run: unsupported target '$target'" >&2
    exit 1
    ;;
esac
