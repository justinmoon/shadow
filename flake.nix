{
  description = "Shadow boot bring-up tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system:
          f { pkgs = import nixpkgs { inherit system; }; });
      mkInitWrapper = pkgs:
        let
          cross = pkgs.pkgsCross.musl64;
        in cross.rustPlatform.buildRustPackage {
          pname = "init-wrapper";
          version = "0.1.0";
          src = ./rust/init-wrapper;
          cargoLock.lockFile = ./rust/init-wrapper/Cargo.lock;
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = "x86_64-unknown-linux-musl";
          RUSTFLAGS = "-C target-feature=+crt-static";
        };
      mkDrmRect = pkgs:
        let
          cross = pkgs.pkgsCross.musl64;
        in cross.rustPlatform.buildRustPackage {
          pname = "drm-rect";
          version = "0.1.0";
          src = ./rust/drm-rect;
          cargoLock.lockFile = ./rust/drm-rect/Cargo.lock;
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = "x86_64-unknown-linux-musl";
          RUSTFLAGS = "-C target-feature=+crt-static";
        };
      mkShadowGuestCompositor = pkgs:
        let
          static = pkgs.pkgsStatic;
        in static.rustPlatform.buildRustPackage {
          pname = "shadow-compositor-guest";
          version = "0.1.0";
          src = ./ui;
          cargoLock.lockFile = ./ui/Cargo.lock;
          doCheck = false;
          strictDeps = true;
          cargoBuildFlags = [ "-p" "shadow-compositor-guest" ];
          cargoInstallFlags = [ "-p" "shadow-compositor-guest" ];
          buildInputs = [ static.libxkbcommon ];
        };
      mkShadowGuestCounter = pkgs:
        let
          static = pkgs.pkgsStatic;
        in static.rustPlatform.buildRustPackage {
          pname = "shadow-counter-guest";
          version = "0.1.0";
          src = ./ui;
          cargoLock.lockFile = ./ui/Cargo.lock;
          doCheck = false;
          strictDeps = true;
          cargoBuildFlags = [ "-p" "shadow-counter-guest" ];
          cargoInstallFlags = [ "-p" "shadow-counter-guest" ];
          nativeBuildInputs = [ pkgs.buildPackages.pkg-config ];
          buildInputs = [
            static.wayland
            static.expat
            static.libffi
          ];
          PKG_CONFIG_ALL_STATIC = "1";
        };
      mkBootimgShell = pkgs:
        let
          toolPkgs = with pkgs; [
            android-tools
            bash
            cargo
            cargo-zigbuild
            coreutils
            curl
            file
            findutils
            gawk
            gnugrep
            gnused
            gzip
            just
            lz4
            nix
            nodejs
            openssh
            python3
            rustc
            zig
          ];
        in pkgs.mkShell {
          packages = toolPkgs;

          shellHook = ''
            export PATH="${pkgs.lib.makeBinPath toolPkgs}:$PATH"
            export IN_NIX_SHELL=1
            export SHADOW_BOOTIMG_SHELL=1
          '';
        };
      mkUiShell = pkgs:
        let
          toolPkgs = with pkgs; [
            bash
            cargo
            clippy
            coreutils
            findutils
            gnugrep
            gnused
            gnutar
            just
            openssh
            pkg-config
            rustc
            rustfmt
          ];
          runtimeLibs = pkgs.lib.optionals pkgs.stdenv.isLinux (with pkgs; [
            libdrm
            libGL
            libxkbcommon
            mesa
            vulkan-loader
            wayland
            wayland-protocols
            libx11
            libxcursor
            libxi
            libxrandr
          ]);
          shellPkgs = toolPkgs ++ runtimeLibs;
          pkgConfigPath = pkgs.lib.makeSearchPath "lib/pkgconfig" runtimeLibs;
        in pkgs.mkShell {
          packages = shellPkgs;

          shellHook = ''
            export PATH="${pkgs.lib.makeBinPath toolPkgs}:$PATH"
            export IN_NIX_SHELL=1
            export SHADOW_UI_SHELL=1
            ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
              export PKG_CONFIG_PATH="${pkgConfigPath}:''${PKG_CONFIG_PATH:-}"
              export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath runtimeLibs}:''${LD_LIBRARY_PATH:-}"
            ''}
          '';
        };
    in {
      devShells = forAllSystems ({ pkgs }: {
        bootimg = mkBootimgShell pkgs;
        ui = mkUiShell pkgs;
        default = mkBootimgShell pkgs;
      });
      packages = forAllSystems ({ pkgs }:
        {
          init-wrapper = mkInitWrapper pkgs;
          drm-rect = mkDrmRect pkgs;
          default = mkInitWrapper pkgs;
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          shadow-compositor-guest = mkShadowGuestCompositor pkgs;
          shadow-counter-guest = mkShadowGuestCounter pkgs;
        });
    };
}
