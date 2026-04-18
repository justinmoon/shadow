#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"
pixel_require_host_lock "$serial" "$0" "$@"

if [[ -z "${PIXEL_VENDOR_TURNIP_LIB_PATH-}" && -z "${PIXEL_VENDOR_TURNIP_TARBALL-}" ]]; then
  PIXEL_VENDOR_TURNIP_LIB_PATH="$(pixel_ensure_pinned_turnip_lib)"
  export PIXEL_VENDOR_TURNIP_LIB_PATH
fi
# Pixel runtime app is GPU-only.
runtime_stage_only=0
runtime_run_only=0

if [[ -n "${PIXEL_RUNTIME_APP_PREP_ONLY-}" || -n "${PIXEL_RUNTIME_APP_PREPARE_ONLY-}" || -n "${PIXEL_RUNTIME_APP_STAGE_ONLY-}" ]]; then
  runtime_stage_only=1
fi
if [[ -n "${PIXEL_RUNTIME_APP_RUN_ONLY-}" ]]; then
  runtime_run_only=1
fi
if (( runtime_stage_only == 1 && runtime_run_only == 1 )); then
  echo "pixel_runtime_app_drm: PIXEL_RUNTIME_APP_RUN_ONLY cannot be combined with prep/stage-only mode" >&2
  exit 64
fi

if (( runtime_run_only == 0 )); then
  "$SCRIPT_DIR/pixel/pixel_build.sh"
fi

runtime_gpu_profile="${PIXEL_RUNTIME_APP_GPU_PROFILE-}"
runtime_gpu_bundle_mode="${PIXEL_BLITZ_GPU_BUNDLE_MODE-}"

if (( runtime_run_only == 0 )); then
  if [[ -z "$runtime_gpu_bundle_mode" ]]; then
    if [[ -n "$runtime_gpu_profile" ]]; then
      case "$runtime_gpu_profile" in
        vulkan*)
          runtime_gpu_bundle_mode="full"
          ;;
        *)
          runtime_gpu_bundle_mode="full"
          ;;
      esac
    else
      runtime_gpu_bundle_mode="full"
    fi
  fi
  PIXEL_BLITZ_GPU_BUNDLE_MODE="$runtime_gpu_bundle_mode" \
    "$SCRIPT_DIR/pixel/pixel_prepare_blitz_demo_gpu_bundle.sh"
fi
if [[ -z "$runtime_gpu_profile" ]]; then
  if [[ -n "${PIXEL_VENDOR_TURNIP_TARBALL-}" || -n "${PIXEL_VENDOR_TURNIP_LIB_PATH-}" ]]; then
    runtime_gpu_profile="vulkan_kgsl_first"
  else
    runtime_gpu_profile="gl"
  fi
fi

if (( runtime_run_only == 0 )); then
  "$SCRIPT_DIR/pixel/pixel_prepare_runtime_app_artifacts.sh"
fi

: "${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS:=12000}"
: "${PIXEL_GUEST_COMPOSITOR_MARKER_TIMEOUT_SECS:=45}"
: "${PIXEL_GUEST_FRAME_CHECKPOINT_TIMEOUT_SECS:=45}"
: "${PIXEL_GUEST_SESSION_TIMEOUT_SECS:=20}"
runtime_session_exit_timeout_secs="${PIXEL_GUEST_SESSION_EXIT_TIMEOUT_SECS-}"
if [[ -z "$runtime_session_exit_timeout_secs" ]]; then
  runtime_session_exit_timeout_secs="$(( (PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS + 999) / 1000 + 10 ))"
  if (( runtime_session_exit_timeout_secs < 20 )); then
    runtime_session_exit_timeout_secs=20
  fi
fi
extra_guest_env="${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}"
extra_session_env="${PIXEL_RUNTIME_APP_EXTRA_SESSION_ENV-}"
extra_required_markers="${PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS-}"
extra_forbidden_markers="${PIXEL_RUNTIME_APP_EXTRA_FORBIDDEN_MARKERS-}"
touch_signal_path="$(pixel_runtime_touch_signal_path)"
runtime_mesa_cache_dir="$(pixel_runtime_mesa_cache_dir)"
runtime_viewport_mode="${PIXEL_RUNTIME_APP_VIEWPORT_MODE-}"

if (( runtime_stage_only == 1 )); then
  PIXEL_RUNTIME_HOST_BUNDLE_ARTIFACT_DIR="$(pixel_runtime_host_bundle_artifact_dir)" \
  PIXEL_RUNTIME_APP_ASSET_ARTIFACT_DIR="$(pixel_runtime_app_asset_artifact_dir)" \
  PIXEL_RUNTIME_APP_BUNDLE_ARTIFACT="$(pixel_runtime_app_bundle_artifact)" \
    "$SCRIPT_DIR/pixel/pixel_push.sh"
  exit 0
fi

panel_size="${PIXEL_RUNTIME_APP_PANEL_SIZE-${PIXEL_PANEL_SIZE-}}"
if [[ -z "$panel_size" ]]; then
  panel_size="$(pixel_display_size "$serial" 2>/dev/null || true)"
fi
if [[ -z "$panel_size" ]]; then
  echo "pixel_runtime_app_drm: failed to determine display size; set PIXEL_RUNTIME_APP_PANEL_SIZE or PIXEL_PANEL_SIZE" >&2
  exit 1
fi
if [[ -z "$runtime_viewport_mode" ]]; then
  runtime_viewport_mode="panel"
fi

case "$runtime_viewport_mode" in
  fit)
    viewport_fit="$(python3 "$SCRIPT_DIR/runtime/runtime_viewport.py" --fit "$panel_size")"
    runtime_surface_width="$(printf '%s\n' "$viewport_fit" | awk -F= '/^fitted_width=/{print $2}')"
    runtime_surface_height="$(printf '%s\n' "$viewport_fit" | awk -F= '/^fitted_height=/{print $2}')"
    ;;
  panel)
    runtime_surface_width="${panel_size%x*}"
    runtime_surface_height="${panel_size#*x}"
    ;;
  *)
    echo "pixel_runtime_app_drm: unsupported PIXEL_RUNTIME_APP_VIEWPORT_MODE: $runtime_viewport_mode" >&2
    exit 1
    ;;
esac
if [[ -z "$runtime_surface_width" || -z "$runtime_surface_height" ]]; then
  echo "pixel_runtime_app_drm: failed to derive runtime viewport from $panel_size (mode=$runtime_viewport_mode)" >&2
  exit 1
fi

runtime_guest_env=$(
  cat <<EOF
SHADOW_BLITZ_SURFACE_WIDTH=$runtime_surface_width
SHADOW_BLITZ_SURFACE_HEIGHT=$runtime_surface_height
SHADOW_BLITZ_RUNTIME_EXIT_DELAY_MS=$PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS
SHADOW_BLITZ_RAW_POINTER_FALLBACK=1
SHADOW_BLITZ_TOUCH_ANYWHERE_TARGET=counter
SHADOW_BLITZ_TOUCH_ACTIVATE_ON_DOWN=1
SHADOW_BLITZ_TOUCH_SIGNAL_PATH=$touch_signal_path
SHADOW_BLITZ_TOUCH_SIGNAL_POLL_INTERVAL_MS=${SHADOW_BLITZ_TOUCH_SIGNAL_POLL_INTERVAL_MS:-16}
SHADOW_BLITZ_DEBUG_OVERLAY=0
SHADOW_BLITZ_UNDECORATED=1
SHADOW_BLITZ_ANDROID_FONTS=${SHADOW_BLITZ_ANDROID_FONTS:-curated}
SHADOW_BLITZ_SOFTWARE_KEYBOARD=${SHADOW_BLITZ_SOFTWARE_KEYBOARD:-1}
SHADOW_RUNTIME_APP_BUNDLE_PATH=$(pixel_runtime_app_bundle_dst)
$(pixel_runtime_host_env_lines)
$(pixel_runtime_linux_user_env_lines)
EOF
)
if [[ "${PIXEL_RUNTIME_ENABLE_GPU_SUMMARY:-0}" == "1" ]]; then
  runtime_guest_env="${runtime_guest_env}"$'\n'"SHADOW_BLITZ_GPU_SUMMARY=1"
fi
if [[ "$runtime_viewport_mode" == "panel" ]]; then
  runtime_guest_env="${runtime_guest_env}"$'\n'"SHADOW_BLITZ_IGNORE_SAFE_AREA=1"
fi
runtime_guest_env="${runtime_guest_env}"$'\n'"MESA_SHADER_CACHE_DIR=$runtime_mesa_cache_dir"
runtime_gpu_profile_env="$(pixel_runtime_gpu_profile_lines "$runtime_gpu_profile")" || {
  echo "pixel_runtime_app_drm: unsupported PIXEL_RUNTIME_APP_GPU_PROFILE: $runtime_gpu_profile" >&2
  exit 1
}
while IFS= read -r env_line; do
  [[ -n "$env_line" ]] || continue
  runtime_guest_env="${runtime_guest_env}"$'\n'"$env_line"
done < <(printf '%s\n' "$runtime_gpu_profile_env")
runtime_guest_env="${runtime_guest_env}"$'\n'"SHADOW_WGPU_PRESENT_MODE=${SHADOW_WGPU_PRESENT_MODE:-fifo}"
if [[ -n "$extra_guest_env" ]]; then
  runtime_guest_env="${runtime_guest_env}"$'\n'"${extra_guest_env}"
fi

runtime_session_env=$(
  cat <<EOF
SHADOW_GUEST_TOUCH_SIGNAL_PATH=$touch_signal_path
SHADOW_GUEST_COMPOSITOR_BOOT_SPLASH_DRM=1
SHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH=$runtime_surface_width
SHADOW_GUEST_COMPOSITOR_TOPLEVEL_HEIGHT=$runtime_surface_height
EOF
)
if [[ -n "$extra_session_env" ]]; then
  runtime_session_env="${runtime_session_env}"$'\n'"${extra_session_env}"
fi

required_markers='runtime-session-ready'
if [[ -n "$extra_required_markers" ]]; then
  required_markers="${required_markers}"$'\n'"${extra_required_markers}"
fi

forbidden_markers='[shadow-runtime-demo] runtime-event-error:'
if [[ -n "$extra_forbidden_markers" ]]; then
  forbidden_markers="${forbidden_markers}"$'\n'"${extra_forbidden_markers}"
fi

takeover_restore_in_session="${PIXEL_TAKEOVER_RESTORE_IN_SESSION-}"
takeover_reboot_on_restore_failure="${PIXEL_TAKEOVER_REBOOT_ON_RESTORE_FAILURE-}"
if [[ -z "$takeover_restore_in_session" ]]; then
  takeover_restore_in_session=0
fi
if [[ -z "$takeover_reboot_on_restore_failure" ]]; then
  takeover_reboot_on_restore_failure=1
fi

# Runtime app smokes validate startup, required app markers, and clean exit.
# Do not implicitly request an extra compositor frame artifact on short-lived
# runs; opt back in explicitly when a debug session needs it.
: "${PIXEL_GUEST_FRAME_CAPTURE_MODE:=off}"

PIXEL_RUNTIME_HOST_BUNDLE_ARTIFACT_DIR="$(pixel_runtime_host_bundle_artifact_dir)" \
PIXEL_RUNTIME_APP_ASSET_ARTIFACT_DIR="$(pixel_runtime_app_asset_artifact_dir)" \
PIXEL_RUNTIME_APP_BUNDLE_ARTIFACT="$(pixel_runtime_app_bundle_artifact)" \
PIXEL_COMPOSITOR_MARKER='[shadow-guest-compositor] presented-frame' \
PIXEL_CLIENT_MARKER='runtime-document-ready' \
PIXEL_GUEST_REQUIRED_MARKERS="$required_markers" \
PIXEL_GUEST_COMPOSITOR_MARKER_TIMEOUT_SECS="$PIXEL_GUEST_COMPOSITOR_MARKER_TIMEOUT_SECS" \
PIXEL_GUEST_FRAME_CHECKPOINT_TIMEOUT_SECS="$PIXEL_GUEST_FRAME_CHECKPOINT_TIMEOUT_SECS" \
PIXEL_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME='' \
PIXEL_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT=1 \
PIXEL_GUEST_CLIENT_EXIT_ON_CONFIGURE='' \
PIXEL_GUEST_SESSION_TIMEOUT_SECS="$PIXEL_GUEST_SESSION_TIMEOUT_SECS" \
PIXEL_GUEST_SESSION_EXIT_TIMEOUT_SECS="$runtime_session_exit_timeout_secs" \
PIXEL_GUEST_CLIENT_ENV="$runtime_guest_env" \
PIXEL_GUEST_SESSION_ENV="$runtime_session_env" \
PIXEL_GUEST_PRECREATE_DIRS="$(pixel_runtime_precreate_dirs_lines)" \
PIXEL_GUEST_FRAME_CAPTURE_MODE="$PIXEL_GUEST_FRAME_CAPTURE_MODE" \
PIXEL_VERIFY_FORBIDDEN_MARKERS="$forbidden_markers" \
  PIXEL_RUNTIME_SUMMARY_RENDERER="gpu" \
PIXEL_GUEST_SKIP_PUSH="$([[ "$runtime_run_only" == 1 ]] && printf 1 || true)" \
PIXEL_TAKEOVER_RESTORE_IN_SESSION="$takeover_restore_in_session" \
PIXEL_TAKEOVER_REBOOT_ON_RESTORE_FAILURE="$takeover_reboot_on_restore_failure" \
  "$SCRIPT_DIR/pixel/pixel_guest_ui_drm.sh"
