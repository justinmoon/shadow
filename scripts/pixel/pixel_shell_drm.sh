#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./pixel_camera_runtime_common.sh
source "$SCRIPT_DIR/lib/pixel_camera_runtime_common.sh"
# shellcheck source=./session_apps.sh
source "$SCRIPT_DIR/lib/session_apps.sh"
export SHADOW_SESSION_APP_PROFILE="pixel-shell"
ensure_bootimg_shell "$@"

shell_start_app_id=""
shell_stage_only=0
shell_run_only=0
camera_runtime_enabled=1
shell_app_id="$(shadow_session_shell_app_id)"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app)
        shell_start_app_id="${2:?pixel_shell_drm: --app requires a value}"
        shift 2
        ;;
      --stage-only)
        shell_stage_only=1
        shift
        ;;
      --run-only)
        shell_run_only=1
        shift
        ;;
      --camera-runtime)
        camera_runtime_enabled=1
        shift
        ;;
      --no-camera-runtime)
        camera_runtime_enabled=0
        shift
        ;;
      *)
        echo "pixel_shell_drm: unsupported argument $1" >&2
        exit 64
        ;;
    esac
  done
}

parse_args "$@"

serial="$(pixel_resolve_serial)"
pixel_require_host_lock "$serial" "$0" "$@"
camera_endpoint=""
camera_allow_mock="${SHADOW_RUNTIME_CAMERA_ALLOW_MOCK-}"
camera_timeout_ms="${SHADOW_RUNTIME_CAMERA_TIMEOUT_MS-}"
camera_mock_requested=0
camera_service_json=""
camera_start_command=""
camera_cleanup_command=""

if (( shell_stage_only == 1 && shell_run_only == 1 )); then
  echo "pixel_shell_drm: --run-only cannot be combined with --stage-only" >&2
  exit 64
fi
if [[ -n "$shell_start_app_id" ]]; then
  if shadow_session_app_is_shell "$shell_start_app_id"; then
    shell_start_app_id=""
  elif ! shadow_session_app_supports_auto_open "$shell_start_app_id"; then
    echo "pixel_shell_drm: unsupported --app $shell_start_app_id; expected $(shadow_session_apps_usage)" >&2
    exit 64
  fi
fi
if (( camera_runtime_enabled == 1 )); then
  if pixel_camera_runtime_mock_requested "$camera_allow_mock"; then
    camera_mock_requested=1
  fi
  camera_endpoint="$(pixel_camera_runtime_endpoint)"
  camera_service_json="$(
    pixel_camera_runtime_service_json \
      "$camera_endpoint" \
      "$camera_allow_mock" \
      "$camera_timeout_ms"
  )"
  if (( camera_mock_requested == 0 )); then
    camera_start_command="$(pixel_camera_runtime_start_command "$camera_endpoint")"
    camera_cleanup_command="$(pixel_camera_runtime_cleanup_command)"
  fi
fi
shell_services_json="$(
  pixel_merge_services_json \
    "$(pixel_runtime_shell_services_json)" \
    "$camera_service_json"
)"

if [[ -z "${PIXEL_VENDOR_TURNIP_LIB_PATH-}" && -z "${PIXEL_VENDOR_TURNIP_TARBALL-}" ]]; then
  PIXEL_VENDOR_TURNIP_LIB_PATH="$(pixel_ensure_pinned_turnip_lib)"
  export PIXEL_VENDOR_TURNIP_LIB_PATH
fi
# Pixel shell is GPU-only.

if (( shell_run_only == 0 )); then
  "$SCRIPT_DIR/pixel/pixel_build.sh"
fi

shell_gpu_profile="${PIXEL_SHELL_GPU_PROFILE-}"
shell_gpu_bundle_mode="${PIXEL_BLITZ_GPU_BUNDLE_MODE-}"
shell_surface_width=""
shell_surface_height=""
shell_viewport_mode="${PIXEL_SHELL_VIEWPORT_MODE-logical}"

if (( shell_run_only == 0 )); then
  if [[ -z "$shell_gpu_bundle_mode" ]]; then
    if [[ -n "$shell_gpu_profile" ]]; then
      case "$shell_gpu_profile" in
        vulkan*)
          shell_gpu_bundle_mode="full"
          ;;
        *)
          shell_gpu_bundle_mode="full"
          ;;
      esac
    else
      shell_gpu_bundle_mode="full"
    fi
  fi
  PIXEL_BLITZ_GPU_BUNDLE_MODE="$shell_gpu_bundle_mode" \
    "$SCRIPT_DIR/pixel/pixel_prepare_blitz_demo_gpu_bundle.sh"
fi

if [[ -z "$shell_gpu_profile" ]]; then
  if [[ -n "${PIXEL_VENDOR_TURNIP_TARBALL-}" || -n "${PIXEL_VENDOR_TURNIP_LIB_PATH-}" ]]; then
    shell_gpu_profile="vulkan_kgsl_first"
  else
    shell_gpu_profile="gl"
  fi
fi

if (( shell_run_only == 0 )); then
  "$SCRIPT_DIR/pixel/pixel_prepare_shell_runtime_artifacts.sh"
  if (( camera_runtime_enabled == 1 && camera_mock_requested == 0 )); then
    pixel_camera_runtime_prepare_helper "$serial"
  fi
fi

shell_panel_size="${PIXEL_SHELL_PANEL_SIZE-${PIXEL_PANEL_SIZE-}}"
if [[ -z "$shell_panel_size" ]]; then
  shell_panel_size="$(pixel_display_size "$serial" 2>/dev/null || true)"
fi
if [[ -z "$shell_panel_size" ]]; then
  echo "pixel_shell_drm: failed to determine display size; set PIXEL_SHELL_PANEL_SIZE or PIXEL_PANEL_SIZE" >&2
  exit 1
fi
shell_surface_width="${shell_panel_size%x*}"
shell_surface_height="${shell_panel_size#*x}"
if [[ -z "$shell_surface_width" || -z "$shell_surface_height" ]]; then
  echo "pixel_shell_drm: failed to derive shell viewport from $shell_panel_size (mode=$shell_viewport_mode)" >&2
  exit 1
fi

PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS="${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS-}"
PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS-}"
extra_guest_env="${PIXEL_SHELL_EXTRA_GUEST_CLIENT_ENV-}"
extra_session_env="${PIXEL_SHELL_EXTRA_SESSION_ENV-}"
extra_required_markers="${PIXEL_SHELL_EXTRA_REQUIRED_MARKERS-}"
runtime_mesa_cache_dir="$(pixel_runtime_mesa_cache_dir)"
expect_client_process=''

# Shell operator runs do not need per-frame snapshot caching by default.
# Opt back in explicitly when a debug session wants publish/request capture.
: "${PIXEL_GUEST_FRAME_CAPTURE_MODE:=off}"

shell_guest_env=$(
  cat <<EOF
SHADOW_BLITZ_RUNTIME_POLL_INTERVAL_MS=${SHADOW_BLITZ_RUNTIME_POLL_INTERVAL_MS:-16}
SHADOW_BLITZ_DEBUG_OVERLAY=0
SHADOW_BLITZ_UNDECORATED=${SHADOW_BLITZ_UNDECORATED:-1}
SHADOW_BLITZ_ANDROID_FONTS=${SHADOW_BLITZ_ANDROID_FONTS:-curated}
SHADOW_BLITZ_SOFTWARE_KEYBOARD=${SHADOW_BLITZ_SOFTWARE_KEYBOARD:-1}
$(pixel_runtime_linux_user_env_lines)
EOF
)
if [[ -n "$PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS" ]]; then
  shell_guest_env="${shell_guest_env}"$'\n'"SHADOW_BLITZ_RUNTIME_EXIT_DELAY_MS=$PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS"
fi
shell_guest_env="${shell_guest_env}"$'\n'"SHADOW_BLITZ_SURFACE_WIDTH=$shell_surface_width"
shell_guest_env="${shell_guest_env}"$'\n'"SHADOW_BLITZ_SURFACE_HEIGHT=$shell_surface_height"
shell_guest_env="${shell_guest_env}"$'\n'"MESA_SHADER_CACHE_DIR=$runtime_mesa_cache_dir"
shell_gpu_profile_env="$(pixel_runtime_gpu_profile_lines "$shell_gpu_profile")" || {
  echo "pixel_shell_drm: unsupported PIXEL_SHELL_GPU_PROFILE: $shell_gpu_profile" >&2
  exit 1
}
while IFS= read -r env_line; do
  [[ -n "$env_line" ]] || continue
  shell_guest_env="${shell_guest_env}"$'\n'"$env_line"
done < <(printf '%s\n' "$shell_gpu_profile_env")
shell_guest_env="${shell_guest_env}"$'\n'"SHADOW_WGPU_PRESENT_MODE=${SHADOW_WGPU_PRESENT_MODE:-fifo}"
shell_guest_env="${shell_guest_env}"$'\n'"SHADOW_WGPU_ANTIALIASING=${SHADOW_WGPU_ANTIALIASING:-area}"
shell_session_env=$(
  cat <<EOF
SHADOW_GUEST_START_APP_ID=$shell_app_id
SHADOW_SESSION_APP_PROFILE=pixel-shell
SHADOW_RUNTIME_DIR_MODE=0711
SHADOW_COMPOSITOR_CONTROL_SOCKET_MODE=0666
SHADOW_GUEST_COMPOSITOR_BIN=$(pixel_runtime_compositor_launcher_dst)
$(pixel_runtime_shell_bundle_env_lines)
$(pixel_system_env_lines)
SHADOW_GUEST_COMPOSITOR_BOOT_SPLASH_DRM=1
EOF
)
shell_session_env="${shell_session_env}"$'\n'"SHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH=$shell_surface_width"
shell_session_env="${shell_session_env}"$'\n'"SHADOW_GUEST_COMPOSITOR_TOPLEVEL_HEIGHT=$shell_surface_height"
shell_session_env="${shell_session_env}"$'\n''SHADOW_GUEST_COMPOSITOR_GPU_SHELL=1'
shell_session_env="${shell_session_env}"$'\n''SHADOW_GUEST_COMPOSITOR_STRICT_GPU_RESIDENT=1'
while IFS= read -r env_line; do
  [[ -n "$env_line" ]] || continue
  shell_session_env="${shell_session_env}"$'\n'"$env_line"
done < <(printf '%s\n' "$shell_gpu_profile_env")
if [[ -n "$shell_start_app_id" ]]; then
  shell_session_env="${shell_session_env}"$'\n'"SHADOW_GUEST_SHELL_START_APP_ID=$shell_start_app_id"
  extra_required_markers="${extra_required_markers}"$'\n''[shadow-guest-compositor] mapped-window'
  extra_required_markers="${extra_required_markers}"$'\n'"[shadow-guest-compositor] surface-app-tracked app=$shell_start_app_id"
fi

required_markers='[shadow-guest-compositor] touch-ready'
if [[ -n "$extra_required_markers" ]]; then
  required_markers="${required_markers}"$'\n'"${extra_required_markers}"
fi

if (( shell_stage_only == 1 )); then
  PIXEL_SYSTEM_BUNDLE_ARTIFACT_DIR="$(pixel_shell_system_bundle_artifact_dir)" \
    "$SCRIPT_DIR/pixel/pixel_push.sh"
  exit 0
fi

run_dir="${PIXEL_GUEST_RUN_DIR-}"
if [[ -z "$run_dir" ]]; then
  run_dir="$(pixel_prepare_named_run_dir "$(pixel_drm_guest_runs_dir)")"
else
  mkdir -p "$run_dir"
fi
startup_config_host_path="$(pixel_guest_startup_config_host_path "$run_dir")"
run_config_path="$(pixel_guest_run_config_host_path "$run_dir")"

shell_session_env_for_config="$shell_session_env"
while IFS= read -r env_line; do
  [[ -n "$env_line" ]] || continue
  shell_session_env_for_config="${shell_session_env_for_config}"$'\n'"$env_line"
done < <(pixel_guest_session_overlay_config_env_lines "$extra_session_env")

shell_session_launch_env="$(pixel_guest_session_launch_env_lines "$shell_session_env")"
overlay_session_launch_env="$(pixel_guest_session_overlay_passthrough_env_lines "$extra_session_env")"
if [[ -n "$overlay_session_launch_env" ]]; then
  if [[ -n "$shell_session_launch_env" ]]; then
    shell_session_launch_env="${shell_session_launch_env}"$'\n'"$overlay_session_launch_env"
  else
    shell_session_launch_env="$overlay_session_launch_env"
  fi
fi

pixel_write_guest_ui_startup_config \
  "$startup_config_host_path" \
  "$(pixel_runtime_dir)" \
  "$(pixel_guest_client_dst)" \
  "" \
  "" \
  "" \
  "$shell_guest_env" \
  "$shell_session_env_for_config" \
  "$(pixel_frame_path)" \
  "$PIXEL_GUEST_FRAME_CAPTURE_MODE" \
  "$shell_services_json"

pixel_write_guest_run_config \
  "$run_config_path" \
  "$startup_config_host_path" \
  "$(pixel_shell_system_bundle_artifact_dir)" \
  "" \
  "" \
  "$shell_session_launch_env" \
  "$extra_guest_env" \
  "$required_markers" \
  "" \
  "$(pixel_runtime_precreate_dirs_lines)" \
  "$camera_start_command" \
  "$camera_cleanup_command" \
  '[shadow-guest-compositor] presented-frame' \
  "" \
  "" \
  "$expect_client_process" \
  "" \
  "" \
  "$PIXEL_GUEST_SESSION_TIMEOUT_SECS" \
  "${PIXEL_GUEST_SESSION_EXIT_TIMEOUT_SECS-}" \
  "${PIXEL_GUEST_COMPOSITOR_MARKER_TIMEOUT_SECS-}" \
  "${PIXEL_GUEST_REQUIRED_MARKER_TIMEOUT_SECS-}" \
  "${PIXEL_GUEST_FRAME_CHECKPOINT_TIMEOUT_SECS-}" \
  "${PIXEL_TAKEOVER_RESTORE_CHECKPOINT_TIMEOUT_SECS-}" \
  "${PIXEL_TAKEOVER_RESTORE_REBOOT_TIMEOUT_SECS-}" \
  "${PIXEL_TAKEOVER_RESTORE_ANDROID-1}" \
  "${PIXEL_TAKEOVER_RESTORE_IN_SESSION-1}" \
  "${PIXEL_TAKEOVER_REBOOT_ON_RESTORE_FAILURE-0}" \
  "${PIXEL_TAKEOVER_STOP_ALLOCATOR:-0}" \
  "$([[ "$shell_run_only" == 1 ]] && printf 1 || true)" \
  ""

exec env \
  PIXEL_GUEST_RUN_DIR="$run_dir" \
  PIXEL_GUEST_RUN_CONFIG="$run_config_path" \
  PIXEL_SYSTEM_BUNDLE_ARTIFACT_DIR="$(pixel_shell_system_bundle_artifact_dir)" \
  PIXEL_GUEST_SKIP_PUSH="$([[ "$shell_run_only" == 1 ]] && printf 1 || true)" \
  "$SCRIPT_DIR/pixel/pixel_guest_ui_drm.sh"
