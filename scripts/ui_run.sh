#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

target="${1:-desktop}"
app="${2:-timeline}"
hold="${3:-1}"

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

resolve_target

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
  if [[ "$app" != "timeline" ]]; then
    echo "ui-run: target=pixel currently supports only app=timeline" >&2
    exit 1
  fi

  echo "ui-run: target=pixel currently launches the runtime timeline app, not the full home shell" >&2

  if [[ "$hold" == "1" ]]; then
    exec "$SCRIPT_DIR/pixel_runtime_app_nostr_timeline_drm_hold.sh"
  fi

  exec "$SCRIPT_DIR/pixel_runtime_app_nostr_timeline_drm.sh"
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
