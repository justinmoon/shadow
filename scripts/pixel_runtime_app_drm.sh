#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

"$SCRIPT_DIR/pixel_build.sh"
"$SCRIPT_DIR/pixel_build_blitz_demo.sh"
"$SCRIPT_DIR/pixel_prepare_runtime_app_artifacts.sh"

: "${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS:=12000}"
: "${PIXEL_GUEST_SESSION_TIMEOUT_SECS:=20}"
extra_guest_env="${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}"
extra_session_env="${PIXEL_RUNTIME_APP_EXTRA_SESSION_ENV-}"
extra_required_markers="${PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS-}"
touch_signal_path="$(pixel_runtime_dir)/touch-signal"

runtime_guest_env=$(
  cat <<EOF
SHADOW_BLITZ_DEMO_MODE=runtime
SHADOW_BLITZ_RUNTIME_EXIT_DELAY_MS=$PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS
SHADOW_BLITZ_RAW_POINTER_FALLBACK=1
SHADOW_BLITZ_TOUCH_ANYWHERE_TARGET=counter
SHADOW_BLITZ_TOUCH_ACTIVATE_ON_DOWN=1
SHADOW_BLITZ_TOUCH_SIGNAL_PATH=$touch_signal_path
SHADOW_BLITZ_DEBUG_OVERLAY=0
SHADOW_RUNTIME_APP_BUNDLE_PATH=$(pixel_runtime_app_bundle_dst)
SHADOW_RUNTIME_HOST_BINARY_PATH=$(pixel_runtime_host_launcher_dst)
EOF
)
if [[ -n "$extra_guest_env" ]]; then
  runtime_guest_env="${runtime_guest_env}"$'\n'"${extra_guest_env}"
fi
runtime_guest_env="$(printf '%s\n' "$runtime_guest_env" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"

runtime_session_env=$(
  cat <<EOF
SHADOW_GUEST_TOUCH_SIGNAL_PATH=$touch_signal_path
EOF
)
if [[ -n "$extra_session_env" ]]; then
  runtime_session_env="${runtime_session_env}"$'\n'"${extra_session_env}"
fi
runtime_session_env="$(printf '%s\n' "$runtime_session_env" | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"

required_markers='runtime-session-ready'
if [[ -n "$extra_required_markers" ]]; then
  required_markers="${required_markers}"$'\n'"${extra_required_markers}"
fi

PIXEL_GUEST_CLIENT_ARTIFACT="$(pixel_blitz_demo_artifact)" \
PIXEL_GUEST_CLIENT_DST="$(pixel_blitz_demo_dst)" \
PIXEL_RUNTIME_HOST_BUNDLE_ARTIFACT_DIR="$(pixel_runtime_host_bundle_artifact_dir)" \
PIXEL_RUNTIME_APP_BUNDLE_ARTIFACT="$(pixel_runtime_app_bundle_artifact)" \
PIXEL_COMPOSITOR_MARKER='[shadow-guest-compositor] presented-frame' \
PIXEL_CLIENT_MARKER='runtime-document-ready' \
PIXEL_GUEST_REQUIRED_MARKERS="$required_markers" \
PIXEL_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME='' \
PIXEL_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT=1 \
PIXEL_GUEST_CLIENT_EXIT_ON_CONFIGURE='' \
PIXEL_GUEST_SESSION_TIMEOUT_SECS="$PIXEL_GUEST_SESSION_TIMEOUT_SECS" \
PIXEL_GUEST_CLIENT_ENV="$runtime_guest_env" \
PIXEL_GUEST_SESSION_ENV="$runtime_session_env" \
  "$SCRIPT_DIR/pixel_guest_ui_drm.sh"
