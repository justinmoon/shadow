#!/usr/bin/env bash

runtime_bundle_file_hash() {
  local path
  path="$1"

  if [[ ! -f "$path" ]]; then
    printf 'missing\n'
    return 0
  fi

  shasum -a 256 "$path" | awk '{print $1}'
}

runtime_bundle_xkb_source_dir() {
  local xkb_store

  if [[ -n "${PIXEL_XKB_CONFIG_SOURCE_DIR-}" ]]; then
    printf '%s\n' "$PIXEL_XKB_CONFIG_SOURCE_DIR"
    return 0
  fi

  xkb_store="$(
    pixel_retry_nix_build_print_out_paths \
      nix build --accept-flake-config --no-link --print-out-paths 'nixpkgs#xkeyboard_config' \
      | tail -n 1
  )"
  PIXEL_XKB_CONFIG_SOURCE_DIR="$xkb_store/share/X11/xkb"
  export PIXEL_XKB_CONFIG_SOURCE_DIR

  if [[ ! -d "$PIXEL_XKB_CONFIG_SOURCE_DIR" ]]; then
    echo "pixel runtime bundle: missing xkeyboard-config data dir: $PIXEL_XKB_CONFIG_SOURCE_DIR" >&2
    return 1
  fi

  printf '%s\n' "$PIXEL_XKB_CONFIG_SOURCE_DIR"
}

runtime_bundle_android_font_source_dir() {
  local font_cache_dir roboto_store roboto_mono_store emoji_store
  local -a sources

  if [[ -n "${PIXEL_ANDROID_FONT_SOURCE_DIR-}" ]]; then
    printf '%s\n' "$PIXEL_ANDROID_FONT_SOURCE_DIR"
    return 0
  fi

  roboto_store="$(
    pixel_retry_nix_build_print_out_paths \
      nix build --accept-flake-config --no-link --print-out-paths 'nixpkgs#roboto' \
      | tail -n 1
  )"
  roboto_mono_store="$(
    pixel_retry_nix_build_print_out_paths \
      nix build --accept-flake-config --no-link --print-out-paths 'nixpkgs#roboto-mono' \
      | tail -n 1
  )"
  emoji_store="$(
    pixel_retry_nix_build_print_out_paths \
      nix build --accept-flake-config --no-link --print-out-paths 'nixpkgs#noto-fonts-color-emoji' \
      | tail -n 1
  )"
  font_cache_dir="$(pixel_dir)/vendor/android-fonts/nix-curated"

  mkdir -p "$font_cache_dir"
  sources=(
    "$roboto_store/share/fonts/truetype/Roboto-Regular.ttf:$font_cache_dir/DroidSans.ttf"
    "$roboto_store/share/fonts/truetype/Roboto-Bold.ttf:$font_cache_dir/DroidSans-Bold.ttf"
    "$roboto_mono_store/share/fonts/truetype/RobotoMono/RobotoMono-Regular.ttf:$font_cache_dir/DroidSansMono.ttf"
    "$emoji_store/share/fonts/noto/NotoColorEmoji.ttf:$font_cache_dir/NotoColorEmoji.ttf"
  )

  local mapping source_path dest_path
  for mapping in "${sources[@]}"; do
    source_path="${mapping%%:*}"
    dest_path="${mapping#*:}"
    if [[ "${PIXEL_FORCE_ANDROID_FONT_REFRESH-}" == 1 || ! -s "$dest_path" ]]; then
      cp -L "$source_path" "$dest_path"
    fi
  done

  PIXEL_ANDROID_FONT_SOURCE_DIR="$font_cache_dir"
  export PIXEL_ANDROID_FONT_SOURCE_DIR
  printf '%s\n' "$PIXEL_ANDROID_FONT_SOURCE_DIR"
}

stage_runtime_bundle_xkb_config() {
  local bundle_dir xkb_source_dir xkb_dest_dir
  bundle_dir="$1"
  xkb_source_dir="$(runtime_bundle_xkb_source_dir)"
  xkb_dest_dir="$bundle_dir/share/X11/xkb"

  mkdir -p "$(dirname "$xkb_dest_dir")"
  mkdir -p "$bundle_dir/etc" "$bundle_dir/etc/X11"
  chmod -R u+w "$bundle_dir/share" "$bundle_dir/etc" 2>/dev/null || true
  rm -rf "$xkb_dest_dir"
  cp -LR "$xkb_source_dir" "$xkb_dest_dir"
  rm -rf "$bundle_dir/etc/xkb" "$bundle_dir/etc/X11/xkb"
  ln -s ../share/X11/xkb "$bundle_dir/etc/xkb"
  ln -s ../../share/X11/xkb "$bundle_dir/etc/X11/xkb"
}

stage_runtime_bundle_android_fonts() {
  local bundle_dir font_source_dir font_dest_dir font_file
  local -a font_files

  bundle_dir="$1"
  font_source_dir="$(runtime_bundle_android_font_source_dir)"
  font_dest_dir="$bundle_dir/system/fonts"
  font_files=(
    "DroidSans.ttf"
    "DroidSans-Bold.ttf"
    "DroidSansMono.ttf"
    "NotoColorEmoji.ttf"
  )

  mkdir -p "$font_dest_dir"
  chmod -R u+w "$bundle_dir/system" 2>/dev/null || true
  for font_file in "${font_files[@]}"; do
    cp -L "$font_source_dir/$font_file" "$font_dest_dir/$font_file"
  done
}

normalize_runtime_bundle_input_path() {
  local path
  path="$1"

  if [[ -z "$path" || ! -e "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi

  python3 - "$path" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

runtime_bundle_source_fingerprint() {
  local package_ref path file file_hash
  package_ref="$1"
  shift

  {
    printf 'package_ref %s\n' "$package_ref"

    for path in "$@"; do
      if [[ -d "$path" ]]; then
        while IFS= read -r file; do
          [[ -f "$file" ]] || continue
          file_hash="$(runtime_bundle_file_hash "$file")"
          printf 'file %s %s\n' "$file_hash" "$file"
        done < <(find "$path" -type f | LC_ALL=C sort)
        continue
      fi

      file_hash="$(runtime_bundle_file_hash "$path")"
      printf 'file %s %s\n' "$file_hash" "$path"
    done
  } | shasum -a 256 | awk '{print $1}'
}

runtime_bundle_cargo_package_source_inputs() {
  local package_dir path
  package_dir="$1"

  printf '%s\n' "$package_dir/Cargo.toml"

  for path in Cargo.lock build.rs src tests examples benches; do
    [[ -e "$package_dir/$path" ]] || continue
    printf '%s\n' "$package_dir/$path"
  done
}

runtime_bundle_directory_fingerprint() {
  local dir
  dir="$1"

  (
    cd "$dir"
    find . -type f | LC_ALL=C sort | while IFS= read -r file; do
      file="${file#./}"
      printf 'file %s %s\n' "$(runtime_bundle_file_hash "$dir/$file")" "$file"
    done
  ) | shasum -a 256 | awk '{print $1}'
}

require_runtime_bundle_entry() {
  local bundle_dir relative_path context path
  bundle_dir="$1"
  relative_path="$2"
  context="${3:-runtime bundle}"
  path="$bundle_dir/$relative_path"

  if [[ -e "$path" ]]; then
    return 0
  fi

  echo "$context: missing required path $relative_path in $bundle_dir" >&2
  return 1
}

runtime_bundle_manifest_matches() {
  local manifest_path expected_fingerprint
  manifest_path="$1"
  expected_fingerprint="$2"

  [[ -f "$manifest_path" ]] || return 1

  python3 - "$manifest_path" "$expected_fingerprint" <<'PY'
import json
import sys

manifest_path, expected_fingerprint = sys.argv[1:3]
with open(manifest_path, "r", encoding="utf-8") as handle:
    manifest = json.load(handle)
raise SystemExit(0 if manifest.get("fingerprint") == expected_fingerprint else 1)
PY
}

write_runtime_bundle_manifest() {
  local manifest_path fingerprint package_ref vendor_mesa_tarball vendor_turnip_tarball vendor_turnip_lib_path
  manifest_path="$1"
  fingerprint="$2"
  package_ref="$3"
  vendor_mesa_tarball="${4-}"
  vendor_turnip_tarball="${5-}"
  vendor_turnip_lib_path="${6-}"

  python3 - "$manifest_path" "$fingerprint" "$package_ref" "$vendor_mesa_tarball" "$vendor_turnip_tarball" "$vendor_turnip_lib_path" <<'PY'
import json
import sys
from datetime import datetime, timezone

manifest_path, fingerprint, package_ref, vendor_mesa_tarball, vendor_turnip_tarball, vendor_turnip_lib_path = sys.argv[1:7]
manifest = {
    "fingerprint": fingerprint,
    "generatedAt": datetime.now(timezone.utc).isoformat(),
    "packageRef": package_ref,
    "vendorMesaTarball": vendor_mesa_tarball or None,
    "vendorTurnipTarball": vendor_turnip_tarball or None,
    "vendorTurnipLibPath": vendor_turnip_lib_path or None,
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY
}

reuse_cached_runtime_bundle() {
  local manifest_path expected_fingerprint bundle_dir launcher_artifact launcher_device_path package_ref
  manifest_path="$1"
  expected_fingerprint="$2"
  bundle_dir="$3"
  launcher_artifact="$4"
  launcher_device_path="$5"
  package_ref="$6"

  if [[ "${PIXEL_FORCE_LINUX_BUNDLE_REBUILD-}" == 1 ]]; then
    return 1
  fi

  [[ -d "$bundle_dir" ]] || return 1
  [[ -x "$launcher_artifact" ]] || return 1
  [[ -f "$bundle_dir/shadow-blitz-demo" ]] || return 1
  [[ -d "$bundle_dir/share/X11/xkb" ]] || return 1
  [[ ! -L "$bundle_dir/share/X11/xkb" ]] || return 1
  [[ -f "$bundle_dir/system/fonts/DroidSans.ttf" ]] || return 1

  runtime_bundle_manifest_matches "$manifest_path" "$expected_fingerprint" || return 1

  python3 - "$bundle_dir" "$launcher_artifact" "$launcher_device_path" "$package_ref" <<'PY'
import json
import os
import sys

bundle_dir, launcher_artifact, launcher_device_path, package_ref = sys.argv[1:5]
print(json.dumps({
    "bundleArtifactDir": os.path.abspath(bundle_dir),
    "cacheHit": True,
    "clientLauncherArtifact": os.path.abspath(launcher_artifact),
    "clientLauncherDevicePath": launcher_device_path,
    "packageRef": package_ref,
}, indent=2))
PY
  return 0
}

runtime_closure_has_path() {
  local candidate existing
  candidate="$1"

  for existing in "${PIXEL_RUNTIME_CLOSURE_PATHS[@]}"; do
    if [[ "$existing" == "$candidate" ]]; then
      return 0
    fi
  done

  return 1
}

append_runtime_closure_paths() {
  local path

  for path in "$@"; do
    [[ -n "$path" ]] || continue
    if runtime_closure_has_path "$path"; then
      continue
    fi
    PIXEL_RUNTIME_CLOSURE_PATHS+=("$path")
  done
}

append_runtime_closure_from_package_ref() {
  local package_ref out_path
  local -a output_paths closure_paths

  package_ref="$1"
  output_paths=()
  while IFS= read -r out_path; do
    [[ -n "$out_path" ]] || continue
    output_paths+=("$out_path")
  done < <(
    pixel_retry_nix_build_print_out_paths \
      nix build --accept-flake-config --no-link --print-out-paths "$package_ref"
  )

  for out_path in "${output_paths[@]}"; do
    append_runtime_closure_paths "$out_path"
    closure_paths=()
    while IFS= read -r closure_path; do
      [[ -n "$closure_path" ]] || continue
      closure_paths+=("$closure_path")
    done < <(nix-store -qR "$out_path")
    append_runtime_closure_paths "${closure_paths[@]}"
  done
}

copy_runtime_optional_file() {
  local source_path dest_path
  source_path="$1"
  dest_path="$2"

  [[ -f "$source_path" ]] || return 0
  mkdir -p "$(dirname "$dest_path")"
  cp "$source_path" "$dest_path"
}

copy_runtime_optional_lib() {
  local name bundle_lib_dir lib_source_path
  name="$1"
  bundle_lib_dir="$2"

  lib_source_path="$(find_runtime_file_in_closure "$name" 2>/dev/null || true)"
  [[ -n "$lib_source_path" ]] || return 0
  cp "$lib_source_path" "$bundle_lib_dir/$name"
}

copy_closure_dir_into_bundle() {
  local relative_path destination required source_path closure_path found_any
  relative_path="$1"
  destination="$2"
  required="${3:-required}"
  found_any=0

  for closure_path in "${PIXEL_RUNTIME_CLOSURE_PATHS[@]}"; do
    source_path="$closure_path/$relative_path"
    if [[ ! -d "$source_path" ]]; then
      continue
    fi

    found_any=1
    mkdir -p "$destination"
    chmod -R u+w "$destination" 2>/dev/null || true
    rsync -rL --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r "$source_path"/. "$destination"/

    python3 - "$destination" "$relative_path" "${PIXEL_RUNTIME_CLOSURE_PATHS[@]}" <<'PY'
import os
import sys

destination = sys.argv[1]
relative_path = sys.argv[2]
closure_paths = sys.argv[3:]
target_root = "/" + relative_path
rewrite_prefixes = [os.path.join(path, relative_path) for path in closure_paths]
for root, _, files in os.walk(destination):
    for name in files:
        path = os.path.join(root, name)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                data = handle.read()
        except UnicodeDecodeError:
            continue
        rewritten = data
        for rewrite_prefix in rewrite_prefixes:
            rewritten = rewritten.replace(rewrite_prefix, target_root)
        if rewritten != data:
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(rewritten)
PY
  done

  if [[ "$found_any" -ne 1 ]]; then
    if [[ "$required" == "optional" ]]; then
      return 0
    fi
    echo "pixel runtime bundle: missing closure dir: $relative_path" >&2
    return 1
  fi
}

binary_interpreter() {
  local binary
  binary="$1"
  llvm-readelf -lW "$binary" | sed -n 's/^      \[Requesting program interpreter: \(.*\)\]$/\1/p' | head -n1
}

binary_needed_libs() {
  local binary
  binary="$1"
  llvm-readelf -dW "$binary" | sed -n 's/^.*Shared library: \[\(.*\)\]$/\1/p'
}

is_elf_file() {
  local path
  path="$1"
  file "$path" | grep -q 'ELF '
}

find_runtime_file_in_closure() {
  local name closure_path candidate
  name="$1"

  for closure_path in "${PIXEL_RUNTIME_CLOSURE_PATHS[@]}"; do
    candidate="$(find -L "$closure_path" -type f -name "$name" -print -quit 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "pixel runtime bundle: missing runtime file in closure: $name" >&2
  return 1
}

fill_linux_bundle_runtime_deps() {
  local bundle_dir bundle_lib_dir loader_name
  local -a dependency_queue
  local current_path needed_lib destination_path lib_source_path

  bundle_dir="$1"
  bundle_lib_dir="$bundle_dir/lib"
  loader_name="${PIXEL_RUNTIME_STAGE_LOADER_NAME:-}"

  dependency_queue=()
  while IFS= read -r dependency_path; do
    [[ -n "$dependency_path" ]] || continue
    dependency_queue+=("$dependency_path")
  done < <(find "$bundle_dir" -type f -print)

  while [[ "${#dependency_queue[@]}" -gt 0 ]]; do
    current_path="${dependency_queue[0]}"
    dependency_queue=("${dependency_queue[@]:1}")

    if [[ ! -f "$current_path" ]] || ! is_elf_file "$current_path"; then
      continue
    fi

    while IFS= read -r needed_lib; do
      [[ -n "$needed_lib" ]] || continue
      if [[ -n "$loader_name" && "$needed_lib" == "$loader_name" ]]; then
        continue
      fi

      destination_path="$bundle_lib_dir/$needed_lib"
      if [[ -f "$destination_path" ]]; then
        continue
      fi

      lib_source_path="$(find_runtime_file_in_closure "$needed_lib")"
      cp "$lib_source_path" "$destination_path"
      dependency_queue+=("$destination_path")
    done < <(binary_needed_libs "$current_path")
  done
}

stage_system_linux_bundle() {
  local package_ref out_link bundle_dir binary_name
  local binary_host_path bundle_lib_dir bundle_etc_dir file_output
  local interpreter_path loader_name needed_lib lib_source_path
  local dns_server

  package_ref="$1"
  out_link="$2"
  bundle_dir="$3"
  binary_name="${4:-shadow-system}"
  bundle_lib_dir="$bundle_dir/lib"
  bundle_etc_dir="$bundle_dir/etc"

  mkdir -p "$(dirname "$out_link")"
  rm -f "$out_link"
  chmod -R u+w "$bundle_dir" 2>/dev/null || true
  rm -rf "$bundle_dir"
  mkdir -p "$bundle_lib_dir" "$bundle_etc_dir"

  pixel_retry_nix_build nix build --accept-flake-config "$package_ref" --out-link "$out_link"

  binary_host_path="$out_link/bin/$binary_name"
  file_output="$(file "$binary_host_path")"
  printf '%s\n' "$file_output"
  if [[ "$file_output" != *"ARM aarch64"* || "$file_output" != *"dynamically linked"* ]]; then
    echo "pixel runtime bundle: expected a dynamic arm64 Linux binary, got: $file_output" >&2
    return 1
  fi

  PIXEL_RUNTIME_CLOSURE_PATHS=()
  while IFS= read -r closure_path; do
    [[ -n "$closure_path" ]] || continue
    PIXEL_RUNTIME_CLOSURE_PATHS+=("$closure_path")
  done < <(nix-store -qR "$out_link")

  interpreter_path="$(binary_interpreter "$binary_host_path")"
  if [[ -z "$interpreter_path" || ! -f "$interpreter_path" ]]; then
    echo "pixel runtime bundle: could not resolve ELF interpreter" >&2
    return 1
  fi
  loader_name="$(basename "$interpreter_path")"

  cp "$binary_host_path" "$bundle_dir/$binary_name"
  cp "$interpreter_path" "$bundle_lib_dir/$loader_name"

  while IFS= read -r needed_lib; do
    [[ -n "$needed_lib" ]] || continue
    if [[ "$needed_lib" == "$loader_name" ]]; then
      continue
    fi
    lib_source_path="$(find_runtime_file_in_closure "$needed_lib")"
    cp "$lib_source_path" "$bundle_lib_dir/$needed_lib"
  done < <(binary_needed_libs "$binary_host_path")

  copy_runtime_optional_lib "libnss_dns.so.2" "$bundle_lib_dir"
  copy_runtime_optional_lib "libnss_files.so.2" "$bundle_lib_dir"
  copy_runtime_optional_lib "libresolv.so.2" "$bundle_lib_dir"
  copy_runtime_optional_lib "libdl.so.2" "$bundle_lib_dir"
  copy_runtime_optional_lib "libpthread.so.0" "$bundle_lib_dir"
  copy_runtime_optional_lib "librt.so.1" "$bundle_lib_dir"

  cat >"$bundle_etc_dir/nsswitch.conf" <<'EOF'
hosts: files dns
passwd: files
group: files
shadow: files
networks: files
protocols: files
services: files
ethers: files
rpc: files
EOF

  cat >"$bundle_etc_dir/hosts" <<'EOF'
127.0.0.1 localhost
::1 localhost
EOF

  : "${PIXEL_RUNTIME_DNS_SERVERS:=1.1.1.1 8.8.8.8}"
  : >"$bundle_etc_dir/resolv.conf"
  for dns_server in $PIXEL_RUNTIME_DNS_SERVERS; do
    printf 'nameserver %s\n' "$dns_server" >>"$bundle_etc_dir/resolv.conf"
  done

  chmod 0755 "$bundle_dir/$binary_name" "$bundle_lib_dir/$loader_name"

  PIXEL_RUNTIME_STAGE_BINARY_HOST_PATH="$binary_host_path"
  PIXEL_RUNTIME_STAGE_INTERPRETER_PATH="$interpreter_path"
  PIXEL_RUNTIME_STAGE_LOADER_NAME="$loader_name"
}
