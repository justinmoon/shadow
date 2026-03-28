#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
# shellcheck source=./guest_ui_common.sh
source "$SCRIPT_DIR/guest_ui_common.sh"
ensure_bootimg_shell "$@"

OUTPUT_IMAGE="${INIT_BOOT_OUT:-$(build_dir)/init_boot.guest_ui.img}"
GUEST_UI_NAMESPACE="${SHADOW_GUEST_UI_NAMESPACE:-$(worktree_basename)-$$}"
SHADOW_SESSION_BIN="${SHADOW_SESSION_BIN:-$(build_dir)/shadow-session}"
SHADOW_SESSION_RC="${SHADOW_SESSION_RC:-$(build_dir)/init.shadow.guest-ui.${GUEST_UI_NAMESPACE}.rc}"
INIT_CUTF_CVM_RC="${INIT_CUTF_CVM_RC:-$(build_dir)/init.cutf_cvm.shadow.${GUEST_UI_NAMESPACE}.rc}"

if [[ -z "${INIT_BOOT_OUT:-}" ]]; then
  OUTPUT_IMAGE="$(build_dir)/init_boot.guest_ui.${GUEST_UI_NAMESPACE}.img"
fi

usage() {
  cat <<'EOF'
Usage: scripts/init_boot_guest_ui.sh [--output PATH]

Rebuild init_boot.img with the Rust /init wrapper plus the guest compositor and client payloads.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_IMAGE="${2:?missing value for --output}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "init_boot_guest_ui: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

main() {
  local compositor_bin counter_bin remote_dir

  if is_local_host; then
    if [[ "$(uname -s)" != "Linux" ]]; then
      echo "init_boot_guest_ui: local guest-ui build requires Linux; use a remote host such as hetzner" >&2
      exit 1
    fi

    compositor_bin="$(local_store_bin shadow-compositor-guest shadow-compositor-guest)"
    counter_bin="$(local_store_bin shadow-counter-guest shadow-counter-guest)"

    if [[ ! -f "$SHADOW_SESSION_BIN" ]]; then
      "$SCRIPT_DIR/build_shadow_session.sh"
    fi

    "$SCRIPT_DIR/write_shadow_session_rc.sh" \
      --mode guest-ui \
      --output "$SHADOW_SESSION_RC" \
      --setenv SHADOW_GUEST_COMPOSITOR_ENABLE_DRM=1 \
      --setenv SHADOW_GUEST_FRAME_PATH=/shadow-frame.ppm \
      --setenv RUST_LOG=shadow_compositor_guest=info,shadow_counter_guest=info,smithay=warn

    printf '%s\n' \
      'import /vendor/etc/init/hw/init.cutf_cvm.rc' \
      >"$INIT_CUTF_CVM_RC"
    printf '\n' >>"$INIT_CUTF_CVM_RC"
    cat "$SHADOW_SESSION_RC" >>"$INIT_CUTF_CVM_RC"

    "$SCRIPT_DIR/init_boot_wrapper.sh" \
      --output "$OUTPUT_IMAGE" \
      --extra-bin /shadow-session="$SHADOW_SESSION_BIN" \
      --extra-file /init.shadow.rc="$SHADOW_SESSION_RC" \
      --extra-file /init.cutf_cvm.rc="$INIT_CUTF_CVM_RC" \
      --extra-bin /shadow-compositor-guest="$compositor_bin" \
      --extra-bin /shadow-counter-guest="$counter_bin"
    return
  fi

  remote_dir="$(sync_remote_guest_ui_tree)"
  cleanup_remote_guest_ui_dir() {
    remote_shell "rm -rf $(printf '%q' "$remote_dir")"
  }
  trap cleanup_remote_guest_ui_dir RETURN
  compositor_bin="$(remote_store_bin "$remote_dir" shadow-compositor-guest shadow-compositor-guest)"
  counter_bin="$(remote_store_bin "$remote_dir" shadow-counter-guest shadow-counter-guest)"

  if [[ ! -f "$SHADOW_SESSION_BIN" ]]; then
    "$SCRIPT_DIR/build_shadow_session.sh"
  fi

  "$SCRIPT_DIR/write_shadow_session_rc.sh" \
    --mode guest-ui \
    --output "$SHADOW_SESSION_RC" \
    --setenv SHADOW_GUEST_COMPOSITOR_ENABLE_DRM=1 \
    --setenv SHADOW_GUEST_FRAME_PATH=/shadow-frame.ppm \
    --setenv RUST_LOG=shadow_compositor_guest=info,shadow_counter_guest=info,smithay=warn

  printf '%s\n' \
    'import /vendor/etc/init/hw/init.cutf_cvm.rc' \
    >"$INIT_CUTF_CVM_RC"
  printf '\n' >>"$INIT_CUTF_CVM_RC"
  cat "$SHADOW_SESSION_RC" >>"$INIT_CUTF_CVM_RC"

  "$SCRIPT_DIR/init_boot_wrapper.sh" \
    --output "$OUTPUT_IMAGE" \
    --extra-bin /shadow-session="$SHADOW_SESSION_BIN" \
    --extra-file /init.shadow.rc="$SHADOW_SESSION_RC" \
    --extra-file /init.cutf_cvm.rc="$INIT_CUTF_CVM_RC" \
    --extra-bin-remote /shadow-compositor-guest="$compositor_bin" \
    --extra-bin-remote /shadow-counter-guest="$counter_bin"
}

main "$@"
