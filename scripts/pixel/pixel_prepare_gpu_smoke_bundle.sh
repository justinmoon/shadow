#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
# shellcheck source=./pixel_runtime_linux_bundle_common.sh
source "$SCRIPT_DIR/lib/pixel_runtime_linux_bundle_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs

repo="$(repo_root)"
bundle_dir="$(pixel_artifact_path shadow-gpu-smoke-gnu)"
bundle_out_link="$(pixel_dir)/shadow-gpu-smoke-aarch64-linux-gnu-result"
launcher_artifact="$(pixel_artifact_path run-shadow-gpu-smoke)"
bundle_manifest="$bundle_dir/.bundle-manifest.json"
bundle_device_dir="${PIXEL_GPU_SMOKE_DEVICE_DIR:-/data/local/tmp/shadow-gpu-smoke-gnu}"
package_system="${PIXEL_LINUX_BUILD_SYSTEM:-aarch64-linux}"
package_ref="$repo#packages.${package_system}.shadow-gpu-smoke-aarch64-linux-gnu"
turnip_package_ref="$repo#packages.${package_system}.shadow-pinned-turnip-mesa-aarch64-linux"
turnip_lib_path="${PIXEL_VENDOR_TURNIP_LIB_PATH-}"
turnip_lib_path="$(normalize_runtime_bundle_input_path "$turnip_lib_path")"

if [[ -z "$turnip_lib_path" ]]; then
  turnip_lib_path="$(pixel_ensure_pinned_turnip_lib)"
fi

bundle_fingerprint="$(
  runtime_bundle_source_fingerprint \
    "$package_ref" \
    "__bundle_device_dir_${bundle_device_dir}__" \
    "$repo/flake.nix" \
    "$repo/ui/Cargo.toml" \
    "$repo/ui/Cargo.lock" \
    "$repo/ui/crates/shadow-gpu-smoke" \
    "$repo/ui/third_party/wgpu_context" \
    "$SCRIPT_DIR/pixel/pixel_prepare_gpu_smoke_bundle.sh" \
    "$SCRIPT_DIR/lib/pixel_runtime_linux_bundle_common.sh" \
    "$turnip_lib_path"
)"

emit_bundle_metadata() {
  local cache_hit="$1"
  python3 - "$bundle_dir" "$launcher_artifact" "$bundle_device_dir" "$package_ref" "$turnip_lib_path" "$cache_hit" <<'PY'
import json
import os
import sys

bundle_dir, launcher_artifact, bundle_device_dir, package_ref, turnip_lib_path, cache_hit = sys.argv[1:7]
print(json.dumps({
    "bundleArtifactDir": os.path.abspath(bundle_dir),
    "bundleDeviceDir": bundle_device_dir,
    "cacheHit": cache_hit == "1",
    "clientLauncherArtifact": os.path.abspath(launcher_artifact),
    "clientLauncherDevicePath": f"{bundle_device_dir}/run-shadow-gpu-smoke",
    "packageRef": package_ref,
    "turnipLibPath": turnip_lib_path,
}, indent=2))
PY
}

reuse_cached_gpu_smoke_bundle() {
  if [[ "${PIXEL_FORCE_LINUX_BUNDLE_REBUILD-}" == 1 ]]; then
    return 1
  fi

  [[ -d "$bundle_dir" ]] || return 1
  [[ -f "$bundle_dir/shadow-gpu-smoke" ]] || return 1
  [[ -f "$bundle_dir/lib/libvulkan.so.1" || -f "$bundle_dir/lib/libvulkan.so" ]] || return 1
  [[ -f "$bundle_dir/lib/libvulkan_freedreno.so" ]] || return 1
  [[ -f "$bundle_dir/share/vulkan/icd.d/freedreno_icd.aarch64.json" ]] || return 1
  [[ -x "$launcher_artifact" ]] || return 1

  runtime_bundle_manifest_matches "$bundle_manifest" "$bundle_fingerprint" || return 1
  emit_bundle_metadata 1
}

copy_optional_tree_from_closure() {
  local relative_path closure_path source_path destination_path
  relative_path="$1"

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

  return 1
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

overlay_turnip_lib() {
  if [[ ! -f "$turnip_lib_path" ]]; then
    echo "pixel_prepare_gpu_smoke_bundle: missing turnip lib: $turnip_lib_path" >&2
    return 1
  fi

  mkdir -p "$bundle_dir/lib"
  cp -Lf "$turnip_lib_path" "$bundle_dir/lib/libvulkan_freedreno.so"
}

stage_vulkan_loader() {
  rm -f "$bundle_dir/lib/libvulkan.so" "$bundle_dir/lib/libvulkan.so.1"
  copy_runtime_optional_lib "libvulkan.so" "$bundle_dir/lib"
  copy_runtime_optional_lib "libvulkan.so.1" "$bundle_dir/lib"
}

rewrite_vulkan_icd_manifest() {
  local vulkan_dir freedreno_json
  vulkan_dir="$bundle_dir/share/vulkan/icd.d"
  freedreno_json="$vulkan_dir/freedreno_icd.aarch64.json"

  mkdir -p "$vulkan_dir"
  chmod -R u+w "$vulkan_dir" 2>/dev/null || true
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
}

if reuse_cached_gpu_smoke_bundle; then
  exit 0
fi

stage_system_linux_bundle "$package_ref" "$bundle_out_link" "$bundle_dir" "shadow-gpu-smoke"

chmod -R u+w "$bundle_dir" 2>/dev/null || true
append_runtime_closure_from_package_ref "$turnip_package_ref"
stage_vulkan_loader
overlay_turnip_lib
flatten_bundle_file_symlinks
fill_linux_bundle_runtime_deps "$bundle_dir"
rewrite_vulkan_icd_manifest

cat >"$launcher_artifact" <<EOF
#!/system/bin/sh
DIR=\$(cd "\$(dirname "\$0")" && pwd)

unset LD_PRELOAD

export HOME="\$DIR/home"
export XDG_CACHE_HOME="\$HOME/.cache"
export XDG_CONFIG_HOME="\$HOME/.config"
export MESA_SHADER_CACHE_DIR="\$XDG_CACHE_HOME/mesa"
export LD_LIBRARY_PATH="\$DIR/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export WGPU_BACKEND="\${WGPU_BACKEND:-vulkan}"
export VK_ICD_FILENAMES="\${VK_ICD_FILENAMES:-\$DIR/share/vulkan/icd.d/freedreno_icd.aarch64.json}"
export MESA_LOADER_DRIVER_OVERRIDE="\${MESA_LOADER_DRIVER_OVERRIDE:-kgsl}"
export TU_DEBUG="\${TU_DEBUG:-noconform}"

mkdir -p "\$HOME" "\$XDG_CACHE_HOME" "\$XDG_CONFIG_HOME" "\$MESA_SHADER_CACHE_DIR"

exec "\$DIR/lib/$PIXEL_RUNTIME_STAGE_LOADER_NAME" --library-path "\$DIR/lib" "\$DIR/shadow-gpu-smoke" "\$@"
EOF
chmod 0755 "$launcher_artifact"

write_runtime_bundle_manifest \
  "$bundle_manifest" \
  "$bundle_fingerprint" \
  "$package_ref" \
  "" \
  "" \
  "$turnip_lib_path"

emit_bundle_metadata 0
