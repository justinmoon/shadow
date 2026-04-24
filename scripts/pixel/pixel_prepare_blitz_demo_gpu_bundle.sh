#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./pixel_runtime_linux_bundle_common.sh
source "$SCRIPT_DIR/lib/pixel_runtime_linux_bundle_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs
if [[ -z "${PIXEL_VENDOR_TURNIP_LIB_PATH-}" && -z "${PIXEL_VENDOR_TURNIP_TARBALL-}" ]]; then
  PIXEL_VENDOR_TURNIP_LIB_PATH="$(pixel_ensure_pinned_turnip_lib)"
  export PIXEL_VENDOR_TURNIP_LIB_PATH
fi
repo="$(repo_root)"
bundle_dir="$(pixel_artifact_path shadow-blitz-demo-gpu-gnu)"
bundle_out_link="$(pixel_dir)/shadow-blitz-demo-aarch64-linux-gnu-gpu-result"
launcher_artifact="$(pixel_artifact_path run-shadow-blitz-demo-gpu)"
openlog_preload_artifact="$(pixel_artifact_path shadow-openlog-preload.so)"
bundle_mode="${PIXEL_BLITZ_GPU_BUNDLE_MODE:-full}"
vendor_mesa_tarball="${PIXEL_VENDOR_MESA_TARBALL-}"
vendor_turnip_tarball="${PIXEL_VENDOR_TURNIP_TARBALL-}"
vendor_turnip_lib_path="${PIXEL_VENDOR_TURNIP_LIB_PATH-}"
vendor_mesa_tarball="$(normalize_runtime_bundle_input_path "$vendor_mesa_tarball")"
vendor_turnip_tarball="$(normalize_runtime_bundle_input_path "$vendor_turnip_tarball")"
vendor_turnip_lib_path="$(normalize_runtime_bundle_input_path "$vendor_turnip_lib_path")"
package_system="${PIXEL_LINUX_BUILD_SYSTEM:-aarch64-linux}"
package_ref="$repo#packages.${package_system}.shadow-blitz-demo-aarch64-linux-gnu-gpu"
bundle_device_dir="$(pixel_runtime_linux_dir)"
bundle_manifest="$bundle_dir/.bundle-manifest.json"
xkb_source_dir="$(runtime_bundle_xkb_source_dir)"
android_font_source_dir="$(runtime_bundle_android_font_source_dir)"
vendor_mesa_package_refs=(
  "nixpkgs#pkgsCross.aarch64-multiplatform.libx11"
  "nixpkgs#pkgsCross.aarch64-multiplatform.libxcb"
  "nixpkgs#pkgsCross.aarch64-multiplatform.libxshmfence"
  "nixpkgs#pkgsCross.aarch64-multiplatform.llvmPackages_19.libllvm"
  "nixpkgs#pkgsCross.aarch64-multiplatform.zstd.out"
  "nixpkgs#pkgsCross.aarch64-multiplatform.lm_sensors.out"
)
vendor_turnip_package_refs=(
  "nixpkgs#pkgsCross.aarch64-multiplatform.libx11"
  "nixpkgs#pkgsCross.aarch64-multiplatform.libxcb"
  "nixpkgs#pkgsCross.aarch64-multiplatform.libxcb-keysyms"
  "nixpkgs#pkgsCross.aarch64-multiplatform.libxshmfence"
  "nixpkgs#pkgsCross.aarch64-multiplatform.zstd.out"
  "nixpkgs#pkgsCross.aarch64-multiplatform.stdenv.cc.cc.lib"
)
bundle_fingerprint="$(
  runtime_bundle_source_fingerprint \
    "$package_ref" \
    "__bundle_mode_${bundle_mode}__" \
    "$repo/flake.nix" \
    "$repo/ui/Cargo.toml" \
    "$repo/ui/Cargo.lock" \
    "$repo/ui/apps/shadow-blitz-demo" \
    "$repo/ui/third_party/anyrender_vello" \
    "$repo/ui/third_party/wgpu_context" \
    "$SCRIPT_DIR/pixel/pixel_prepare_blitz_demo_gpu_bundle.sh" \
    "$SCRIPT_DIR/lib/pixel_runtime_linux_bundle_common.sh" \
    "$SCRIPT_DIR/pixel/pixel_build_openlog_preload.sh" \
    "$SCRIPT_DIR/pixel/pixel_openlog_preload.c" \
    "$xkb_source_dir" \
    "$android_font_source_dir" \
    "${vendor_mesa_tarball:-__no_vendor_mesa__}" \
    "${vendor_turnip_tarball:-__no_vendor_turnip__}" \
    "${vendor_turnip_lib_path:-__no_vendor_turnip_lib__}"
)"

if reuse_cached_runtime_bundle \
  "$bundle_manifest" \
  "$bundle_fingerprint" \
  "$bundle_dir" \
  "$launcher_artifact" \
  "$bundle_device_dir/run-shadow-blitz-demo" \
  "$package_ref"; then
  exit 0
fi

copy_optional_tree_from_closure() {
  local relative_path closure_path source_path destination_path copied
  relative_path="$1"
  copied=0

  for closure_path in "${PIXEL_RUNTIME_CLOSURE_PATHS[@]}"; do
    source_path="$closure_path/$relative_path"
    if [[ ! -d "$source_path" ]]; then
      continue
    fi

    destination_path="$bundle_dir/$relative_path"
    mkdir -p "$destination_path"
    chmod -R u+w "$destination_path" 2>/dev/null || true
    cp -R "$source_path"/. "$destination_path"/
    return 0
  done

  return "$copied"
}

flatten_bundle_file_symlinks() {
  local symlink_path temp_path

  while IFS= read -r symlink_path; do
    [[ -L "$symlink_path" ]] || continue
    if [[ -d "$symlink_path" ]]; then
      continue
    fi

    temp_path="$(mktemp "${symlink_path}.XXXXXX")"
    cp -L "$symlink_path" "$temp_path"
    rm "$symlink_path"
    mv "$temp_path" "$symlink_path"
  done < <(find "$bundle_dir" -type l -print)
}

copy_runtime_libs_from_package_output() {
  local runtime_libs_root source_path destination_path
  runtime_libs_root="$bundle_out_link/runtime-libs"

  if [[ ! -d "$runtime_libs_root" ]]; then
    return 0
  fi

  while IFS= read -r -d '' source_path; do
    destination_path="$bundle_dir/lib/$(basename "$source_path")"
    if [[ -e "$destination_path" ]]; then
      continue
    fi
    cp -L "$source_path" "$destination_path"
  done < <(find -L "$runtime_libs_root" -path '*/lib/*.so*' -type f -print0)
}

rewrite_bundle_driver_manifests() {
  local vulkan_dir egl_dir freedreno_json mesa_json
  vulkan_dir="$bundle_dir/share/vulkan/icd.d"
  egl_dir="$bundle_dir/share/glvnd/egl_vendor.d"
  freedreno_json="$vulkan_dir/freedreno_icd.aarch64.json"
  mesa_json="$egl_dir/50_mesa.json"

  chmod -R u+w "$vulkan_dir" "$egl_dir" 2>/dev/null || true

  if [[ -d "$vulkan_dir" ]]; then
    find "$vulkan_dir" -maxdepth 1 -type f ! -name 'freedreno_icd.aarch64.json' -delete
    cat >"$freedreno_json" <<EOF
{
    "ICD": {
        "api_version": "1.4.335",
        "library_arch": "64",
        "library_path": "${bundle_device_dir}/lib/libvulkan_freedreno.so"
    },
    "file_format_version": "1.0.1"
}
EOF
  fi

  if [[ -d "$egl_dir" ]]; then
    find "$egl_dir" -maxdepth 1 -type f ! -name '50_mesa.json' -delete
    cat >"$mesa_json" <<EOF
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "${bundle_device_dir}/lib/libEGL_mesa.so.0"
    }
}
EOF
  fi
}

stage_openlog_preload() {
  "$SCRIPT_DIR/pixel/pixel_build_openlog_preload.sh"
  mkdir -p "$bundle_dir/lib"
  cp -L "$openlog_preload_artifact" "$bundle_dir/lib/shadow-openlog-preload.so"
}

copy_vulkan_loader_from_closure() {
  mkdir -p "$bundle_dir/lib"
  copy_runtime_optional_lib "libvulkan.so" "$bundle_dir/lib"
  copy_runtime_optional_lib "libvulkan.so.1" "$bundle_dir/lib"
}

overlay_vendor_mesa_tarball() {
  local tarball="$1"
  local temp_dir="$bundle_dir/.vendor-mesa-overlay"
  local source_root

  [[ -n "$tarball" ]] || return 0
  if [[ ! -f "$tarball" ]]; then
    echo "pixel_prepare_blitz_demo_gpu_bundle: missing PIXEL_VENDOR_MESA_TARBALL: $tarball" >&2
    return 1
  fi

  rm -rf "$temp_dir"
  mkdir -p "$temp_dir"
  tar -xzf "$tarball" -C "$temp_dir"
  source_root="$temp_dir/usr"

  chmod -R u+w "$bundle_dir" 2>/dev/null || true
  mkdir -p "$bundle_dir/lib" "$bundle_dir/lib/dri" "$bundle_dir/share/vulkan/icd.d" \
    "$bundle_dir/share/glvnd/egl_vendor.d" "$bundle_dir/share/drirc.d"

  if [[ -d "$source_root/lib/aarch64-linux-gnu" ]]; then
    find "$source_root/lib/aarch64-linux-gnu" -maxdepth 1 -type f \
      \( \
        -name 'libEGL*' -o \
        -name 'libGLES*' -o \
        -name 'libGLX_mesa*' -o \
        -name 'libgallium*' -o \
        -name 'libglapi*' -o \
        -name 'libgbm*' -o \
        -name 'libvulkan_freedreno.so*' -o \
        -name 'libwayland-egl.so*' -o \
        -name 'dri_gbm.so' -o \
        -name '*_dri.so' \
      \) \
      -exec cp -Lf {} "$bundle_dir/lib/" \;

    if [[ -d "$source_root/lib/aarch64-linux-gnu/dri" ]]; then
      cp -LRf "$source_root/lib/aarch64-linux-gnu/dri"/. "$bundle_dir/lib/dri"/
    fi
  fi

  if [[ -d "$source_root/share/vulkan/icd.d" ]]; then
    cp -LRf "$source_root/share/vulkan/icd.d"/. "$bundle_dir/share/vulkan/icd.d"/
  fi
  if [[ -d "$source_root/share/glvnd/egl_vendor.d" ]]; then
    cp -LRf "$source_root/share/glvnd/egl_vendor.d"/. "$bundle_dir/share/glvnd/egl_vendor.d"/
  fi
  if [[ -d "$source_root/share/drirc.d" ]]; then
    cp -LRf "$source_root/share/drirc.d"/. "$bundle_dir/share/drirc.d"/
  fi

  rm -rf "$temp_dir"
}

append_vendor_mesa_runtime_closure() {
  local package_ref

  [[ -n "$vendor_mesa_tarball" ]] || return 0
  for package_ref in "${vendor_mesa_package_refs[@]}"; do
    append_runtime_closure_from_package_ref "$package_ref"
  done
}

append_vendor_turnip_runtime_closure() {
  local package_ref

  [[ -n "$vendor_turnip_tarball" || -n "$vendor_turnip_lib_path" ]] || return 0
  for package_ref in "${vendor_turnip_package_refs[@]}"; do
    append_runtime_closure_from_package_ref "$package_ref"
  done
}

overlay_vendor_turnip_tarball() {
  local tarball="$1"

  [[ -n "$tarball" ]] || return 0
  if [[ ! -f "$tarball" ]]; then
    echo "pixel_prepare_blitz_demo_gpu_bundle: missing PIXEL_VENDOR_TURNIP_TARBALL: $tarball" >&2
    return 1
  fi

  mkdir -p "$bundle_dir/lib" "$bundle_dir/share/vulkan/icd.d" "$bundle_dir/share/drirc.d"
  tar -xzf "$tarball" -C "$bundle_dir/lib" \
    --strip-components=4 \
    ./usr/lib/aarch64-linux-gnu/libvulkan_freedreno.so
  tar -xzf "$tarball" -C "$bundle_dir/share/vulkan/icd.d" \
    --strip-components=5 \
    ./usr/share/vulkan/icd.d/freedreno_icd.aarch64.json
  if tar -tzf "$tarball" | grep -Fq './usr/share/drirc.d/00-mesa-defaults.conf'; then
    tar -xzf "$tarball" -C "$bundle_dir/share/drirc.d" \
      --strip-components=4 \
      ./usr/share/drirc.d/00-mesa-defaults.conf
  fi
}

overlay_vendor_turnip_lib_path() {
  local lib_path="$1"

  [[ -n "$lib_path" ]] || return 0
  if [[ ! -f "$lib_path" ]]; then
    echo "pixel_prepare_blitz_demo_gpu_bundle: missing PIXEL_VENDOR_TURNIP_LIB_PATH: $lib_path" >&2
    return 1
  fi

  mkdir -p "$bundle_dir/lib"
  cp -Lf "$lib_path" "$bundle_dir/lib/libvulkan_freedreno.so"
}

stage_system_linux_bundle "$package_ref" "$bundle_out_link" "$bundle_dir" "shadow-blitz-demo"

chmod -R u+w "$bundle_dir" 2>/dev/null || true
stage_openlog_preload
if [[ "$bundle_mode" == "vulkan-only" ]]; then
  copy_vulkan_loader_from_closure
else
  copy_runtime_libs_from_package_output
  copy_optional_tree_from_closure "lib/dri" || true
  copy_optional_tree_from_closure "share/vulkan/icd.d" || true
  copy_optional_tree_from_closure "share/glvnd/egl_vendor.d" || true
  append_vendor_mesa_runtime_closure
fi
append_vendor_turnip_runtime_closure
if [[ "$bundle_mode" != "vulkan-only" ]]; then
  overlay_vendor_mesa_tarball "$vendor_mesa_tarball"
fi
overlay_vendor_turnip_tarball "$vendor_turnip_tarball"
overlay_vendor_turnip_lib_path "$vendor_turnip_lib_path"
flatten_bundle_file_symlinks
chmod -R u+w "$bundle_dir" 2>/dev/null || true
fill_linux_bundle_runtime_deps "$bundle_dir"
rewrite_bundle_driver_manifests
stage_runtime_bundle_xkb_config "$bundle_dir"
stage_runtime_bundle_android_fonts "$bundle_dir"

cat >"$launcher_artifact" <<EOF
#!/system/bin/sh
DIR=\$(cd "\$(dirname "\$0")" && pwd)
GNU_LD_PRELOAD="\${SHADOW_LINUX_LD_PRELOAD:-}"
SYSTEM_PATH="\${SHADOW_SYSTEM_BINARY_PATH:-}"
RUNTIME_BUNDLE_PATH="\${SHADOW_RUNTIME_APP_BUNDLE_PATH:-}"

unset LD_PRELOAD

export HOME="\${HOME:-\$DIR/home}"
export XDG_CACHE_HOME="\${XDG_CACHE_HOME:-\$HOME/.cache}"
export XDG_CONFIG_HOME="\${XDG_CONFIG_HOME:-\$HOME/.config}"
export MESA_SHADER_CACHE_DIR="\${MESA_SHADER_CACHE_DIR:-\$XDG_CACHE_HOME/mesa}"
export LD_LIBRARY_PATH="\$DIR/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export LIBGL_DRIVERS_PATH="\$DIR/lib/dri\${LIBGL_DRIVERS_PATH:+:\$LIBGL_DRIVERS_PATH}"
export __EGL_VENDOR_LIBRARY_DIRS="\$DIR/share/glvnd/egl_vendor.d"
export WGPU_BACKEND="\${WGPU_BACKEND:-vulkan}"
export VK_ICD_FILENAMES="\$DIR/share/vulkan/icd.d/freedreno_icd.aarch64.json"

mkdir -p "\$HOME" "\$XDG_CACHE_HOME" "\$XDG_CONFIG_HOME" "\$MESA_SHADER_CACHE_DIR"

export XKB_CONFIG_EXTRA_PATH="\${XKB_CONFIG_EXTRA_PATH:-\$DIR/etc/xkb}"
export XKB_CONFIG_ROOT="\${XKB_CONFIG_ROOT:-\$DIR/share/X11/xkb}"
export SHADOW_RUNTIME_AUDIO_BRIDGE_BINARY="\$DIR/shadow-audio-bridge"
export SHADOW_RUNTIME_AUDIO_SPIKE_BINARY="\$SHADOW_RUNTIME_AUDIO_BRIDGE_BINARY"
export SHADOW_RUNTIME_AUDIO_SPIKE_STAGE_LOADER_PATH="\$DIR/lib/$PIXEL_RUNTIME_STAGE_LOADER_NAME"
export SHADOW_RUNTIME_AUDIO_SPIKE_STAGE_LIBRARY_PATH="\$DIR/lib"
export ALSA_CONFIG_PATH="\$DIR/share/alsa/alsa.conf"
export ALSA_CONFIG_DIR="\$DIR/share/alsa"
export ALSA_CONFIG_UCM="\$DIR/share/alsa/ucm"
export ALSA_CONFIG_UCM2="\$DIR/share/alsa/ucm2"
export ALSA_PLUGIN_DIR="\$DIR/lib/alsa-lib"
if [ -n "\$GNU_LD_PRELOAD" ]; then
  exec env LD_PRELOAD="\$GNU_LD_PRELOAD" "\$DIR/lib/$PIXEL_RUNTIME_STAGE_LOADER_NAME" --library-path "\$DIR/lib" "\$DIR/shadow-blitz-demo" "\$@"
fi

exec "\$DIR/lib/$PIXEL_RUNTIME_STAGE_LOADER_NAME" --library-path "\$DIR/lib" "\$DIR/shadow-blitz-demo" "\$@"
EOF
chmod 0755 "$launcher_artifact"
write_runtime_bundle_manifest \
  "$bundle_manifest" \
  "$bundle_fingerprint" \
  "$package_ref" \
  "$vendor_mesa_tarball" \
  "$vendor_turnip_tarball" \
  "$vendor_turnip_lib_path"

python3 - "$bundle_dir" "$launcher_artifact" "$bundle_device_dir" "$package_ref" <<'PY'
import json
import os
import sys

bundle_dir, launcher_artifact, bundle_device_dir, package_ref = sys.argv[1:5]
print(json.dumps({
    "bundleArtifactDir": os.path.abspath(bundle_dir),
    "bundleDeviceDir": bundle_device_dir,
    "clientLauncherArtifact": os.path.abspath(launcher_artifact),
    "clientLauncherDevicePath": f"{bundle_device_dir}/run-shadow-blitz-demo",
    "packageRef": package_ref,
}, indent=2))
PY
