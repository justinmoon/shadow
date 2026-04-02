#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

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

  for closure_path in "${closure_paths[@]}"; do
    candidate="$(find "$closure_path" -type f -name "$name" -print -quit 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "pixel_runtime_deno_core_smoke: missing runtime file in closure: $name" >&2
  return 1
}

serial="$(pixel_resolve_serial)"
run_dir="$(pixel_prepare_named_run_dir "$(pixel_runtime_runs_dir)")"
device_dir="$(pixel_runtime_linux_dir)"
package_ref="$(repo_root)#deno-core-smoke-aarch64-linux-gnu"
out_link="$(pixel_dir)/deno-core-smoke-aarch64-linux-gnu-result"
binary_name="deno-core-smoke"
binary_host_path=""
binary_device_path="$device_dir/$binary_name"
modules_host_dir=""
module_device_path="$device_dir/modules/main.js"
bundle_dir="$run_dir/shadow-runtime-gnu"
bundle_lib_dir="$bundle_dir/lib"
bundle_manifest_path="$run_dir/bundle-manifest.txt"
session_output_path="$run_dir/runtime-output.txt"
device_listing_path="$run_dir/device-files.txt"
binary_file_path="$run_dir/binary-file.txt"
program_headers_path="$run_dir/program-headers.txt"
dynamic_section_path="$run_dir/dynamic-section.txt"
closure_path="$run_dir/closure.txt"
root_id_path="$run_dir/root-id.txt"
push_log_path="$run_dir/push-log.txt"
run_status=1
root_ok=false
binary_ok=false
bundle_ok=false
push_ok=false
output_ok=false
interpreter_path=""
loader_name=""
failure_message=""

pixel_prepare_dirs
pixel_capture_props "$serial" "$run_dir/device-props.txt"
pixel_capture_processes "$serial" "$run_dir/processes-before.txt"

set +e
root_id="$(pixel_root_id "$serial")"
root_status="$?"
set -e
if [[ "$root_status" -ne 0 ]]; then
  echo "pixel_runtime_deno_core_smoke: root is required; run 'just pixel-root-check'" >&2
  exit 1
fi
root_ok=true
printf '%s\n' "$root_id" >"$root_id_path"

mkdir -p "$(dirname "$out_link")"
rm -f "$out_link"
nix build --accept-flake-config "$package_ref" --out-link "$out_link"

binary_host_path="$out_link/bin/$binary_name"
modules_host_dir="$out_link/lib/$binary_name/modules"

file_output="$(file "$binary_host_path")"
printf '%s\n' "$file_output" | tee "$binary_file_path"
if [[ "$file_output" != *"ARM aarch64"* || "$file_output" != *"dynamically linked"* ]]; then
  echo "pixel_runtime_deno_core_smoke: expected a dynamic arm64 Linux binary, got: $file_output" >&2
  exit 1
fi
binary_ok=true

llvm-readelf -lW "$binary_host_path" >"$program_headers_path"
llvm-readelf -dW "$binary_host_path" >"$dynamic_section_path"
mapfile -t closure_paths < <(nix-store -qR "$out_link")
printf '%s\n' "${closure_paths[@]}" >"$closure_path"

interpreter_path="$(binary_interpreter "$binary_host_path")"
if [[ -z "$interpreter_path" || ! -f "$interpreter_path" ]]; then
  echo "pixel_runtime_deno_core_smoke: could not resolve ELF interpreter" >&2
  exit 1
fi
loader_name="$(basename "$interpreter_path")"

mkdir -p "$bundle_lib_dir"
cp "$binary_host_path" "$bundle_dir/$binary_name"
cp -r "$modules_host_dir" "$bundle_dir/modules"
cp "$interpreter_path" "$bundle_lib_dir/$loader_name"
printf '%s -> %s\n' "$interpreter_path" "$bundle_lib_dir/$loader_name" >"$bundle_manifest_path"

while IFS= read -r needed_lib; do
  [[ -n "$needed_lib" ]] || continue
  if [[ "$needed_lib" == "$loader_name" ]]; then
    continue
  fi
  lib_source_path="$(find_runtime_file_in_closure "$needed_lib")"
  cp "$lib_source_path" "$bundle_lib_dir/$needed_lib"
  printf '%s -> %s\n' "$lib_source_path" "$bundle_lib_dir/$needed_lib" >>"$bundle_manifest_path"
done < <(binary_needed_libs "$binary_host_path")

chmod 0755 "$bundle_dir/$binary_name" "$bundle_lib_dir/$loader_name"
bundle_ok=true

if {
  printf 'Pushing GNU runtime bundle to %s\n' "$serial"
  pixel_root_shell "$serial" "rm -rf '$device_dir'"
  pixel_adb "$serial" shell "mkdir -p '$device_dir/lib'"
  pixel_adb "$serial" push "$bundle_dir/$binary_name" "$binary_device_path"
  pixel_adb "$serial" push "$bundle_dir/modules" "$device_dir"
  for host_lib_path in "$bundle_lib_dir"/*; do
    pixel_adb "$serial" push "$host_lib_path" "$device_dir/lib/$(basename "$host_lib_path")"
  done
  pixel_adb "$serial" shell "chmod 0755 '$binary_device_path' '$device_dir/lib/$loader_name' && find '$device_dir' -type f | sort"
} >"$push_log_path" 2>&1; then
  push_ok=true
else
  failure_message="failed to push GNU runtime bundle"
fi

if [[ "$push_ok" == true ]]; then
  pixel_root_shell "$serial" "find '$device_dir' -maxdepth 2 -type f | sort" >"$device_listing_path"
  set +e
  pixel_root_shell "$serial" "'$device_dir/lib/$loader_name' --library-path '$device_dir/lib' '$binary_device_path' '$module_device_path'" >"$session_output_path" 2>&1
  run_status="$?"
  set -e

  expected_result="result=HELLO FROM HOST OP AND FILE MODULE"
  expected_module="module=file://$module_device_path"
  if [[ "$run_status" -eq 0 ]] \
    && grep -Fq 'deno_core host-op ok:' "$session_output_path" \
    && grep -Fq "$expected_module" "$session_output_path" \
    && grep -Fq "$expected_result" "$session_output_path"; then
    output_ok=true
  else
    failure_message="device runtime smoke did not produce the expected output"
  fi
fi

pixel_capture_processes "$serial" "$run_dir/processes-after.txt"

pixel_write_status_json "$run_dir/status.json" \
  run_dir="$run_dir" \
  serial="$serial" \
  root_ok="$root_ok" \
  binary_ok="$binary_ok" \
  bundle_ok="$bundle_ok" \
  push_ok="$push_ok" \
  run_exit="$run_status" \
  output_ok="$output_ok" \
  interpreter="$interpreter_path" \
  loader_name="$loader_name" \
  failure_message="$failure_message" \
  success="$([[ "$root_ok" == true && "$binary_ok" == true && "$bundle_ok" == true && "$push_ok" == true && "$output_ok" == true ]] && echo true || echo false)"

cat "$run_dir/status.json"

if [[ "$output_ok" != true ]]; then
  [[ -n "$failure_message" ]] && echo "pixel_runtime_deno_core_smoke: $failure_message" >&2
  echo "pixel_runtime_deno_core_smoke: device runtime smoke failed; see $run_dir" >&2
  exit 1
fi

printf 'Pixel Deno Core runtime smoke succeeded: %s\n' "$run_dir"
