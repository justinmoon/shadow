#!/usr/bin/env bash

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

stage_runtime_host_linux_bundle() {
fill_linux_bundle_runtime_deps() {
  local bundle_dir bundle_lib_dir loader_name
  local -a dependency_queue
  local current_path needed_lib destination_path lib_source_path

  bundle_dir="$1"
  bundle_lib_dir="$bundle_dir/lib"
  loader_name="${PIXEL_RUNTIME_STAGE_LOADER_NAME:-}"

  mapfile -t dependency_queue < <(find "$bundle_dir" -type f -print)

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

stage_runtime_host_linux_bundle() {
  local package_ref out_link bundle_dir binary_name
  local binary_host_path bundle_lib_dir bundle_etc_dir file_output
  local interpreter_path loader_name needed_lib lib_source_path
  local dns_server

  package_ref="$1"
  out_link="$2"
  bundle_dir="$3"
  binary_name="${4:-shadow-runtime-host}"
  bundle_lib_dir="$bundle_dir/lib"
  bundle_etc_dir="$bundle_dir/etc"

  mkdir -p "$(dirname "$out_link")"
  rm -f "$out_link"
  chmod -R u+w "$bundle_dir" 2>/dev/null || true
  rm -rf "$bundle_dir"
  mkdir -p "$bundle_lib_dir" "$bundle_etc_dir"

  nix build --accept-flake-config "$package_ref" --out-link "$out_link"

  binary_host_path="$out_link/bin/$binary_name"
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
