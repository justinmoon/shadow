#!/usr/bin/env bash

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

find_runtime_file_in_closure() {
  local name closure_path candidate
  name="$1"

  for closure_path in "${PIXEL_RUNTIME_CLOSURE_PATHS[@]}"; do
    candidate="$(find "$closure_path" -type f -name "$name" -print -quit 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "pixel runtime bundle: missing runtime file in closure: $name" >&2
  return 1
}

stage_deno_core_linux_bundle() {
  local package_ref out_link bundle_dir binary_name
  local binary_host_path modules_host_dir bundle_lib_dir file_output
  local interpreter_path loader_name needed_lib lib_source_path

  package_ref="$1"
  out_link="$2"
  bundle_dir="$3"
  binary_name="${4:-deno-core-smoke}"
  bundle_lib_dir="$bundle_dir/lib"

  mkdir -p "$(dirname "$out_link")"
  rm -f "$out_link"
  chmod -R u+w "$bundle_dir" 2>/dev/null || true
  rm -rf "$bundle_dir"
  mkdir -p "$bundle_lib_dir"

  nix build --accept-flake-config "$package_ref" --out-link "$out_link"

  binary_host_path="$out_link/bin/$binary_name"
  modules_host_dir="$out_link/lib/$binary_name/modules"

  file_output="$(file "$binary_host_path")"
  printf '%s\n' "$file_output"
  if [[ "$file_output" != *"ARM aarch64"* || "$file_output" != *"dynamically linked"* ]]; then
    echo "pixel runtime bundle: expected a dynamic arm64 Linux binary, got: $file_output" >&2
    return 1
  fi

  mapfile -t PIXEL_RUNTIME_CLOSURE_PATHS < <(nix-store -qR "$out_link")

  interpreter_path="$(binary_interpreter "$binary_host_path")"
  if [[ -z "$interpreter_path" || ! -f "$interpreter_path" ]]; then
    echo "pixel runtime bundle: could not resolve ELF interpreter" >&2
    return 1
  fi
  loader_name="$(basename "$interpreter_path")"

  cp "$binary_host_path" "$bundle_dir/$binary_name"
  if [[ -d "$modules_host_dir" ]]; then
    cp -r "$modules_host_dir" "$bundle_dir/modules"
  fi
  cp "$interpreter_path" "$bundle_lib_dir/$loader_name"

  while IFS= read -r needed_lib; do
    [[ -n "$needed_lib" ]] || continue
    if [[ "$needed_lib" == "$loader_name" ]]; then
      continue
    fi
    lib_source_path="$(find_runtime_file_in_closure "$needed_lib")"
    cp "$lib_source_path" "$bundle_lib_dir/$needed_lib"
  done < <(binary_needed_libs "$binary_host_path")

  chmod 0755 "$bundle_dir/$binary_name" "$bundle_lib_dir/$loader_name"

  PIXEL_RUNTIME_STAGE_BINARY_HOST_PATH="$binary_host_path"
  PIXEL_RUNTIME_STAGE_INTERPRETER_PATH="$interpreter_path"
  PIXEL_RUNTIME_STAGE_LOADER_NAME="$loader_name"
}
