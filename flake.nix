{
  description = "Shadow boot bring-up tooling";

  nixConfig = {
    extra-substituters = [ "https://microvm.cachix.org" ];
    extra-trusted-public-keys = [
      "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, microvm }:
    let
      lib = nixpkgs.lib;
      uiVmSourceEnv = builtins.getEnv "SHADOW_UI_VM_SOURCE";
      uiVmSource =
        if uiVmSourceEnv != "" then
          uiVmSourceEnv
        else
          null;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      darwinSystems = builtins.filter (system: lib.hasSuffix "-darwin" system) systems;
      forAllSystems = f:
        lib.genAttrs systems (system:
          f { pkgs = import nixpkgs { inherit system; }; });
      mkUnavailablePackage = pkgs: name: message:
        pkgs.writeShellScriptBin name ''
          echo ${builtins.toJSON message} >&2
          exit 1
        '';
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
      mkShadowSession = pkgs:
        let
          cross = pkgs.pkgsCross.musl64;
        in cross.rustPlatform.buildRustPackage {
          pname = "shadow-session";
          version = "0.1.0";
          src = ./rust/shadow-session;
          cargoLock.lockFile = ./rust/shadow-session/Cargo.lock;
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
      nixosConfigurations =
        lib.optionalAttrs (uiVmSource != null)
          (lib.listToAttrs (map (hostSystem: {
            name = "${hostSystem}-shadow-ui-vm";
            value = import ./vm/shadow-ui-vm.nix {
              inherit hostSystem microvm nixpkgs;
              repoSource = uiVmSource;
            };
          }) darwinSystems));
      devShells = forAllSystems ({ pkgs }: {
        bootimg = mkBootimgShell pkgs;
        ui = mkUiShell pkgs;
        default = mkBootimgShell pkgs;
      });
      packages = forAllSystems ({ pkgs }:
        {
          init-wrapper = mkInitWrapper pkgs;
          drm-rect = mkDrmRect pkgs;
          shadow-session = mkShadowSession pkgs;
          default = mkInitWrapper pkgs;
          ui-vm =
            if pkgs.stdenv.isDarwin && uiVmSource != null then
              self.nixosConfigurations."${pkgs.stdenv.hostPlatform.system}-shadow-ui-vm".config.microvm.declaredRunner
            else
              mkUnavailablePackage pkgs "shadow-ui-vm-unavailable"
                "ui-vm requires a macOS host plus SHADOW_UI_VM_SOURCE set under --impure. Use just ui-vm-run.";
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          shadow-compositor-guest = mkShadowGuestCompositor pkgs;
          shadow-counter-guest = mkShadowGuestCounter pkgs;
        });
    };
}
