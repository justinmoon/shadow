#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs
repo="$(repo_root)"
output_path="$(pixel_guest_client_artifact)"
target="aarch64-unknown-linux-musl"
profile="${PIXEL_GUEST_CLIENT_PROFILE:-debug}"
renderer="${PIXEL_BLITZ_RENDERER:-cpu}"
toolchain_bin_dir="$(dirname "$(rustup which cargo)")"
binary_path="$repo/ui/target/$target/$profile/shadow-blitz-demo"
release_flag=""
pkg_config_dir="$(mktemp -d)"
declare -a cargo_renderer_args=()
cargo_renderer_flags=""

cleanup() {
  rm -rf "$pkg_config_dir"
}

trap cleanup EXIT

if [[ "$profile" == "release" ]]; then
  release_flag="--release"
fi

case "$renderer" in
  cpu) ;;
  gpu)
    cargo_renderer_args=(--no-default-features --features gpu)
    ;;
  gpu_softbuffer)
    cargo_renderer_args=(--no-default-features --features gpu_softbuffer)
    ;;
  hybrid)
    cargo_renderer_args=(--no-default-features --features hybrid)
    ;;
  *)
    echo "pixel_build_blitz_demo: unsupported PIXEL_BLITZ_RENDERER: $renderer" >&2
    exit 1
    ;;
esac

cargo_renderer_flags="${cargo_renderer_args[*]}"

static_wayland_store="$(nix build --accept-flake-config 'nixpkgs#pkgsCross.aarch64-multiplatform-musl.pkgsStatic.wayland' --print-out-paths --no-link | tail -n 1)"
static_libffi_store="$(nix build --accept-flake-config 'nixpkgs#pkgsCross.aarch64-multiplatform-musl.pkgsStatic.libffi' --print-out-paths --no-link | tail -n 1)"

cat >"$pkg_config_dir/wayland-client.pc" <<EOF
prefix=$static_wayland_store
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: wayland-client
Description: Wayland client library
Version: 1.24.0
Libs: -L\${libdir} -lwayland-client
Libs.private: -L$static_libffi_store/lib -lffi
Cflags:
EOF

rustup target add "$target" >/dev/null

nix develop "$repo"#ui -c bash -lc "
set -euo pipefail
export PATH=$(printf '%q' "$toolchain_bin_dir"):\$PATH
export PKG_CONFIG_PATH=$(printf '%q' "$pkg_config_dir")
export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_ALL_STATIC=1
cd $(printf '%q' "$repo")
cargo zigbuild --manifest-path ui/Cargo.toml -p shadow-blitz-demo --target $target $release_flag $cargo_renderer_flags
"

cp "$binary_path" "$output_path"

chmod 0755 "$output_path"
file_output="$(file "$output_path")"
printf '%s\n' "$file_output"
if [[ "$file_output" != *"ARM aarch64"* ]]; then
  echo "pixel_build_guest_client: expected an arm64 binary, got: $file_output" >&2
  exit 1
fi
if [[ "$file_output" == *"dynamically linked"* ]]; then
  echo "pixel_build_guest_client: expected a static binary, got a dynamic one: $file_output" >&2
  exit 1
fi

printf 'Built %s renderer=%s -> %s\n' "shadow-blitz-demo" "$renderer" "$output_path"
