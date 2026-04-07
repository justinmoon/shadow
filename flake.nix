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
        "blitz-dom-0.2.2" = "sha256-RWQ5RpapA5ZmxJ9+LuUlL+RTwBcHRgZDM7Kok6yHpi8=";
        "blitz-html-0.2.0" = "sha256-RWQ5RpapA5ZmxJ9+LuUlL+RTwBcHRgZDM7Kok6yHpi8=";
        "blitz-paint-0.2.1" = "sha256-RWQ5RpapA5ZmxJ9+LuUlL+RTwBcHRgZDM7Kok6yHpi8=";
        "blitz-shell-0.2.2" = "sha256-RWQ5RpapA5ZmxJ9+LuUlL+RTwBcHRgZDM7Kok6yHpi8=";
        "blitz-traits-0.2.0" = "sha256-RWQ5RpapA5ZmxJ9+LuUlL+RTwBcHRgZDM7Kok6yHpi8=";
        "debug_timer-0.1.3" = "sha256-RWQ5RpapA5ZmxJ9+LuUlL+RTwBcHRgZDM7Kok6yHpi8=";
        "fontique-0.8.0" = "sha256-dhczFDIFbcl2mMUtTIZaeaTtXWTHNw1fl2xgVcp93NE=";
        "parlance-0.1.0" = "sha256-dhczFDIFbcl2mMUtTIZaeaTtXWTHNw1fl2xgVcp93NE=";
        "parley-0.8.0" = "sha256-dhczFDIFbcl2mMUtTIZaeaTtXWTHNw1fl2xgVcp93NE=";
        "parley_data-0.8.0" = "sha256-dhczFDIFbcl2mMUtTIZaeaTtXWTHNw1fl2xgVcp93NE=";
        "stylo_taffy-0.2.0" = "sha256-RWQ5RpapA5ZmxJ9+LuUlL+RTwBcHRgZDM7Kok6yHpi8=";
        "taffy-0.9.2" = "sha256-PrLnNpo6pjChOKUzc1KgN7uxxAbGhY4tFffVMf2ZXbc=";
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
          nativeBuildInputs = [
            cross.buildPackages.pkg-config
            cross.buildPackages.python3
          ];
          buildInputs = lib.optionals cross.stdenv.hostPlatform.isLinux [ staticXkbcommon ];
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
          nativeBuildInputs = [
            cross.buildPackages.pkg-config
            cross.buildPackages.python3
          ];
          buildInputs = [
            cross.wayland
            cross.expat
            cross.libffi
          ];
          PKG_CONFIG_ALL_STATIC = "1";
        };
      mkShadowBlitzDemoFor = cross: rendererFeature:
        let
          rendererSuffix = lib.replaceStrings [ "_" ] [ "-" ] rendererFeature;
        in cross.rustPlatform.buildRustPackage {
          pname = "shadow-blitz-demo-${rendererSuffix}";
          version = "0.1.0";
          src = ./ui;
          cargoLock = {
            lockFile = ./ui/Cargo.lock;
            outputHashes = uiBlitzOutputHashes;
          };
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = cross.stdenv.hostPlatform.config;
          PYTHON3 = "${cross.buildPackages.python3}/bin/python3";
          cargoBuildFlags = [
            "-p"
            "shadow-blitz-demo"
            "--no-default-features"
            "--features"
            rendererFeature
          ];
          cargoInstallFlags = [
            "-p"
            "shadow-blitz-demo"
            "--no-default-features"
            "--features"
            rendererFeature
          ];
          nativeBuildInputs = [ cross.buildPackages.pkg-config ];
          depsBuildBuild =
            lib.optionals cross.stdenv.buildPlatform.isDarwin [
              cross.buildPackages.stdenv.cc
              cross.buildPackages.libiconv
            ];
          buildInputs = [
            cross.expat
            cross.fontconfig
            cross.freetype
            cross.libdrm
            cross.libffi
            cross.libglvnd
            cross.libxkbcommon
            cross.mesa.drivers
            cross.vulkan-loader
            cross.wayland
            cross.wayland-protocols
          ];
          postInstall = ''
            mkdir -p "$out/runtime-libs"
            ln -s "${cross.expat}" "$out/runtime-libs/expat"
            ln -s "${cross.fontconfig}" "$out/runtime-libs/fontconfig"
            ln -s "${cross.freetype}" "$out/runtime-libs/freetype"
            ln -s "${cross.libdrm}" "$out/runtime-libs/libdrm"
            ln -s "${cross.libffi}" "$out/runtime-libs/libffi"
            ln -s "${cross.libglvnd}" "$out/runtime-libs/libglvnd"
            ln -s "${cross.libxkbcommon}" "$out/runtime-libs/libxkbcommon"
            ln -s "${cross.mesa.drivers}" "$out/runtime-libs/mesa-drivers"
            ln -s "${cross.vulkan-loader}" "$out/runtime-libs/vulkan-loader"
            ln -s "${cross.wayland}" "$out/runtime-libs/wayland"
            ln -s "${cross.wayland-protocols}" "$out/runtime-libs/wayland-protocols"
            if [ -d "${cross.mesa.drivers}/lib/dri" ]; then
              mkdir -p "$out/lib"
              ln -s "${cross.mesa.drivers}/lib/dri" "$out/lib/dri"
            fi
            if [ -d "${cross.mesa.drivers}/share/vulkan/icd.d" ]; then
              mkdir -p "$out/share/vulkan"
              ln -s "${cross.mesa.drivers}/share/vulkan/icd.d" "$out/share/vulkan/icd.d"
            fi
            if [ -d "${cross.mesa.drivers}/share/glvnd/egl_vendor.d" ]; then
              mkdir -p "$out/share/glvnd"
              ln -s "${cross.mesa.drivers}/share/glvnd/egl_vendor.d" "$out/share/glvnd/egl_vendor.d"
            elif [ -d "${cross.libglvnd}/share/glvnd/egl_vendor.d" ]; then
              mkdir -p "$out/share/glvnd"
              ln -s "${cross.libglvnd}/share/glvnd/egl_vendor.d" "$out/share/glvnd/egl_vendor.d"
            fi
          '';
          meta.mainProgram = "shadow-blitz-demo";
        };
      mkShadowRuntimeHostFor = cross:
        cross.rustPlatform.buildRustPackage {
          pname = "shadow-runtime-host";
          version = "0.1.0";
          src = ./.;
          cargoRoot = "rust/shadow-runtime-host";
          buildAndTestSubdir = "rust/shadow-runtime-host";
          cargoLock.lockFile = ./rust/shadow-runtime-host/Cargo.lock;
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = cross.stdenv.hostPlatform.config;
          nativeBuildInputs = [ cross.buildPackages.pkg-config ];
          depsBuildBuild =
            lib.optionals cross.stdenv.buildPlatform.isDarwin [
              cross.buildPackages.stdenv.cc
              cross.buildPackages.libiconv
            ];
          RUSTY_V8_ARCHIVE = mkRustyV8ArchiveFor cross;
          meta.mainProgram = "shadow-runtime-host";
        };
      mkShadowLinuxAudioSpikeFor = cross:
        cross.rustPlatform.buildRustPackage {
          pname = "shadow-linux-audio-spike";
          version = "0.1.0";
          src = ./.;
          cargoRoot = "rust/shadow-linux-audio-spike";
          buildAndTestSubdir = "rust/shadow-linux-audio-spike";
          cargoLock.lockFile = ./rust/shadow-linux-audio-spike/Cargo.lock;
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = cross.stdenv.hostPlatform.config;
          nativeBuildInputs = [ cross.buildPackages.pkg-config ];
          buildInputs = [ cross.alsa-lib ];
          meta.mainProgram = "shadow-linux-audio-spike";
        };
      mkShadowSession = pkgs: mkShadowSessionFor pkgs.pkgsCross.musl64;
      mkDrmRect = pkgs: mkDrmRectFor pkgs.pkgsCross.musl64;
      mkShadowGuestCompositor = pkgs: mkShadowGuestCompositorFor pkgs.pkgsStatic;
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
            python3
            rustc
            rustfmt
            zig
          ];
          runtimeLibs =
            (with pkgs; [ libxkbcommon ])
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux (with pkgs; [
              libdrm
              libGL
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
            export PKG_CONFIG_PATH="${pkgConfigPath}:''${PKG_CONFIG_PATH:-}"
            ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
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
            deno
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
            sqlite
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
          shadow-linux-audio-spike-aarch64-linux-gnu =
            mkShadowLinuxAudioSpikeFor pkgs.pkgsCross.aarch64-multiplatform;
          shadow-runtime-host = mkShadowRuntimeHostFor pkgs;
          shadow-runtime-host-aarch64-linux-gnu =
            mkShadowRuntimeHostFor pkgs.pkgsCross.aarch64-multiplatform;
          shadow-runtime-host-x86_64-linux-gnu =
            mkShadowRuntimeHostFor pkgs.pkgsCross.gnu64;
          drm-rect = mkDrmRect pkgs;
          drm-rect-device = mkDrmRectFor pkgs.pkgsCross.aarch64-multiplatform-musl;
          shadow-session = mkShadowSession pkgs;
          shadow-session-device = mkShadowSessionFor pkgs.pkgsCross.aarch64-multiplatform-musl;
          default = mkShadowSession pkgs;
          ui-vm =
            if pkgs.stdenv.isDarwin && uiVmSource != null then
              self.nixosConfigurations."${pkgs.stdenv.hostPlatform.system}-shadow-ui-vm".config.microvm.declaredRunner
            else
              mkUnavailablePackage pkgs "shadow-ui-vm-unavailable"
                "ui-vm requires a macOS host plus SHADOW_UI_VM_SOURCE set under --impure. Use just ui-vm-run.";
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          shadow-blitz-demo-aarch64-linux-gnu-gpu =
            mkShadowBlitzDemoFor pkgs.pkgsCross.aarch64-multiplatform "gpu";
          shadow-blitz-demo-aarch64-linux-gnu-gpu-softbuffer =
            mkShadowBlitzDemoFor pkgs.pkgsCross.aarch64-multiplatform "gpu_softbuffer";
          shadow-compositor-guest = mkShadowGuestCompositor pkgs;
          shadow-compositor-guest-device =
            mkShadowGuestCompositorFor pkgs.pkgsCross.aarch64-multiplatform-musl;
        });
    };
}
