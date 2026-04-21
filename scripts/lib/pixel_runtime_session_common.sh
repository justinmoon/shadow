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

pixel_guest_startup_config_dst() {
  local token="${1:-}"

  if [[ -n "${PIXEL_GUEST_STARTUP_CONFIG_DST:-}" ]]; then
    printf '%s\n' "$PIXEL_GUEST_STARTUP_CONFIG_DST"
    return 0
  fi
  if [[ -n "$token" ]]; then
    printf '/data/local/tmp/shadow-guest-startup-%s.json\n' "$token"
    return 0
  fi
  printf '%s\n' '/data/local/tmp/shadow-guest-startup.json'
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

pixel_validate_env_assignment_line() {
  local label="$1"
  local line="$2"
  local key=""

  if [[ "$line" != *=* ]]; then
    echo "pixel: invalid $label assignment (missing '='): $line" >&2
    return 1
  fi

  key="${line%%=*}"
  if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "pixel: invalid $label key: $key" >&2
    return 1
  fi
}

pixel_validate_env_assignment_lines() {
  local label="$1"
  local lines="${2:-}"
  local line=""

  [[ -n "$lines" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pixel_validate_env_assignment_line "$label" "$line" || return 1
  done <<< "$lines"
}

pixel_env_assignment_last_value() {
  local key="${1:?pixel_env_assignment_last_value requires a key}"
  local lines="${2:-}"
  local line=""
  local line_key=""
  local value=""
  local found=""

  pixel_validate_env_assignment_lines "env lookup" "$lines" || return 1
  [[ -n "$lines" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    line_key="${line%%=*}"
    if [[ "$line_key" == "$key" ]]; then
      value="${line#*=}"
      found=1
    fi
  done <<< "$lines"
  if [[ -n "$found" ]]; then
    printf '%s\n' "$value"
  fi
}

pixel_guest_session_env_assignment_is_config_owned() {
  local key="${1:?pixel_guest_session_env_assignment_is_config_owned requires a key}"

  case "$key" in
    SHADOW_GUEST_CLIENT | \
    SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE | \
    SHADOW_GUEST_CLIENT_LINGER_MS | \
    SHADOW_GUEST_COMPOSITOR_BOOT_SPLASH_DRM | \
    SHADOW_GUEST_COMPOSITOR_BACKGROUND_APP_LIMIT | \
    SHADOW_GUEST_COMPOSITOR_DISABLE_DMABUF_GLOBAL | \
    SHADOW_GUEST_COMPOSITOR_DMABUF_FEEDBACK | \
    SHADOW_GUEST_COMPOSITOR_DMABUF_FORMAT_PROFILE | \
    SHADOW_GUEST_COMPOSITOR_ENABLE_DRM | \
    SHADOW_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT | \
    SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_DMA_BUFFER | \
    SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME | \
    SHADOW_GUEST_COMPOSITOR_GPU_SHELL | \
    SHADOW_GUEST_COMPOSITOR_STRICT_GPU_RESIDENT | \
    SHADOW_GUEST_COMPOSITOR_TOPLEVEL_HEIGHT | \
    SHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH | \
    SHADOW_GUEST_COMPOSITOR_TRANSPORT | \
    SHADOW_GUEST_FRAME_ARTIFACTS | \
    SHADOW_GUEST_FRAME_CHECKSUM | \
    SHADOW_GUEST_FRAME_PATH | \
    SHADOW_GUEST_FRAME_SNAPSHOT_CACHE | \
    SHADOW_GUEST_FRAME_WRITE_EVERY_FRAME | \
    SHADOW_GUEST_SHELL_START_APP_ID | \
    SHADOW_GUEST_START_APP_ID | \
    SHADOW_GUEST_TOUCH_LATENCY_TRACE | \
    SHADOW_GUEST_TOUCH_SIGNAL_PATH | \
    SHADOW_SYSTEM_BINARY_PATH)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

pixel_guest_session_launch_env_lines() {
  local lines="${1:-}"
  local line=""
  local key=""

  pixel_validate_env_assignment_lines "guest startup session env" "$lines" || return 1
  [[ -n "$lines" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="${line%%=*}"
    if pixel_guest_session_env_assignment_is_config_owned "$key"; then
      continue
    fi
    printf '%s\n' "$line"
  done <<< "$lines"
}

pixel_guest_session_overlay_config_env_lines() {
  local lines="${1:-}"
  local line=""
  local key=""

  pixel_validate_env_assignment_lines "guest session overlay env" "$lines" || return 1
  [[ -n "$lines" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="${line%%=*}"
    if pixel_guest_session_env_assignment_is_config_owned "$key"; then
      printf '%s\n' "$line"
    fi
  done <<< "$lines"
}

pixel_guest_session_overlay_passthrough_env_lines() {
  local lines="${1:-}"
  local line=""
  local key=""

  pixel_validate_env_assignment_lines "guest session overlay env" "$lines" || return 1
  [[ -n "$lines" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="${line%%=*}"
    if ! pixel_guest_session_env_assignment_is_config_owned "$key"; then
      printf '%s\n' "$line"
    fi
  done <<< "$lines"
}

pixel_write_guest_ui_startup_config() {
  local output_path="$1"
  local runtime_dir="$2"
  local client_dst="$3"
  local compositor_exit_on_first_frame="${4:-}"
  local compositor_exit_on_client_disconnect="${5:-}"
  local client_exit_on_configure="${6:-}"
  local guest_client_env="${7:-}"
  local guest_session_env="${8:-}"
  local frame_artifact_path="${9:-}"
  local frame_capture_mode="${10:-off}"

  pixel_validate_env_assignment_lines "guest client env" "$guest_client_env" || return 1
  pixel_validate_env_assignment_lines "guest startup session env" "$guest_session_env" || return 1

  PIXEL_GUEST_STARTUP_OUTPUT_PATH="$output_path" \
  PIXEL_GUEST_STARTUP_RUNTIME_DIR="$runtime_dir" \
  PIXEL_GUEST_STARTUP_CLIENT_DST="$client_dst" \
  PIXEL_GUEST_STARTUP_COMPOSITOR_EXIT_ON_FIRST_FRAME="$compositor_exit_on_first_frame" \
  PIXEL_GUEST_STARTUP_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT="$compositor_exit_on_client_disconnect" \
  PIXEL_GUEST_STARTUP_CLIENT_EXIT_ON_CONFIGURE="$client_exit_on_configure" \
  PIXEL_GUEST_STARTUP_CLIENT_ENV="$guest_client_env" \
  PIXEL_GUEST_STARTUP_SESSION_ENV="$guest_session_env" \
  PIXEL_GUEST_STARTUP_FRAME_ARTIFACT_PATH="$frame_artifact_path" \
  PIXEL_GUEST_STARTUP_FRAME_CAPTURE_MODE="$frame_capture_mode" \
    python3 - <<'PY'
import json
import os
import sys


def parse_env_lines(label, raw_lines):
    lines = []
    for raw_line in raw_lines.splitlines():
        if not raw_line:
            continue
        if "=" not in raw_line:
            raise SystemExit(f"pixel: invalid {label} assignment (missing '='): {raw_line}")
        key, value = raw_line.split("=", 1)
        if not key or key[0].isdigit() or any(
            ch not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
            for ch in key
        ):
            raise SystemExit(f"pixel: invalid {label} key: {key}")
        lines.append((key, value))
    return lines


def parse_bool_text(raw_value):
    if raw_value is None:
        return None
    value = raw_value.strip().lower()
    if value in {"1", "true", "on"}:
        return True
    if value in {"0", "false", "off"}:
        return False
    return None


def parse_optional_int(label, raw_value):
    value = raw_value.strip()
    if not value:
        return None
    try:
        return int(value)
    except ValueError as error:
        raise SystemExit(f"pixel: invalid {label}: {raw_value!r}: {error}") from error


output_path = os.environ["PIXEL_GUEST_STARTUP_OUTPUT_PATH"]
runtime_dir = os.environ["PIXEL_GUEST_STARTUP_RUNTIME_DIR"]
client_dst = os.environ["PIXEL_GUEST_STARTUP_CLIENT_DST"]
client_env_lines = parse_env_lines(
    "guest client env",
    os.environ.get("PIXEL_GUEST_STARTUP_CLIENT_ENV", ""),
)
session_env_lines = parse_env_lines(
    "guest startup session env",
    os.environ.get("PIXEL_GUEST_STARTUP_SESSION_ENV", ""),
)
session_env = {key: value for key, value in session_env_lines}
frame_capture_mode = os.environ.get("PIXEL_GUEST_STARTUP_FRAME_CAPTURE_MODE", "off").strip()
frame_artifact_path = os.environ.get("PIXEL_GUEST_STARTUP_FRAME_ARTIFACT_PATH", "").strip()

if frame_capture_mode not in {"publish", "request", "off"}:
    raise SystemExit(
        "pixel: unsupported frame capture mode for startup config: "
        f"{frame_capture_mode or '<empty>'}"
    )

client_env_assignments = []
system_binary_path = None
software_keyboard_enabled = None
for key, value in client_env_lines:
    if key == "SHADOW_SYSTEM_BINARY_PATH":
        if value.strip():
            system_binary_path = value
        continue
    if key == "SHADOW_BLITZ_SOFTWARE_KEYBOARD":
        parsed = parse_bool_text(value)
        if parsed is not None:
            software_keyboard_enabled = parsed
    client_env_assignments.append({"key": key, "value": value})

if system_binary_path is None:
    candidate = session_env.get("SHADOW_SYSTEM_BINARY_PATH", "").strip()
    if candidate:
        system_binary_path = candidate
client_path_override = session_env.get("SHADOW_GUEST_CLIENT", "").strip()
if client_path_override:
    client_dst = client_path_override

startup = {"mode": "client"}
start_app_id = session_env.get("SHADOW_GUEST_START_APP_ID", "").strip()
shell_start_app_id = session_env.get("SHADOW_GUEST_SHELL_START_APP_ID", "").strip()
if start_app_id == "shell":
    startup["mode"] = "shell"
    if shell_start_app_id:
        startup["shellStartAppId"] = shell_start_app_id
elif start_app_id:
    startup["mode"] = "app"
    startup["startAppId"] = start_app_id
elif shell_start_app_id:
    startup["mode"] = "shell"
    startup["shellStartAppId"] = shell_start_app_id

compositor = {
    "transport": session_env.get("SHADOW_GUEST_COMPOSITOR_TRANSPORT", "direct"),
    "enableDrm": True,
}
if (
    os.environ.get("PIXEL_GUEST_STARTUP_COMPOSITOR_EXIT_ON_FIRST_FRAME")
    or "SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME" in session_env
):
    compositor["exitOnFirstFrame"] = True
if (
    os.environ.get("PIXEL_GUEST_STARTUP_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT")
    or "SHADOW_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT" in session_env
):
    compositor["exitOnClientDisconnect"] = True
if "SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_DMA_BUFFER" in session_env:
    compositor["exitOnFirstDmaBuffer"] = True
if "SHADOW_GUEST_COMPOSITOR_BOOT_SPLASH_DRM" in session_env:
    compositor["bootSplashDrm"] = True
if "SHADOW_GUEST_COMPOSITOR_GPU_SHELL" in session_env:
    compositor["gpuShell"] = True
if "SHADOW_GUEST_COMPOSITOR_STRICT_GPU_RESIDENT" in session_env:
    compositor["strictGpuResident"] = True
if "SHADOW_GUEST_COMPOSITOR_DISABLE_DMABUF_GLOBAL" in session_env:
    compositor["dmabufGlobalEnabled"] = False
if "SHADOW_GUEST_COMPOSITOR_DMABUF_FEEDBACK" in session_env:
    compositor["dmabufFeedbackEnabled"] = True
dmabuf_format_profile = session_env.get("SHADOW_GUEST_COMPOSITOR_DMABUF_FORMAT_PROFILE", "").strip()
if dmabuf_format_profile:
    compositor["dmabufFormatProfile"] = dmabuf_format_profile
background_app_limit = parse_optional_int(
    "SHADOW_GUEST_COMPOSITOR_BACKGROUND_APP_LIMIT",
    session_env.get("SHADOW_GUEST_COMPOSITOR_BACKGROUND_APP_LIMIT", ""),
)
if background_app_limit is not None:
    compositor["backgroundAppResidentLimit"] = background_app_limit
if software_keyboard_enabled is not None:
    compositor["softwareKeyboardEnabled"] = software_keyboard_enabled

frame_capture = {}
session_frame_artifact_path = session_env.get("SHADOW_GUEST_FRAME_PATH", "").strip()
if session_frame_artifact_path:
    frame_artifact_path = session_frame_artifact_path
if frame_capture_mode == "publish":
    frame_capture["mode"] = "first-frame"
elif frame_capture_mode == "request":
    frame_capture["snapshotCache"] = True
elif "SHADOW_GUEST_FRAME_SNAPSHOT_CACHE" in session_env:
    frame_capture["snapshotCache"] = True
elif "SHADOW_GUEST_FRAME_ARTIFACTS" in session_env:
    if "SHADOW_GUEST_FRAME_WRITE_EVERY_FRAME" in session_env:
        frame_capture["mode"] = "every-frame"
    else:
        frame_capture["mode"] = "first-frame"
if "SHADOW_GUEST_FRAME_CHECKSUM" in session_env:
    frame_capture["checksum"] = True
if frame_artifact_path:
    frame_capture["artifactPath"] = frame_artifact_path
if frame_capture:
    compositor["frameCapture"] = frame_capture

window = {}
surface_width = session_env.get("SHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH", "").strip()
surface_height = session_env.get("SHADOW_GUEST_COMPOSITOR_TOPLEVEL_HEIGHT", "").strip()
surface_width_value = parse_optional_int(
    "SHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH",
    surface_width,
)
surface_height_value = parse_optional_int(
    "SHADOW_GUEST_COMPOSITOR_TOPLEVEL_HEIGHT",
    surface_height,
)
if surface_width_value is not None:
    window["surfaceWidth"] = surface_width_value
if surface_height_value is not None:
    window["surfaceHeight"] = surface_height_value

touch = {}
touch_signal_path = session_env.get("SHADOW_GUEST_TOUCH_SIGNAL_PATH")
if touch_signal_path is not None and touch_signal_path.strip():
    touch["signalPath"] = touch_signal_path
if "SHADOW_GUEST_TOUCH_LATENCY_TRACE" in session_env:
    touch["latencyTrace"] = True

client = {
    "appClientPath": client_dst,
    "runtimeDir": runtime_dir,
}
client_linger_ms = parse_optional_int(
    "SHADOW_GUEST_CLIENT_LINGER_MS",
    session_env.get("SHADOW_GUEST_CLIENT_LINGER_MS", ""),
)
if client_linger_ms is not None:
    client["lingerMs"] = client_linger_ms
else:
    client["lingerMs"] = 500
if system_binary_path is not None:
    client["systemBinaryPath"] = system_binary_path
if client_env_assignments:
    client["envAssignments"] = client_env_assignments
if (
    os.environ.get("PIXEL_GUEST_STARTUP_CLIENT_EXIT_ON_CONFIGURE")
    or "SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE" in session_env
):
    client["exitOnConfigure"] = True

config = {
    "schemaVersion": 1,
    "startup": startup,
    "client": client,
    "compositor": compositor,
}
if touch:
    config["touch"] = touch
if window:
    config["window"] = window

with open(output_path, "w", encoding="utf-8") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
PY
}

pixel_push_device_file_verified() {
  local serial="$1"
  local host_path="$2"
  local device_path="$3"
  local mode="${4:-0644}"
  local device_dir=""
  local tmp_path=""
  local host_sum=""
  local device_sum=""

  if [[ ! -f "$host_path" ]]; then
    echo "pixel: missing host file for push: $host_path" >&2
    return 1
  fi

  device_dir="${device_path%/*}"
  tmp_path="/data/local/tmp/.$(basename "$device_path").push.$$"
  host_sum="$(shasum -a 256 "$host_path" | awk '{print $1}')"

  pixel_adb "$serial" shell "rm -f '$tmp_path'" >/dev/null
  pixel_adb "$serial" push "$host_path" "$tmp_path" >/dev/null
  device_sum="$(
    pixel_adb "$serial" shell "toybox sha256sum '$tmp_path'" 2>/dev/null \
      | tr -d '\r' \
      | awk 'NR == 1 { print $1 }'
  )"
  if [[ -z "$device_sum" || "$device_sum" != "$host_sum" ]]; then
    pixel_adb "$serial" shell "rm -f '$tmp_path'" >/dev/null 2>&1 || true
    echo "pixel: checksum mismatch while pushing $device_path" >&2
    echo "pixel: host checksum=$host_sum device checksum=${device_sum:-missing}" >&2
    return 1
  fi

  pixel_root_shell "$serial" \
    "mkdir -p '$device_dir' && mv '$tmp_path' '$device_path' && chown shell:shell '$device_path' && chmod $mode '$device_path'"
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
