#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

serial="$(pixel_resolve_serial)"

default_turnip_tarball="$(pixel_dir)/vendor/turnip_26.1.0-devel-20260404_debian_trixie_arm64.tar.gz"
default_mesa_tarball="$(pixel_dir)/vendor/mesa-for-android-container_26.1.0-devel-20260404_debian_trixie_arm64.tar.gz"
if [[ -z "${PIXEL_VENDOR_MESA_TARBALL-}" && -f "$default_mesa_tarball" ]]; then
  PIXEL_VENDOR_MESA_TARBALL="$default_mesa_tarball"
  export PIXEL_VENDOR_MESA_TARBALL
fi
if [[ -z "${PIXEL_VENDOR_TURNIP_TARBALL-}" && -f "$default_turnip_tarball" ]]; then
  PIXEL_VENDOR_TURNIP_TARBALL="$default_turnip_tarball"
  export PIXEL_VENDOR_TURNIP_TARBALL
fi

# Deterministic default. Never infer renderer mode from optional GPU assets.
# CPU stays opt-in through PIXEL_RUNTIME_APP_RENDERER=cpu.
: "${PIXEL_RUNTIME_APP_RENDERER:=gpu_softbuffer}"
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

build_include_guest_client=1
if [[ "$PIXEL_RUNTIME_APP_RENDERER" == "gpu_softbuffer" || "$PIXEL_RUNTIME_APP_RENDERER" == "gpu" ]]; then
  build_include_guest_client=0
fi

if (( runtime_run_only == 0 )); then
  PIXEL_BUILD_INCLUDE_GUEST_CLIENT="$build_include_guest_client" \
    "$SCRIPT_DIR/pixel_build.sh"
fi

guest_client_artifact="$(pixel_guest_client_artifact)"
guest_client_dst="$(pixel_guest_client_dst)"
runtime_prepare_extra_env=()
runtime_gpu_profile="${PIXEL_RUNTIME_APP_GPU_PROFILE-}"

case "$PIXEL_RUNTIME_APP_RENDERER" in
  cpu)
    if (( runtime_run_only == 0 )); then
      PIXEL_BLITZ_RENDERER=cpu "$SCRIPT_DIR/pixel_build_guest_client.sh"
    fi
    ;;
  gpu)
    if (( runtime_run_only == 0 )); then
      "$SCRIPT_DIR/pixel_prepare_blitz_demo_gpu_bundle.sh"
    fi
    guest_client_artifact="$(pixel_artifact_path run-shadow-blitz-demo-gpu)"
    guest_client_dst="$(pixel_runtime_linux_dir)/run-shadow-blitz-demo"
    runtime_prepare_extra_env=(
      "PIXEL_RUNTIME_EXTRA_BUNDLE_ARTIFACT_DIR=$(pixel_artifact_path shadow-blitz-demo-gpu-gnu)"
    )
    if [[ -z "$runtime_gpu_profile" ]]; then
      if [[ -n "${PIXEL_VENDOR_TURNIP_TARBALL-}" ]]; then
        runtime_gpu_profile="vulkan_kgsl_first"
      else
        runtime_gpu_profile="gl"
      fi
    fi
    ;;
  hybrid)
    if (( runtime_run_only == 0 )); then
      PIXEL_BLITZ_RENDERER=hybrid "$SCRIPT_DIR/pixel_build_guest_client.sh"
    fi
    ;;
  gpu_softbuffer)
    if (( runtime_run_only == 0 )); then
      "$SCRIPT_DIR/pixel_prepare_blitz_demo_gpu_softbuffer_bundle.sh"
    fi
    guest_client_artifact="$(pixel_artifact_path run-shadow-blitz-demo-gpu-softbuffer)"
    guest_client_dst="$(pixel_runtime_linux_dir)/run-shadow-blitz-demo"
    runtime_prepare_extra_env=(
      "PIXEL_RUNTIME_EXTRA_BUNDLE_ARTIFACT_DIR=$(pixel_artifact_path shadow-blitz-demo-gnu)"
    )
    ;;
  *)
    echo "pixel_runtime_app_drm: unsupported PIXEL_RUNTIME_APP_RENDERER: $PIXEL_RUNTIME_APP_RENDERER" >&2
    exit 1
    ;;
esac

if (( runtime_run_only == 0 )); then
  env "${runtime_prepare_extra_env[@]}" "$SCRIPT_DIR/pixel_prepare_runtime_app_artifacts.sh"
fi

: "${PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS:=12000}"
: "${PIXEL_GUEST_COMPOSITOR_MARKER_TIMEOUT_SECS:=45}"
: "${PIXEL_GUEST_FRAME_CHECKPOINT_TIMEOUT_SECS:=45}"
: "${PIXEL_GUEST_SESSION_TIMEOUT_SECS:=20}"
extra_guest_env="${PIXEL_RUNTIME_APP_EXTRA_GUEST_CLIENT_ENV-}"
extra_session_env="${PIXEL_RUNTIME_APP_EXTRA_SESSION_ENV-}"
extra_required_markers="${PIXEL_RUNTIME_APP_EXTRA_REQUIRED_MARKERS-}"
extra_forbidden_markers="${PIXEL_RUNTIME_APP_EXTRA_FORBIDDEN_MARKERS-}"
touch_signal_path="$(pixel_runtime_touch_signal_path)"
runtime_mesa_cache_dir="$(pixel_runtime_mesa_cache_dir)"

if (( runtime_stage_only == 1 )); then
  PIXEL_GUEST_CLIENT_ARTIFACT="$guest_client_artifact" \
  PIXEL_GUEST_CLIENT_DST="$guest_client_dst" \
  PIXEL_RUNTIME_HOST_BUNDLE_ARTIFACT_DIR="$(pixel_runtime_host_bundle_artifact_dir)" \
  PIXEL_RUNTIME_APP_BUNDLE_ARTIFACT="$(pixel_runtime_app_bundle_artifact)" \
    "$SCRIPT_DIR/pixel_push.sh"
  exit 0
fi

panel_size="$(pixel_display_size "$serial")"
viewport_fit="$(python3 "$SCRIPT_DIR/runtime_viewport.py" --fit "$panel_size")"
runtime_surface_width="$(printf '%s\n' "$viewport_fit" | awk -F= '/^fitted_width=/{print $2}')"
runtime_surface_height="$(printf '%s\n' "$viewport_fit" | awk -F= '/^fitted_height=/{print $2}')"
if [[ -z "$runtime_surface_width" || -z "$runtime_surface_height" ]]; then
  echo "pixel_runtime_app_drm: failed to derive runtime viewport from $panel_size" >&2
  exit 1
fi

runtime_guest_env=$(
  cat <<EOF
SHADOW_BLITZ_DEMO_MODE=runtime
SHADOW_BLITZ_SURFACE_WIDTH=$runtime_surface_width
SHADOW_BLITZ_SURFACE_HEIGHT=$runtime_surface_height
SHADOW_BLITZ_RUNTIME_EXIT_DELAY_MS=$PIXEL_BLITZ_RUNTIME_EXIT_DELAY_MS
SHADOW_BLITZ_RAW_POINTER_FALLBACK=1
SHADOW_BLITZ_TOUCH_ANYWHERE_TARGET=counter
SHADOW_BLITZ_TOUCH_ACTIVATE_ON_DOWN=1
SHADOW_BLITZ_TOUCH_SIGNAL_PATH=$touch_signal_path
SHADOW_BLITZ_DEBUG_OVERLAY=0
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
if [[ "$PIXEL_RUNTIME_APP_RENDERER" == "gpu_softbuffer" || "$PIXEL_RUNTIME_APP_RENDERER" == "gpu" ]]; then
  runtime_guest_env="${runtime_guest_env}"$'\n'"MESA_SHADER_CACHE_DIR=$runtime_mesa_cache_dir"
  if [[ "$PIXEL_RUNTIME_APP_RENDERER" == "gpu" ]]; then
    runtime_gpu_profile_env="$(pixel_runtime_gpu_profile_lines "$runtime_gpu_profile")" || {
      echo "pixel_runtime_app_drm: unsupported PIXEL_RUNTIME_APP_GPU_PROFILE: $runtime_gpu_profile" >&2
      exit 1
    }
    while IFS= read -r env_line; do
      [[ -n "$env_line" ]] || continue
      runtime_guest_env="${runtime_guest_env}"$'\n'"$env_line"
    done < <(printf '%s\n' "$runtime_gpu_profile_env")
  elif [[ -n "${PIXEL_VENDOR_TURNIP_TARBALL-}" ]]; then
    runtime_guest_env="${runtime_guest_env}"$'\n'"WGPU_BACKEND=${WGPU_BACKEND:-vulkan}"
    runtime_guest_env="${runtime_guest_env}"$'\n'"MESA_LOADER_DRIVER_OVERRIDE=${MESA_LOADER_DRIVER_OVERRIDE:-kgsl}"
    runtime_guest_env="${runtime_guest_env}"$'\n'"TU_DEBUG=${TU_DEBUG:-noconform}"
    runtime_guest_env="${runtime_guest_env}"$'\n'"SHADOW_LINUX_LD_PRELOAD=$(pixel_runtime_openlog_preload_dst)"
    runtime_guest_env="${runtime_guest_env}"$'\n'"SHADOW_OPENLOG_DENY_DRI=${SHADOW_OPENLOG_DENY_DRI:-1}"
  else
    runtime_guest_env="${runtime_guest_env}"$'\n'"WGPU_BACKEND=${WGPU_BACKEND:-gl}"
  fi
fi
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

PIXEL_GUEST_CLIENT_ARTIFACT="$guest_client_artifact" \
PIXEL_GUEST_CLIENT_DST="$guest_client_dst" \
PIXEL_RUNTIME_HOST_BUNDLE_ARTIFACT_DIR="$(pixel_runtime_host_bundle_artifact_dir)" \
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
PIXEL_GUEST_CLIENT_ENV="$runtime_guest_env" \
PIXEL_GUEST_SESSION_ENV="$runtime_session_env" \
PIXEL_GUEST_PRECREATE_DIRS="$(pixel_runtime_precreate_dirs_lines)" \
PIXEL_VERIFY_FORBIDDEN_MARKERS="$forbidden_markers" \
PIXEL_RUNTIME_SUMMARY_RENDERER="$PIXEL_RUNTIME_APP_RENDERER" \
PIXEL_GUEST_SKIP_PUSH="$([[ "$runtime_run_only" == 1 ]] && printf 1 || true)" \
  "$SCRIPT_DIR/pixel_guest_ui_drm.sh"
