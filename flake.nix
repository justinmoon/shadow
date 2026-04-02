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
      uiBlitzOutputHashes = {
        "blitz-dom-0.2.2" = "sha256-12kCCerl+ZhcEyGHOYQ0Rez1U+WY/KRFISVYu6PTrXY=";
        "blitz-html-0.2.0" = "sha256-12kCCerl+ZhcEyGHOYQ0Rez1U+WY/KRFISVYu6PTrXY=";
        "blitz-paint-0.2.1" = "sha256-12kCCerl+ZhcEyGHOYQ0Rez1U+WY/KRFISVYu6PTrXY=";
        "blitz-shell-0.2.2" = "sha256-12kCCerl+ZhcEyGHOYQ0Rez1U+WY/KRFISVYu6PTrXY=";
        "blitz-traits-0.2.0" = "sha256-12kCCerl+ZhcEyGHOYQ0Rez1U+WY/KRFISVYu6PTrXY=";
        "debug_timer-0.1.3" = "sha256-12kCCerl+ZhcEyGHOYQ0Rez1U+WY/KRFISVYu6PTrXY=";
        "fontique-0.7.0" = "sha256-F5+3iH+5seYqG0MDK2FjP8N5DTIfAXFuG8hOaP9JqDY=";
        "parley-0.7.0" = "sha256-F5+3iH+5seYqG0MDK2FjP8N5DTIfAXFuG8hOaP9JqDY=";
        "parley_data-0.0.0" = "sha256-F5+3iH+5seYqG0MDK2FjP8N5DTIfAXFuG8hOaP9JqDY=";
        "stylo_taffy-0.2.0" = "sha256-12kCCerl+ZhcEyGHOYQ0Rez1U+WY/KRFISVYu6PTrXY=";
        "taffy-0.9.2" = "sha256-ySHniRTk6gOvZ4Kdb5oY7ihBzmKFbWBpeRiS9MXeeZM=";
        "text_primitives-0.1.0" = "sha256-F5+3iH+5seYqG0MDK2FjP8N5DTIfAXFuG8hOaP9JqDY=";
      };
      rustyV8ReleaseVersion = "146.8.0";
      rustyV8ReleaseShas = {
        "x86_64-linux" = "sha256-deV+2rJD9EstgAtaFRk+z1Wk/l+j5yF9lxlLGHoCbII=";
        "aarch64-linux" = "sha256-zkzEqNmYuJhxXC+nYvbdKaZCGhPLONxvQ5X8u9S7/M4=";
        "x86_64-darwin" = "sha256-8HbKFjFm5F/+hb5lViPWok0b0NIkYXoR6RXQgHAroVo=";
        "aarch64-darwin" = "sha256-1AXPak0YGf53zRyPUtfPgvAn0Z03oIB9zEFbc+laAFY=";
      };
      mkUnavailablePackage = pkgs: name: message:
        pkgs.writeShellScriptBin name ''
          echo ${builtins.toJSON message} >&2
          exit 1
        '';
      mkRustyV8ArchiveFor = cross:
        cross.fetchurl {
          name = "librusty_v8-${rustyV8ReleaseVersion}";
          url = "https://github.com/denoland/rusty_v8/releases/download/v${rustyV8ReleaseVersion}/librusty_v8_release_${cross.stdenv.hostPlatform.rust.rustcTarget}.a.gz";
          sha256 = rustyV8ReleaseShas.${cross.stdenv.hostPlatform.system};
          meta.sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
        };
      mkInitWrapperFor = cross:
        cross.rustPlatform.buildRustPackage {
          pname = "init-wrapper";
          version = "0.1.0";
          src = ./rust/init-wrapper;
          cargoLock.lockFile = ./rust/init-wrapper/Cargo.lock;
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = cross.stdenv.hostPlatform.config;
          RUSTFLAGS = lib.optionalString cross.stdenv.hostPlatform.isMusl "-C target-feature=+crt-static";
        };
      mkDrmRectFor = cross:
        cross.rustPlatform.buildRustPackage {
          pname = "drm-rect";
          version = "0.1.0";
          src = ./rust/drm-rect;
          cargoLock.lockFile = ./rust/drm-rect/Cargo.lock;
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = cross.stdenv.hostPlatform.config;
          RUSTFLAGS = lib.optionalString cross.stdenv.hostPlatform.isMusl "-C target-feature=+crt-static";
        };
      mkShadowSessionFor = cross:
        cross.rustPlatform.buildRustPackage {
          pname = "shadow-session";
          version = "0.1.0";
          src = ./rust/shadow-session;
          cargoLock.lockFile = ./rust/shadow-session/Cargo.lock;
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = cross.stdenv.hostPlatform.config;
          RUSTFLAGS = lib.optionalString cross.stdenv.hostPlatform.isMusl "-C target-feature=+crt-static";
        };
      mkShadowGuestCompositorFor = cross:
        let
          staticXkbcommon = (cross.libxkbcommon.override { withWaylandTools = false; }).overrideAttrs (old: {
            mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Ddefault_library=static" ];
          });
        in cross.rustPlatform.buildRustPackage {
          pname = "shadow-compositor-guest";
          version = "0.1.0";
          src = ./ui;
          cargoLock = {
            lockFile = ./ui/Cargo.lock;
            outputHashes = uiBlitzOutputHashes;
          };
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = cross.stdenv.hostPlatform.config;
          RUSTFLAGS = lib.optionalString cross.stdenv.hostPlatform.isMusl "-C target-feature=+crt-static";
          cargoBuildFlags = [ "-p" "shadow-compositor-guest" ];
          cargoInstallFlags = [ "-p" "shadow-compositor-guest" ];
          nativeBuildInputs = [ cross.buildPackages.pkg-config ];
          buildInputs = lib.optionals cross.stdenv.hostPlatform.isLinux [ staticXkbcommon ];
        };
      mkShadowGuestCounterFor = cross:
        cross.rustPlatform.buildRustPackage {
          pname = "shadow-counter-guest";
          version = "0.1.0";
          src = ./ui;
          cargoLock = {
            lockFile = ./ui/Cargo.lock;
            outputHashes = uiBlitzOutputHashes;
          };
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = cross.stdenv.hostPlatform.config;
          RUSTFLAGS = lib.optionalString cross.stdenv.hostPlatform.isMusl "-C target-feature=+crt-static";
          cargoBuildFlags = [ "-p" "shadow-counter-guest" ];
          cargoInstallFlags = [ "-p" "shadow-counter-guest" ];
          nativeBuildInputs = [ cross.buildPackages.pkg-config ];
          buildInputs = [
            cross.wayland
            cross.expat
            cross.libffi
          ];
          PKG_CONFIG_ALL_STATIC = "1";
        };
      mkRustyV8SmokeFor = cross:
        cross.rustPlatform.buildRustPackage {
          pname = "rusty-v8-smoke";
          version = "0.1.0";
          src = ./rust/rusty-v8-smoke;
          cargoLock.lockFile = ./rust/rusty-v8-smoke/Cargo.lock;
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = cross.stdenv.hostPlatform.config;
          depsBuildBuild =
            lib.optionals cross.stdenv.buildPlatform.isDarwin [
              cross.buildPackages.stdenv.cc
              cross.buildPackages.libiconv
            ];
          RUSTY_V8_ARCHIVE = mkRustyV8ArchiveFor cross;
          meta.mainProgram = "rusty-v8-smoke";
        };
      mkDenoCoreSmokeFor = cross:
        cross.rustPlatform.buildRustPackage {
          pname = "deno-core-smoke";
          version = "0.1.0";
          src = ./rust/deno-core-smoke;
          cargoLock.lockFile = ./rust/deno-core-smoke/Cargo.lock;
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = cross.stdenv.hostPlatform.config;
          depsBuildBuild =
            lib.optionals cross.stdenv.buildPlatform.isDarwin [
              cross.buildPackages.stdenv.cc
              cross.buildPackages.libiconv
            ];
          RUSTY_V8_ARCHIVE = mkRustyV8ArchiveFor cross;
          postInstall = ''
            mkdir -p "$out/lib/deno-core-smoke"
            cp -r "$src/modules" "$out/lib/deno-core-smoke/"
          '';
          meta.mainProgram = "deno-core-smoke";
        };
      mkInitWrapper = pkgs: mkInitWrapperFor pkgs.pkgsCross.musl64;
      mkDrmRect = pkgs: mkDrmRectFor pkgs.pkgsCross.musl64;
      mkShadowSession = pkgs: mkShadowSessionFor pkgs.pkgsCross.musl64;
      mkShadowGuestCompositor = pkgs: mkShadowGuestCompositorFor pkgs.pkgsStatic;
      mkShadowGuestCounter = pkgs: mkShadowGuestCounterFor pkgs.pkgsStatic;
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
            llvmPackages.bintools
            lz4
            nix
            nodejs
            openssh
            payload-dumper-go
            python3
            rustc
            unzip
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
            cargo-zigbuild
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
            zig
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
      mkRuntimeShell = pkgs:
        let
          toolPkgs = with pkgs; [
            bash
            cargo
            clippy
            cmake
            coreutils
            findutils
            gn
            gnugrep
            gnused
            just
            llvmPackages.bintools
            ninja
            pkg-config
            python3
            rustc
            rustfmt
          ] ++ lib.optionals pkgs.stdenv.isDarwin [ lld ];
        in pkgs.mkShell {
          packages = toolPkgs;

          shellHook = ''
            export PATH="${pkgs.lib.makeBinPath toolPkgs}:$PATH"
            export IN_NIX_SHELL=1
            export SHADOW_RUNTIME_SHELL=1
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
        runtime = mkRuntimeShell pkgs;
        ui = mkUiShell pkgs;
        default = mkBootimgShell pkgs;
      });
      packages = forAllSystems ({ pkgs }:
        {
          init-wrapper = mkInitWrapper pkgs;
          drm-rect = mkDrmRect pkgs;
          deno-core-smoke = mkDenoCoreSmokeFor pkgs;
          deno-core-smoke-aarch64-linux-gnu =
            mkDenoCoreSmokeFor pkgs.pkgsCross.aarch64-multiplatform;
          deno-core-smoke-x86_64-linux-gnu =
            mkDenoCoreSmokeFor pkgs.pkgsCross.gnu64;
          rusty-v8-smoke = mkRustyV8SmokeFor pkgs;
          rusty-v8-smoke-aarch64-linux-gnu =
            mkRustyV8SmokeFor pkgs.pkgsCross.aarch64-multiplatform;
          rusty-v8-smoke-x86_64-linux-gnu =
            mkRustyV8SmokeFor pkgs.pkgsCross.gnu64;
          shadow-session = mkShadowSession pkgs;
          init-wrapper-device = mkInitWrapperFor pkgs.pkgsCross.aarch64-multiplatform-musl;
          drm-rect-device = mkDrmRectFor pkgs.pkgsCross.aarch64-multiplatform-musl;
          shadow-session-device = mkShadowSessionFor pkgs.pkgsCross.aarch64-multiplatform-musl;
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
          shadow-compositor-guest-device =
            mkShadowGuestCompositorFor pkgs.pkgsCross.aarch64-multiplatform-musl;
          shadow-counter-guest-device =
            mkShadowGuestCounterFor pkgs.pkgsCross.aarch64-multiplatform-musl;
        });
    };
}
