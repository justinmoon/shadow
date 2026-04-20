#!/usr/bin/env bash

pixel_prepare_dirs() {
  mkdir -p \
    "$(pixel_artifacts_dir)" \
    "$(pixel_runs_dir)" \
    "$(pixel_root_dir)" \
    "$(pixel_boot_dir)"
}

pixel_pinned_turnip_result_link() {
  printf '%s/shadow-pinned-turnip-mesa-aarch64-linux-result\n' "$(pixel_dir)"
}

pixel_pinned_turnip_lib_path() {
  printf '%s/lib/libvulkan_freedreno.so\n' "$(pixel_pinned_turnip_result_link)"
}

pixel_ensure_pinned_turnip_lib() {
  local repo package_system package_ref out_link lib_path

  out_link="$(pixel_pinned_turnip_result_link)"
  lib_path="$(pixel_pinned_turnip_lib_path)"
  repo="$(repo_root)"
  package_system="${PIXEL_LINUX_BUILD_SYSTEM:-aarch64-linux}"
  package_ref="$repo#packages.${package_system}.shadow-pinned-turnip-mesa-aarch64-linux"
  nix build \
    --accept-flake-config \
    --out-link "$out_link" \
    --print-out-paths \
    "$package_ref" >/dev/null

  if [[ ! -f "$lib_path" ]]; then
    echo "pixel: pinned Turnip build did not produce libvulkan_freedreno.so: $lib_path" >&2
    return 1
  fi

  printf '%s\n' "$lib_path"
}

pixel_prepare_named_run_dir() {
  local base_dir run_dir
  base_dir="$1"
  mkdir -p "$base_dir"
  run_dir="${base_dir}/$(pixel_timestamp)"
  mkdir -p "$run_dir"
  printf '%s\n' "$run_dir"
}

pixel_prepare_run_dir() {
  local run_dir
  pixel_prepare_dirs
  run_dir="$(pixel_runs_dir)/$(pixel_timestamp)"
  mkdir -p "$run_dir"
  ln -sfn "$run_dir" "$(pixel_latest_run_link)"
  printf '%s\n' "$run_dir"
}

pixel_latest_run_dir() {
  local link
  link="$(pixel_latest_run_link)"
  if [[ -L "$link" ]]; then
    readlink "$link"
  fi
}

pixel_selected_run_dir() {
  if [[ -n "${PIXEL_RUN_DIR:-}" ]]; then
    printf '%s\n' "$PIXEL_RUN_DIR"
    return 0
  fi
  pixel_latest_run_dir
}

pixel_artifact_path() {
  printf '%s/%s\n' "$(pixel_artifacts_dir)" "$1"
}

pixel_session_artifact() {
  pixel_artifact_path shadow-session
}

pixel_compositor_artifact() {
  pixel_artifact_path shadow-compositor-guest
}

pixel_runtime_app_bundle_artifact() {
  pixel_artifact_path shadow-runtime-app-bundle.js
}

pixel_runtime_apps_manifest() {
  printf '%s\n' "${SHADOW_APP_METADATA_MANIFEST:-$(repo_root)/runtime/apps.json}"
}

pixel_manifest_profile_app_ids() {
  local profile="$1"
  local model_filter="${2:-}"

  python3 - "$(pixel_runtime_apps_manifest)" "$profile" "$model_filter" <<'PY'
import json
import sys

manifest_path, profile, model_filter = sys.argv[1:4]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)

for app in manifest.get("apps", []):
    profiles = set(app.get("profiles", []))
    if profile not in profiles:
        continue
    if model_filter and app.get("model") != model_filter:
        continue
    print(app["id"])
PY
}

pixel_session_shell_app_ids() {
  pixel_manifest_profile_app_ids "pixel-shell" "typescript"
}

pixel_runtime_shell_app_ids() {
  pixel_manifest_profile_app_ids "pixel-shell" "typescript"
}

pixel_runtime_app_manifest_field() {
  local app_id="$1"
  local field_path="$2"

  python3 - "$(pixel_runtime_apps_manifest)" "$app_id" "$field_path" <<'PY'
import json
import sys

manifest_path, app_id, field_path = sys.argv[1:4]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)

for app in manifest.get("apps", []):
    if app.get("id") != app_id:
        continue
    value = app
    for part in field_path.split("."):
        value = value[part]
    if isinstance(value, (dict, list)):
        print(json.dumps(value, separators=(",", ":")))
    else:
        print(value)
    raise SystemExit(0)

raise SystemExit(f"unknown runtime app id: {app_id}")
PY
}

pixel_runtime_app_bundle_filename() {
  pixel_runtime_app_manifest_field "$1" runtime.bundleFilename
}

pixel_runtime_app_bundle_env() {
  pixel_runtime_app_manifest_field "$1" runtime.bundleEnv
}

pixel_runtime_app_bundle_artifact_for() {
  pixel_artifact_path "$(pixel_runtime_app_bundle_filename "$1")"
}

pixel_system_bundle_artifact_dir() {
  pixel_artifact_path shadow-runtime-gnu
}

pixel_runtime_app_asset_artifact_dir() {
  pixel_artifact_path shadow-runtime-app-assets
}

pixel_shell_system_bundle_artifact_dir() {
  pixel_artifact_path shadow-runtime-shell-gnu
}

pixel_guest_client_artifact() {
  pixel_artifact_path run-shadow-blitz-demo-gpu
}

pixel_session_dst() {
  printf '%s\n' "${PIXEL_SESSION_DST:-/data/local/tmp/shadow-session}"
}

pixel_compositor_dst() {
  printf '%s\n' "${PIXEL_COMPOSITOR_DST:-/data/local/tmp/shadow-compositor-guest}"
}

pixel_guest_client_dst() {
  printf '%s/run-shadow-blitz-demo\n' "$(pixel_runtime_linux_dir)"
}

pixel_runtime_dir() {
  printf '%s\n' "${PIXEL_RUNTIME_DIR:-/data/local/tmp/shadow-runtime}"
}

pixel_runtime_touch_signal_path() {
  printf '%s/touch-signal\n' "$(pixel_runtime_dir)"
}

pixel_runtime_cashu_data_dir() {
  printf '%s/cashu\n' "$(pixel_runtime_dir)"
}

pixel_runtime_nostr_db_path() {
  printf '%s/runtime-nostr.sqlite3\n' "$(pixel_runtime_dir)"
}

pixel_shell_control_socket_path() {
  printf '%s/%s\n' "$(pixel_runtime_dir)" "shadow-control.sock"
}

pixel_runtime_linux_dir() {
  printf '%s\n' "${PIXEL_RUNTIME_LINUX_DIR:-/data/local/tmp/shadow-runtime-gnu}"
}

pixel_runtime_chroot_device_path() {
  local chroot_path
  chroot_path="${1:?pixel_runtime_chroot_device_path requires a path}"
  printf '%s%s\n' "$(pixel_runtime_linux_dir)" "$chroot_path"
}

pixel_runtime_home_dir() {
  printf '%s/home\n' "$(pixel_runtime_linux_dir)"
}

pixel_runtime_cache_dir() {
  printf '%s/.cache\n' "$(pixel_runtime_home_dir)"
}

pixel_runtime_mesa_cache_dir() {
  printf '%s/mesa\n' "$(pixel_runtime_cache_dir)"
}

pixel_runtime_config_dir() {
  printf '%s/.config\n' "$(pixel_runtime_home_dir)"
}

pixel_runtime_xkb_config_root() {
  printf '%s/share/X11/xkb\n' "$(pixel_runtime_linux_dir)"
}

pixel_runtime_precreate_dirs_lines() {
  cat <<EOF
$(pixel_runtime_home_dir)
$(pixel_runtime_cache_dir)
$(pixel_runtime_mesa_cache_dir)
$(pixel_runtime_config_dir)
EOF
}

pixel_runtime_app_bundle_dst() {
  printf '%s/runtime-app-bundle.js\n' "$(pixel_runtime_linux_dir)"
}

pixel_runtime_app_bundle_dst_for() {
  printf '%s/%s\n' "$(pixel_runtime_linux_dir)" "$(pixel_runtime_app_bundle_filename "$1")"
}

pixel_system_binary_dst() {
  printf '%s/shadow-system\n' "$(pixel_runtime_linux_dir)"
}

pixel_system_launcher_dst() {
  printf '%s/run-shadow-system\n' "$(pixel_runtime_linux_dir)"
}

pixel_runtime_compositor_binary_dst() {
  printf '%s/shadow-compositor-guest\n' "$(pixel_runtime_linux_dir)"
}

pixel_runtime_compositor_launcher_dst() {
  printf '%s/run-shadow-compositor-guest\n' "$(pixel_runtime_linux_dir)"
}

pixel_runtime_openlog_preload_dst() {
  printf '%s/lib/shadow-openlog-preload.so\n' "$(pixel_runtime_linux_dir)"
}

pixel_system_env_lines() {
  cat <<EOF
SHADOW_SYSTEM_BINARY_PATH=$(pixel_system_launcher_dst)
SHADOW_RUNTIME_NOSTR_DB_PATH=$(pixel_runtime_nostr_db_path)
SHADOW_RUNTIME_NOSTR_SERVICE_SOCKET=$(pixel_runtime_dir)/runtime-nostr.sock
EOF
}

pixel_runtime_linux_user_env_lines() {
  cat <<EOF
HOME=$(pixel_runtime_home_dir)
XDG_CACHE_HOME=$(pixel_runtime_cache_dir)
XDG_CONFIG_HOME=$(pixel_runtime_config_dir)
XKB_CONFIG_ROOT=$(pixel_runtime_xkb_config_root)
EOF
}

pixel_runtime_linux_bundle_env_lines() {
  cat <<EOF
HOME=$(pixel_runtime_home_dir)
XDG_CACHE_HOME=$(pixel_runtime_cache_dir)
XDG_CONFIG_HOME=$(pixel_runtime_config_dir)
MESA_SHADER_CACHE_DIR=$(pixel_runtime_mesa_cache_dir)
LD_LIBRARY_PATH=$(pixel_runtime_linux_dir)/lib
LIBGL_DRIVERS_PATH=$(pixel_runtime_linux_dir)/lib/dri
__EGL_VENDOR_LIBRARY_DIRS=$(pixel_runtime_linux_dir)/share/glvnd/egl_vendor.d
VK_ICD_FILENAMES=$(pixel_runtime_linux_dir)/share/vulkan/icd.d/freedreno_icd.aarch64.json
XKB_CONFIG_EXTRA_PATH=$(pixel_runtime_linux_dir)/etc/xkb
XKB_CONFIG_ROOT=$(pixel_runtime_xkb_config_root)
EOF
}

pixel_runtime_gpu_profile_lines() {
  local profile="$1"

  case "$profile" in
    "")
      return 0
      ;;
    gl)
      printf '%s\n' \
        'WGPU_BACKEND=gl' \
        "SHADOW_LINUX_LD_PRELOAD=$(pixel_runtime_openlog_preload_dst)"
      ;;
    gl_kgsl)
      printf '%s\n' \
        'WGPU_BACKEND=gl' \
        'MESA_LOADER_DRIVER_OVERRIDE=kgsl' \
        'TU_DEBUG=noconform' \
        "SHADOW_LINUX_LD_PRELOAD=$(pixel_runtime_openlog_preload_dst)"
      ;;
    vulkan_drm)
      printf '%s\n' \
        'WGPU_BACKEND=vulkan' \
        "SHADOW_LINUX_LD_PRELOAD=$(pixel_runtime_openlog_preload_dst)"
      ;;
    vulkan_kgsl)
      printf '%s\n' \
        'WGPU_BACKEND=vulkan' \
        'MESA_LOADER_DRIVER_OVERRIDE=kgsl' \
        'TU_DEBUG=noconform' \
        "SHADOW_LINUX_LD_PRELOAD=$(pixel_runtime_openlog_preload_dst)"
      ;;
    vulkan_kgsl_first)
      printf '%s\n' \
        'WGPU_BACKEND=vulkan' \
        'MESA_LOADER_DRIVER_OVERRIDE=kgsl' \
        'TU_DEBUG=noconform' \
        "SHADOW_LINUX_LD_PRELOAD=$(pixel_runtime_openlog_preload_dst)" \
        'SHADOW_OPENLOG_DENY_DRI=1'
      ;;
    *)
      return 1
      ;;
  esac
}

pixel_runtime_shell_bundle_env_lines() {
  local app_id

  while IFS= read -r app_id; do
    [[ -n "$app_id" ]] || continue
    printf '%s=%s\n' \
      "$(pixel_runtime_app_bundle_env "$app_id")" \
      "$(pixel_runtime_app_bundle_dst_for "$app_id")"
  done < <(pixel_runtime_shell_app_ids)
  printf 'SHADOW_RUNTIME_CASHU_DATA_DIR=%s\n' "$(pixel_runtime_cashu_data_dir)"
}

pixel_shell_words_quoted() {
  local word quoted

  for word in "$@"; do
    [[ -n "$word" ]] || continue
    # The rooted device wrapper executes under /system/bin/sh, so avoid bash-only
    # $'...' quoting for multiline env payloads.
    quoted=${word//\'/\'\\\'\'}
    printf "'%s' " "$quoted"
  done
}

pixel_lines_quoted() {
  local lines="$1"
  local line

  [[ -n "$lines" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pixel_shell_words_quoted "$line"
  done <<< "$lines"
}

pixel_guest_ui_session_env_words() {
  local runtime_dir="$1"
  local compositor_dst="$2"
  local client_dst="$3"
  local frame_path="$4"
  local compositor_exit_on_first_frame="${5:-}"
  local compositor_exit_on_client_disconnect="${6:-}"
  local client_exit_on_configure="${7:-}"
  local guest_client_env="${8:-}"
  local guest_session_env="${9:-}"

  pixel_shell_words_quoted \
    "XKB_CONFIG_ROOT=$(pixel_runtime_xkb_config_root)" \
    'SHADOW_SESSION_MODE=guest-ui' \
    "SHADOW_RUNTIME_DIR=$runtime_dir" \
    "SHADOW_GUEST_COMPOSITOR_BIN=$compositor_dst" \
    "SHADOW_GUEST_CLIENT=$client_dst" \
    'SHADOW_GUEST_COMPOSITOR_TRANSPORT=direct' \
    'SHADOW_GUEST_COMPOSITOR_ENABLE_DRM=1'

  if [[ -n "$compositor_exit_on_first_frame" ]]; then
    pixel_shell_words_quoted "SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME=$compositor_exit_on_first_frame"
  fi
  if [[ -n "$compositor_exit_on_client_disconnect" ]]; then
    pixel_shell_words_quoted "SHADOW_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT=$compositor_exit_on_client_disconnect"
  fi
  if [[ -n "$client_exit_on_configure" ]]; then
    pixel_shell_words_quoted "SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE=$client_exit_on_configure"
  fi
  pixel_shell_words_quoted 'SHADOW_GUEST_CLIENT_LINGER_MS=500'
  if [[ -n "$guest_client_env" ]]; then
    pixel_shell_words_quoted "SHADOW_GUEST_CLIENT_ENV=$guest_client_env"
  fi

  pixel_lines_quoted "$guest_session_env"

  pixel_shell_words_quoted \
    "SHADOW_GUEST_FRAME_PATH=$frame_path" \
    'RUST_LOG=shadow_compositor_guest=info,shadow_blitz_demo=info,smithay=warn'
}

pixel_download_dir_device() {
  printf '%s\n' "${PIXEL_DOWNLOAD_DIR_DEVICE:-/storage/emulated/0/Download}"
}

pixel_frame_path() {
  printf '%s\n' "${PIXEL_FRAME_PATH:-/data/local/tmp/shadow-frame.ppm}"
}

pixel_drm_runs_dir() {
  printf '%s/drm\n' "$(pixel_dir)"
}

pixel_drm_guest_runs_dir() {
  printf '%s/drm-guest\n' "$(pixel_dir)"
}

pixel_runtime_runs_dir() {
  printf '%s/runtime\n' "$(pixel_dir)"
}

pixel_shell_runs_dir() {
  printf '%s/shell\n' "$(pixel_dir)"
}

pixel_audio_runs_dir() {
  printf '%s/audio\n' "$(pixel_dir)"
}

pixel_touch_runs_dir() {
  printf '%s/touch\n' "$(pixel_dir)"
}

pixel_audio_linux_dir() {
  printf '%s\n' "${PIXEL_AUDIO_LINUX_DIR:-/data/local/tmp/shadow-audio-spike-gnu}"
}
