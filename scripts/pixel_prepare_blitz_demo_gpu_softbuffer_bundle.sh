#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
# shellcheck source=./pixel_runtime_linux_bundle_common.sh
source "$SCRIPT_DIR/pixel_runtime_linux_bundle_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs
repo="$(repo_root)"
bundle_dir="$(pixel_artifact_path shadow-blitz-demo-gnu)"
bundle_out_link="$(pixel_dir)/shadow-blitz-demo-aarch64-linux-gnu-gpu-softbuffer-result"
launcher_artifact="$(pixel_artifact_path run-shadow-blitz-demo-gpu-softbuffer)"
openlog_preload_artifact="$(pixel_artifact_path shadow-openlog-preload.so)"
package_system="${PIXEL_LINUX_BUILD_SYSTEM:-x86_64-linux}"
package_ref="$repo#packages.${package_system}.shadow-blitz-demo-aarch64-linux-gnu-gpu-softbuffer"
bundle_device_dir="$(pixel_runtime_linux_dir)"

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

stage_runtime_host_linux_bundle "$package_ref" "$bundle_out_link" "$bundle_dir" "shadow-blitz-demo"

chmod -R u+w "$bundle_dir" 2>/dev/null || true
stage_openlog_preload
copy_runtime_libs_from_package_output
copy_optional_tree_from_closure "lib/dri" || true
copy_optional_tree_from_closure "share/vulkan/icd.d" || true
copy_optional_tree_from_closure "share/glvnd/egl_vendor.d" || true
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
