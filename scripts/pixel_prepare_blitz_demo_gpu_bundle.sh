#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
# shellcheck source=./pixel_runtime_linux_bundle_common.sh
source "$SCRIPT_DIR/pixel_runtime_linux_bundle_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs
default_mesa_tarball="$(pixel_dir)/vendor/mesa-for-android-container_26.1.0-devel-20260404_debian_trixie_arm64.tar.gz"
default_turnip_tarball="$(pixel_dir)/vendor/turnip_26.1.0-devel-20260404_debian_trixie_arm64.tar.gz"
if [[ -z "${PIXEL_VENDOR_MESA_TARBALL-}" && -f "$default_mesa_tarball" ]]; then
  PIXEL_VENDOR_MESA_TARBALL="$default_mesa_tarball"
  export PIXEL_VENDOR_MESA_TARBALL
fi
if [[ -z "${PIXEL_VENDOR_TURNIP_TARBALL-}" && -f "$default_turnip_tarball" ]]; then
  PIXEL_VENDOR_TURNIP_TARBALL="$default_turnip_tarball"
  export PIXEL_VENDOR_TURNIP_TARBALL
fi
repo="$(repo_root)"
bundle_dir="$(pixel_artifact_path shadow-blitz-demo-gpu-gnu)"
bundle_out_link="$(pixel_dir)/shadow-blitz-demo-aarch64-linux-gnu-gpu-result"
launcher_artifact="$(pixel_artifact_path run-shadow-blitz-demo-gpu)"
openlog_preload_artifact="$(pixel_artifact_path shadow-openlog-preload.so)"
vendor_mesa_tarball="${PIXEL_VENDOR_MESA_TARBALL-}"
vendor_turnip_tarball="${PIXEL_VENDOR_TURNIP_TARBALL-}"
vendor_mesa_tarball="$(normalize_runtime_bundle_input_path "$vendor_mesa_tarball")"
vendor_turnip_tarball="$(normalize_runtime_bundle_input_path "$vendor_turnip_tarball")"
package_system="${PIXEL_LINUX_BUILD_SYSTEM:-aarch64-linux}"
package_ref="$repo#packages.${package_system}.shadow-blitz-demo-aarch64-linux-gnu-gpu"
bundle_device_dir="$(pixel_runtime_linux_dir)"
bundle_manifest="$bundle_dir/.bundle-manifest.json"
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
  "nixpkgs#pkgsCross.aarch64-multiplatform.libxshmfence"
  "nixpkgs#pkgsCross.aarch64-multiplatform.zstd.out"
  "nixpkgs#pkgsCross.aarch64-multiplatform.stdenv.cc.cc.lib"
)
bundle_fingerprint="$(
  runtime_bundle_source_fingerprint \
    "$package_ref" \
    "$repo/flake.nix" \
    "$repo/ui/Cargo.toml" \
    "$repo/ui/Cargo.lock" \
    "$repo/ui/apps/shadow-blitz-demo" \
    "$repo/ui/third_party/anyrender_vello" \
    "$repo/ui/third_party/softbuffer_window_renderer" \
    "$repo/ui/third_party/wgpu_context" \
    "$SCRIPT_DIR/pixel_prepare_blitz_demo_gpu_bundle.sh" \
    "$SCRIPT_DIR/pixel_runtime_linux_bundle_common.sh" \
    "$SCRIPT_DIR/pixel_build_openlog_preload.sh" \
    "$SCRIPT_DIR/pixel_openlog_preload.c" \
    "${vendor_mesa_tarball:-__no_vendor_mesa__}" \
    "${vendor_turnip_tarball:-__no_vendor_turnip__}"
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
  "$SCRIPT_DIR/pixel_build_openlog_preload.sh"
  mkdir -p "$bundle_dir/lib"
  cp -L "$openlog_preload_artifact" "$bundle_dir/lib/shadow-openlog-preload.so"
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

  [[ -n "$vendor_turnip_tarball" ]] || return 0
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

stage_runtime_host_linux_bundle "$package_ref" "$bundle_out_link" "$bundle_dir" "shadow-blitz-demo"

chmod -R u+w "$bundle_dir" 2>/dev/null || true
stage_openlog_preload
copy_runtime_libs_from_package_output
copy_optional_tree_from_closure "lib/dri" || true
copy_optional_tree_from_closure "share/vulkan/icd.d" || true
copy_optional_tree_from_closure "share/glvnd/egl_vendor.d" || true
append_vendor_mesa_runtime_closure
append_vendor_turnip_runtime_closure
overlay_vendor_mesa_tarball "$vendor_mesa_tarball"
overlay_vendor_turnip_tarball "$vendor_turnip_tarball"
rewrite_bundle_driver_manifests
flatten_bundle_file_symlinks
chmod -R u+w "$bundle_dir" 2>/dev/null || true
fill_linux_bundle_runtime_deps "$bundle_dir"

cat >"$launcher_artifact" <<EOF
#!/system/bin/sh
DIR=\$(cd "\$(dirname "\$0")" && pwd)
GNU_LD_PRELOAD="\${SHADOW_LINUX_LD_PRELOAD:-}"

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
  "$vendor_turnip_tarball"

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
