#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

target="desktop"
app="podcast"
hold="1"

parse_args() {
  local positional=()
  local arg
  local target_set=0
  local app_set=0
  local hold_set=0

  target="desktop"
  app="podcast"
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
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "ui-run: target=desktop uses the VM on $(uname -s) because the desktop compositor host is Linux-only" >&2
    run_vm
    return 0
  fi

  local runtime_env_tmp=""
  local -a compositor_env=()

  case "$app" in
    shell)
      ;;
    counter|timeline|podcast|cashu)
      compositor_env=(
        "SHADOW_COMPOSITOR_AUTO_LAUNCH=1"
        "SHADOW_COMPOSITOR_START_APP_ID=$app"
      )
      ;;
    *)
      echo "ui-run: target=desktop currently supports app=shell, app=counter, app=timeline, app=podcast, or app=cashu" >&2
      exit 1
      ;;
  esac

  if [[ -n "${SHADOW_UI_RUN_ECHO_EXEC-}" ]]; then
    local env_assignment
    for env_assignment in "${compositor_env[@]}"; do
      printf 'env=%s\n' "$env_assignment"
    done
    printf 'command=nix develop .#ui -c cargo run --manifest-path ui/Cargo.toml -p shadow-compositor\n'
    return 0
  fi

  cd "$REPO_ROOT"
  runtime_env_tmp="$(mktemp "${TMPDIR:-/tmp}/shadow-ui-run-runtime-env.XXXXXX")"
  trap 'rm -f "$runtime_env_tmp"' RETURN
  SHADOW_RUNTIME_ENABLE_PODCAST_APP=1 \
    "$SCRIPT_DIR/runtime_prepare_host_session_env.sh" >"$runtime_env_tmp"
  # shellcheck source=/dev/null
  source "$runtime_env_tmp"

  if [[ "${#compositor_env[@]}" -gt 0 ]]; then
    exec env "${compositor_env[@]}" \
      nix develop .#ui -c cargo run --manifest-path ui/Cargo.toml -p shadow-compositor
  fi

  exec nix develop .#ui -c cargo run --manifest-path ui/Cargo.toml -p shadow-compositor
}

run_vm() {
  case "$app" in
    shell)
      echo "ui-run: target=vm launches the full shell session" >&2
      exec_or_echo "$SCRIPT_DIR/ui_vm_run.sh"
      return 0
      ;;
    counter|timeline|podcast|cashu)
      echo "ui-run: target=vm auto-opens app=$app through the guest shell session" >&2
      exec_or_echo "$SCRIPT_DIR/ui_vm_run.sh" "SHADOW_UI_VM_START_APP_ID=$app"
      return 0
      ;;
    *)
      echo "ui-run: target=vm currently supports app=shell, app=counter, app=timeline, app=podcast, or app=cashu" >&2
      exit 1
      ;;
  esac
}

run_pixel() {
  local -a shell_env=()

  case "$app" in
    shell)
      echo "ui-run: target=pixel launches the full home shell" >&2
      ;;
    counter|timeline|podcast|cashu)
      echo "ui-run: target=pixel launches the full home shell and asks it to open $app" >&2
      shell_env=("PIXEL_SHELL_START_APP_ID=$app")
      ;;
    *)
      echo "ui-run: target=pixel currently supports app=shell, app=counter, app=timeline, app=podcast, or app=cashu" >&2
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
