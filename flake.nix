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
    android-nixpkgs = {
      url = "github:tadfisher/android-nixpkgs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    microvm = {
      url = "github:microvm-nix/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, android-nixpkgs, microvm, crane, rust-overlay }:
    let
      lib = nixpkgs.lib;
      guestSystemForHostSystem = hostSystem:
        builtins.replaceStrings [ "-darwin" ] [ "-linux" ] hostSystem;
      uiVmSourceEnv = builtins.getEnv "SHADOW_UI_VM_SOURCE";
      localMesaSourceEnv = builtins.getEnv "SHADOW_LOCAL_MESA_SOURCE";
      localMesaApplyRepoPatchEnv = builtins.getEnv "SHADOW_LOCAL_MESA_APPLY_REPO_PATCH";
      uiVmSshPortEnv = builtins.getEnv "SHADOW_UI_VM_SSH_PORT";
      uiVmSource =
        if uiVmSourceEnv != "" then
          uiVmSourceEnv
        else
          null;
      localMesaSourcePath =
        if localMesaSourceEnv != "" then
          /. + localMesaSourceEnv
        else
          null;
      localMesaSource =
        if localMesaSourcePath != null then
          lib.cleanSource localMesaSourcePath
        else
          null;
      localMesaApplyRepoPatch = localMesaApplyRepoPatchEnv != "0";
      uiVmSshPort =
        if uiVmSshPortEnv != "" then
          builtins.fromJSON uiVmSshPortEnv
        else
          2222;
      runtimeHostPackageAttrForHostSystem = hostSystem:
        if lib.hasPrefix "aarch64-" hostSystem then
          "shadow-runtime-host-aarch64-linux-gnu"
        else if lib.hasPrefix "x86_64-" hostSystem then
          "shadow-runtime-host-x86_64-linux-gnu"
        else
          throw "unsupported host system for runtime host package selection: ${hostSystem}";
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      repoRoot = ./.;
      repoRootStr = toString repoRoot;
      repoSourceFromPrefixes = prefixes:
        lib.cleanSourceWith {
          src = repoRoot;
          filter = path: _type:
            let
              pathStr = toString path;
              relPath =
                if pathStr == repoRootStr then
                  ""
                else
                  lib.removePrefix "${repoRootStr}/" pathStr;
              pathMatchesPrefix = prefix:
                relPath == prefix || lib.hasPrefix "${prefix}/" relPath;
              pathIsPrefixAncestor = prefix:
                relPath == "" || lib.hasPrefix "${relPath}/" prefix;
            in
              lib.any pathMatchesPrefix prefixes || lib.any pathIsPrefixAncestor prefixes;
        };
      shadowRuntimeHostSrc = repoSourceFromPrefixes [
        "rust/Cargo.toml"
        "rust/Cargo.lock"
        "rust/shadow-runtime-host"
        "rust/shadow-runtime-protocol"
        "rust/runtime-audio-host"
        "rust/runtime-camera-host"
        "rust/runtime-cashu-host"
        "rust/runtime-nostr-host"
        "rust/vendor/temporal_rs"
      ];
      shadowUiSrc = repoSourceFromPrefixes [
        "ui/Cargo.toml"
        "ui/Cargo.lock"
        "ui/apps"
        "ui/crates"
        "ui/third_party"
        "rust/shadow-runtime-protocol"
      ];
      shadowUiCoreSrc = repoSourceFromPrefixes [
        "ui/Cargo.toml"
        "ui/Cargo.lock"
        "ui/crates/shadow-ui-core"
        "ui/third_party"
        "rust/shadow-runtime-protocol"
      ];
      shadowCompositorSrc = repoSourceFromPrefixes [
        "ui/Cargo.toml"
        "ui/Cargo.lock"
        "ui/crates/shadow-ui-core"
        "ui/crates/shadow-ui-software"
        "ui/crates/shadow-compositor-common"
        "ui/crates/shadow-compositor"
        "ui/third_party"
        "rust/shadow-runtime-protocol"
      ];
      shadowCompositorGuestSrc = repoSourceFromPrefixes [
        "ui/Cargo.toml"
        "ui/Cargo.lock"
        "ui/crates/shadow-ui-core"
        "ui/crates/shadow-ui-software"
        "ui/crates/shadow-compositor-common"
        "ui/crates/shadow-compositor-guest"
        "ui/third_party"
        "rust/shadow-runtime-protocol"
      ];
      shadowLinuxAudioSpikeSrc = repoSourceFromPrefixes [
        "rust/shadow-linux-audio-spike"
      ];
      shadowBlitzDemoSrc = repoSourceFromPrefixes [
        "ui/Cargo.toml"
        "ui/Cargo.lock"
        "ui/apps/shadow-blitz-demo"
        "ui/crates/shadow-ui-core"
        "ui/third_party/anyrender_vello"
        "ui/third_party/softbuffer_window_renderer"
        "ui/third_party/wgpu_context"
        "ui/third_party/winit"
        "rust/shadow-runtime-protocol"
      ];
      shadowVmSmokeSrc = repoSourceFromPrefixes [
        "flake.nix"
        "flake.lock"
        "justfile"
        "patches"
        "runtime"
        "scripts"
        "vm"
        "rust/Cargo.toml"
        "rust/Cargo.lock"
        "rust/shadow-runtime-host"
        "rust/shadow-runtime-protocol"
        "rust/runtime-audio-host"
        "rust/runtime-camera-host"
        "rust/runtime-cashu-host"
        "rust/runtime-nostr-host"
        "rust/vendor/temporal_rs"
        "ui/Cargo.toml"
        "ui/Cargo.lock"
        "ui/apps"
        "ui/crates"
        "ui/third_party"
      ];
      darwinSystems = builtins.filter (system: lib.hasSuffix "-darwin" system) systems;
      forAllSystems = f:
        lib.genAttrs systems (
          system:
          let
            pkgs = import nixpkgs { inherit system; };
            androidDevPkgs = import nixpkgs {
              inherit system;
              overlays = [ (import rust-overlay) ];
            };
            androidSdk =
              if builtins.hasAttr system android-nixpkgs.sdk then
                android-nixpkgs.sdk.${system} (
                  sdkPkgs:
                  with sdkPkgs;
                  [
                    cmdline-tools-latest
                    platform-tools
                    ndk-28-2-13676358
                  ]
                )
              else
                null;
          in
            f {
              inherit androidDevPkgs androidSdk pkgs;
            }
        );
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
      uiCraneOutputHashes = {
        "git+https://github.com/DioxusLabs/blitz?rev=781ae63fdb6e76baa0969ba8cbce557327c7dfca#781ae63fdb6e76baa0969ba8cbce557327c7dfca" =
          "sha256-RWQ5RpapA5ZmxJ9+LuUlL+RTwBcHRgZDM7Kok6yHpi8=";
        "git+https://github.com/DioxusLabs/taffy?rev=4b6687da0ca1e9d71da4e48b4c659f5c45060707#4b6687da0ca1e9d71da4e48b4c659f5c45060707" =
          "sha256-PrLnNpo6pjChOKUzc1KgN7uxxAbGhY4tFffVMf2ZXbc=";
        "git+https://github.com/linebender/parley?rev=07980878fc9ea4b16ddc197ac789d01fb8ada7a3#07980878fc9ea4b16ddc197ac789d01fb8ada7a3" =
          "sha256-dhczFDIFbcl2mMUtTIZaeaTtXWTHNw1fl2xgVcp93NE=";
      };
      mkUiWorkspaceMembersPostPatch =
        cargoTomlPath: members:
        let
          memberLines = lib.concatMapStringsSep "" (member: "    \"${member}\",\n") members;
          replacement = "members = [\n${memberLines}]";
        in
          ''
            python3 - <<'PY'
            from pathlib import Path
            import re

            cargo_toml = Path(${builtins.toJSON cargoTomlPath})
            data = cargo_toml.read_text()
            data = re.sub(
                r"members = \[\n(?:    \".*\",\n)+\]",
                ${builtins.toJSON replacement},
                data,
                count=1,
            )
            cargo_toml.write_text(data)
            PY
          '';
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
          src = shadowCompositorGuestSrc;
          cargoRoot = "ui";
          buildAndTestSubdir = "ui";
          cargoLock = {
            lockFile = ./ui/Cargo.lock;
            outputHashes = uiBlitzOutputHashes;
          };
          postPatch = mkUiWorkspaceMembersPostPatch "ui/Cargo.toml" [
            "crates/shadow-ui-core"
            "crates/shadow-ui-software"
            "crates/shadow-compositor-common"
            "crates/shadow-compositor-guest"
          ];
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
      mkShadowCompositorFor = cross:
        cross.rustPlatform.buildRustPackage {
          pname = "shadow-compositor";
          version = "0.1.0";
          src = shadowCompositorSrc;
          cargoRoot = "ui";
          buildAndTestSubdir = "ui";
          cargoLock = {
            lockFile = ./ui/Cargo.lock;
            outputHashes = uiBlitzOutputHashes;
          };
          postPatch = mkUiWorkspaceMembersPostPatch "ui/Cargo.toml" [
            "crates/shadow-ui-core"
            "crates/shadow-ui-software"
            "crates/shadow-compositor-common"
            "crates/shadow-compositor"
          ];
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = cross.stdenv.hostPlatform.config;
          cargoBuildFlags = [ "-p" "shadow-compositor" ];
          cargoInstallFlags = [ "-p" "shadow-compositor" ];
          nativeBuildInputs = [
            cross.buildPackages.pkg-config
            cross.buildPackages.python3
          ];
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
            cross.libGL
            cross.libxkbcommon
            cross.mesa
            cross.vulkan-loader
            cross.wayland
            cross.wayland-protocols
            cross.libx11
            cross.libxcursor
            cross.libxi
            cross.libxrandr
          ];
          meta.mainProgram = "shadow-compositor";
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
          src = ./.;
          cargoRoot = "ui";
          buildAndTestSubdir = "ui";
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
      mkShadowBlitzDemoFor =
        cross:
        {
          features ? [ ],
          pnameSuffix ? null,
          useDefaultFeatures ? false,
        }:
        let
          suffix =
            if pnameSuffix != null then
              pnameSuffix
            else
              lib.concatMapStringsSep "-" (feature: lib.replaceStrings [ "_" ] [ "-" ] feature) features;
          defaultFeatureArgs = lib.optionals (!useDefaultFeatures) [ "--no-default-features" ];
          featureArgs = lib.optionals (features != [ ]) [
            "--features"
            (lib.concatStringsSep "," features)
          ];
        in cross.rustPlatform.buildRustPackage {
          pname =
            if suffix == "" then
              "shadow-blitz-demo"
            else
              "shadow-blitz-demo-${suffix}";
          version = "0.1.0";
          src = shadowBlitzDemoSrc;
          cargoRoot = "ui";
          buildAndTestSubdir = "ui";
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
          ] ++ defaultFeatureArgs ++ featureArgs;
          cargoInstallFlags = [
            "-p"
            "shadow-blitz-demo"
          ] ++ defaultFeatureArgs ++ featureArgs;
          nativeBuildInputs = [
            cross.buildPackages.pkg-config
            cross.buildPackages.python3
          ];
          postPatch = mkUiWorkspaceMembersPostPatch "ui/Cargo.toml" [
            "crates/shadow-ui-core"
            "apps/shadow-blitz-demo"
          ];
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
            cross.mesa
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
            ln -s "${cross.mesa}" "$out/runtime-libs/mesa-drivers"
            ln -s "${cross.vulkan-loader}" "$out/runtime-libs/vulkan-loader"
            ln -s "${cross.wayland}" "$out/runtime-libs/wayland"
            ln -s "${cross.wayland-protocols}" "$out/runtime-libs/wayland-protocols"
            if [ -d "${cross.mesa}/lib/dri" ]; then
              mkdir -p "$out/lib"
              ln -s "${cross.mesa}/lib/dri" "$out/lib/dri"
            fi
            if [ -d "${cross.mesa}/share/vulkan/icd.d" ]; then
              mkdir -p "$out/share/vulkan"
              ln -s "${cross.mesa}/share/vulkan/icd.d" "$out/share/vulkan/icd.d"
            fi
            if [ -d "${cross.mesa}/share/glvnd/egl_vendor.d" ]; then
              mkdir -p "$out/share/glvnd"
              ln -s "${cross.mesa}/share/glvnd/egl_vendor.d" "$out/share/glvnd/egl_vendor.d"
            elif [ -d "${cross.libglvnd}/share/glvnd/egl_vendor.d" ]; then
              mkdir -p "$out/share/glvnd"
              ln -s "${cross.libglvnd}/share/glvnd/egl_vendor.d" "$out/share/glvnd/egl_vendor.d"
            fi
          '';
          meta.mainProgram = "shadow-blitz-demo";
        };
      mesaTurnipKnownGoodRev = "81feb2e7f1196dec7faee7791e17e472f9d8702a";
      mesaTurnipKnownGoodArchive =
        "https://gitlab.freedesktop.org/mesa/mesa/-/archive/${mesaTurnipKnownGoodRev}/mesa-${mesaTurnipKnownGoodRev}.tar.gz";
      mkShadowTurnipMesaFor = cross: { pname, src, patches ? [ ] }:
        (cross.mesa.override {
            galliumDrivers = [ ];
            vulkanDrivers = [ "freedreno" ];
            eglPlatforms = [ "x11" "wayland" ];
            vulkanLayers = [ ];
            enablePatentEncumberedCodecs = false;
            withValgrind = false;
          }).overrideAttrs (old: {
            inherit pname src;
            outputs = [ "out" ];
            patches = (old.patches or [ ]) ++ patches;
            mesonFlags = (old.mesonFlags or [ ]) ++ [
              (lib.mesonEnable "xlib-lease" false)
              (lib.mesonBool "opengl" false)
              (lib.mesonEnable "gles1" false)
              (lib.mesonEnable "gles2" false)
              (lib.mesonOption "glx" "disabled")
              (lib.mesonEnable "egl" false)
              (lib.mesonEnable "glvnd" false)
              (lib.mesonEnable "gbm" false)
              (lib.mesonBool "teflon" false)
              (lib.mesonBool "gallium-rusticl" false)
              (lib.mesonBool "gallium-extra-hud" false)
              (lib.mesonEnable "gallium-va" false)
              (lib.mesonEnable "intel-rt" false)
              (lib.mesonEnable "llvm" false)
              (lib.mesonBool "build-tests" false)
              (lib.mesonEnable "libunwind" false)
              (lib.mesonBool "lmsensors" false)
              (lib.mesonEnable "android-libbacktrace" false)
              (lib.mesonOption "freedreno-kmds" "msm,kgsl")
              (lib.mesonOption "tools" "")
            ];
            postInstall = ''
              mkdir -p "$out/nix-support"
              printf '%s\n' "$out/lib/libvulkan_freedreno.so" > "$out/nix-support/libvulkan-freedreno-path"
            '';
            postFixup = "";
          });
      mkShadowPinnedTurnipMesaFor = cross:
        mkShadowTurnipMesaFor cross {
          pname = "shadow-pinned-turnip-mesa";
          src = cross.fetchzip {
            url = mesaTurnipKnownGoodArchive;
            hash = "sha256-/V2epd3eXAFZJME4ocQmD5ihVNiaK/ysN2gXfj0f1hg=";
            stripRoot = true;
          };
          patches = [
            ./patches/mesa/0002-shadow-turnip-direct-gpu-known-good.patch
          ];
        };
      mkShadowLocalTurnipMesaFor = cross:
        if localMesaSource == null then
          mkUnavailablePackage cross.buildPackages "shadow-local-turnip-mesa-unavailable"
            "Set SHADOW_LOCAL_MESA_SOURCE under --impure to a local Mesa checkout."
        else
          mkShadowTurnipMesaFor cross {
            pname = "shadow-local-turnip-mesa";
            src = localMesaSource;
            patches =
              lib.optionals localMesaApplyRepoPatch [
                ./patches/mesa/0001-turnip-kgsl-ignore-khr-display.patch
              ];
          };
      mkShadowRuntimeHostFor = cross:
        let
          craneLib = crane.mkLib cross;
          commonArgs = {
            pname = "shadow-runtime-host";
            version = "0.1.0";
            src = shadowRuntimeHostSrc;
            cargoLock = ./rust/Cargo.lock;
            cargoToml = ./rust/Cargo.toml;
            cargoExtraArgs = "--locked -p shadow-runtime-host";
            doCheck = false;
            strictDeps = true;
            CARGO_BUILD_TARGET = cross.stdenv.hostPlatform.rust.rustcTarget;
            postUnpack = ''
              cd "$sourceRoot/rust"
              sourceRoot="."
            '';
            nativeBuildInputs = [ cross.buildPackages.pkg-config ];
            depsBuildBuild =
              lib.optionals cross.stdenv.buildPlatform.isDarwin [
                cross.buildPackages.stdenv.cc
                cross.buildPackages.libiconv
            ];
            RUSTY_V8_ARCHIVE = mkRustyV8ArchiveFor cross;
          };
          cargoVendorDir = craneLib.vendorCargoDeps commonArgs;
          cargoArgs = commonArgs // { inherit cargoVendorDir; };
          cargoArtifacts = craneLib.buildDepsOnly ((builtins.removeAttrs cargoArgs [ "src" ]) // {
            pname = "shadow-runtime-host-deps";
            dummySrc = craneLib.mkDummySrc (commonArgs // {
              extraDummyScript = ''
                rm -rf "$out/rust/vendor/temporal_rs"
                mkdir -p "$out/rust/vendor"
                cp --recursive --no-preserve=ownership ${./rust/vendor/temporal_rs} "$out/rust/vendor/temporal_rs"
                chmod +w -R "$out/rust/vendor/temporal_rs"
              '';
            });
          });
        in craneLib.buildPackage (cargoArgs // {
          inherit cargoArtifacts;
          meta.mainProgram = "shadow-runtime-host";
        });
      mkShadowLinuxAudioSpikeFor = cross:
        cross.rustPlatform.buildRustPackage {
          pname = "shadow-linux-audio-spike";
          version = "0.1.0";
          src = shadowLinuxAudioSpikeSrc;
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
      mkShadowCameraProviderHostFor = cross:
        cross.rustPlatform.buildRustPackage {
          pname = "shadow-camera-provider-host";
          version = "0.1.0";
          src = ./.;
          cargoRoot = "rust/shadow-camera-provider-host";
          buildAndTestSubdir = "rust/shadow-camera-provider-host";
          cargoLock.lockFile = ./rust/shadow-camera-provider-host/Cargo.lock;
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = cross.stdenv.hostPlatform.config;
          meta.mainProgram = "shadow-camera-provider-host";
        };
      mkShadowSession = pkgs: mkShadowSessionFor pkgs.pkgsCross.musl64;
      mkDrmRect = pkgs: mkDrmRectFor pkgs.pkgsCross.musl64;
      mkShadowGuestCompositor = pkgs: mkShadowGuestCompositorFor pkgs.pkgsStatic;
      shadowCliShellHook = ''
        shadow_root="$PWD"
        if git_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
          shadow_root="$git_root"
        fi
        if [ -d "$shadow_root/scripts" ]; then
          export PATH="$shadow_root/scripts:$PATH"
        fi
      '';
      mkAndroidShell = pkgs: androidSdk:
        let
          rustToolchain = pkgs.rust-bin.stable.latest.default.override {
            extensions = [ "rust-src" ];
            targets = [ "aarch64-linux-android" ];
          };
          toolPkgs = [
            androidSdk
            rustToolchain
            pkgs.bash
            pkgs.cargo-ndk
            pkgs.coreutils
            pkgs.findutils
            pkgs.gnugrep
            pkgs.gnused
            pkgs.jdk17_headless
            pkgs.just
            pkgs.pkg-config
            pkgs.python3
          ];
        in
        pkgs.mkShell {
          packages = toolPkgs;

          shellHook = ''
            export PATH="${pkgs.lib.makeBinPath toolPkgs}:$PATH"
            export IN_NIX_SHELL=1
            export SHADOW_ANDROID_SHELL=1
            export ANDROID_HOME=${androidSdk}/share/android-sdk
            export ANDROID_SDK_ROOT=${androidSdk}/share/android-sdk
            export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/28.2.13676358"
            ${shadowCliShellHook}
          '';
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
            ${shadowCliShellHook}
          '';
        };
      mkUiShell = pkgs:
        let
          toolPkgs = with pkgs; [
            android-tools
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
            ${shadowCliShellHook}
          '';
        };
      uiCheckRuntimeLibsFor = pkgs:
        [ pkgs.libxkbcommon ]
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
      uiCheckNativeBuildInputsFor = pkgs: with pkgs; [
        pkg-config
        python3
      ];
      mkShadowUiChecksFor = pkgs:
        let
          craneLib = crane.mkLib pkgs;
          commonArgs = {
            pname = "shadow-ui-workspace";
            version = "0.1.0";
            src = shadowUiSrc;
            cargoLock = ./ui/Cargo.lock;
            cargoToml = ./ui/Cargo.toml;
            outputHashes = uiCraneOutputHashes;
            cargoExtraArgs = "--locked";
            doCheck = false;
            strictDeps = true;
            CARGO_PROFILE = "";
            postUnpack = ''
              cd "$sourceRoot/ui"
              sourceRoot="."
            '';
            nativeBuildInputs = uiCheckNativeBuildInputsFor pkgs;
            buildInputs = uiCheckRuntimeLibsFor pkgs;
          };
          cargoVendorDir = craneLib.vendorCargoDeps commonArgs;
          cargoArgs = commonArgs // { inherit cargoVendorDir; };
          cargoArtifacts = craneLib.buildDepsOnly ((builtins.removeAttrs cargoArgs [ "src" ]) // {
            pname = "shadow-ui-workspace-deps";
            dummySrc = craneLib.mkDummySrc commonArgs;
          });
          mkUiTestArgs =
            {
              pname,
            }:
            cargoArgs
            // {
              inherit pname cargoArtifacts;
              doCheck = true;
              doInstallCargoArtifacts = false;
              installPhaseCommand = "mkdir -p $out";
            };
          mkUiCargoCheck =
            {
              pname,
              cargoCheckExtraArgs,
            }:
            craneLib.mkCargoDerivation (cargoArgs // {
              inherit pname cargoArtifacts;
              doInstallCargoArtifacts = false;
              buildPhaseCargoCommand =
                "cargo check --locked ${cargoCheckExtraArgs}";
              checkPhaseCargoCommand = "";
              installPhaseCommand = "mkdir -p $out";
            });
          coreChecks =
            {
              uiFmt = craneLib.cargoFmt {
                pname = "shadow-ui-workspace";
                version = "0.1.0";
                src = shadowUiSrc;
                cargoToml = ./ui/Cargo.toml;
                cargoExtraArgs = "--all";
                postUnpack = ''
                  cd "$sourceRoot/ui"
                  sourceRoot="."
                '';
              };
              uiShadowUiCoreTests = craneLib.cargoTest (mkUiTestArgs {
                pname = "shadow-ui-core";
              } // {
                cargoTestExtraArgs = "-p shadow-ui-core";
              });
              uiShadowBlitzDemoAppTests = craneLib.cargoTest (mkUiTestArgs {
                pname = "shadow-blitz-demo-app-tests";
              } // {
                cargoTestExtraArgs = "-p shadow-blitz-demo app::tests::";
              });
              uiShadowBlitzDemoRuntimeDocumentTests = craneLib.cargoTest (mkUiTestArgs {
                pname = "shadow-blitz-demo-runtime-document-tests";
              } // {
                cargoTestExtraArgs = "-p shadow-blitz-demo runtime_document";
              });
              uiShadowCompositorGuestTests = craneLib.cargoTest (mkUiTestArgs {
                pname = "shadow-compositor-guest-tests";
              } // {
                cargoTestExtraArgs = "-p shadow-compositor-guest";
              });
              uiShadowBlitzDemoHostSystemFontsCheck = mkUiCargoCheck {
                pname = "shadow-blitz-demo-host-system-fonts-check";
                cargoCheckExtraArgs = "-p shadow-blitz-demo --features host_system_fonts";
              };
              uiShadowBlitzDemoGpuCheck = mkUiCargoCheck {
                pname = "shadow-blitz-demo-gpu-check";
                cargoCheckExtraArgs =
                  "-p shadow-blitz-demo --no-default-features --features gpu";
              };
            }
            // lib.optionalAttrs pkgs.stdenv.isLinux {
              uiShadowCompositorCheck = mkUiCargoCheck {
                pname = "shadow-compositor-check";
                cargoCheckExtraArgs = "-p shadow-compositor";
              };
              uiShadowCompositorGuestCheck = mkUiCargoCheck {
                pname = "shadow-compositor-guest-check";
                cargoCheckExtraArgs = "-p shadow-compositor-guest";
              };
            };
        in
          coreChecks
          // {
            uiCheck = pkgs.linkFarm "shadow-ui-check" (
              lib.mapAttrsToList (name: path: { inherit name path; }) coreChecks
            );
          };
      mkRuntimeShell = pkgs:
        let
          toolPkgs = with pkgs; [
            android-tools
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
            ${shadowCliShellHook}
          '';
        };
      mkShadowUiVmConfig = hostSystem:
        let
          guestSystem = guestSystemForHostSystem hostSystem;
        in
          import ./vm/shadow-ui-vm.nix {
            inherit hostSystem microvm nixpkgs;
            shadowBlitzDemoPackage =
              self.packages.${guestSystem}.shadow-blitz-demo-host-system-fonts;
            shadowCompositorPackage = self.packages.${guestSystem}.shadow-compositor;
            sshPort = uiVmSshPort;
          };
      mkVmSmokeInputsFor = pkgs:
        let
          hostSystem = pkgs.stdenv.hostPlatform.system;
          runtimeHostPackageAttr = runtimeHostPackageAttrForHostSystem hostSystem;
          runtimeHostPackage = self.packages.${hostSystem}.${runtimeHostPackageAttr};
          uiVmRunnerPackage = self.packages.${hostSystem}.ui-vm-ci;
          requiredAppsJson = builtins.toJSON [
            "camera"
            "cashu"
            "counter"
            "podcast"
            "timeline"
          ];
        in
          pkgs.runCommandLocal "shadow-vm-smoke-inputs" {
            preferLocalBuild = true;
            allowSubstitutes = false;
          } ''
            mkdir -p "$out"
            ln -s ${shadowVmSmokeSrc} "$out/source"
            ln -s ${runtimeHostPackage} "$out/runtime-host"
            ln -s ${uiVmRunnerPackage} "$out/ui-vm-runner"
            cat >"$out/metadata.json" <<EOF
            {
              "schemaVersion": 1,
              "sourceStorePath": "${shadowVmSmokeSrc}",
              "runtimeHostPackageAttr": "${runtimeHostPackageAttr}",
              "runtimeHostBinaryPath": "${runtimeHostPackage}/bin/shadow-runtime-host",
              "runtimeHostPackagePath": "${runtimeHostPackage}",
              "uiVmRunnerPackagePath": "${uiVmRunnerPackage}",
              "uiVmRunnerBinaryPath": "${uiVmRunnerPackage}/bin/microvm-run",
              "requiredApps": ${requiredAppsJson}
            }
            EOF
          '';
    in {
      nixosConfigurations = lib.listToAttrs (lib.concatMap (
        hostSystem:
        let
          shadowUiVmConfig = mkShadowUiVmConfig hostSystem;
        in
          [
            {
              name = "${hostSystem}-shadow-ui-vm-ci";
              value = shadowUiVmConfig;
            }
          ]
      ) darwinSystems);
      devShells = forAllSystems ({ androidDevPkgs, androidSdk, pkgs }: {
        android =
          if androidSdk != null then
            mkAndroidShell androidDevPkgs androidSdk
          else
            mkUnavailablePackage pkgs "shadow-android-shell-unavailable"
              "android shell requires android-nixpkgs support for this host";
        bootimg = mkBootimgShell pkgs;
        runtime = mkRuntimeShell pkgs;
        ui = mkUiShell pkgs;
        default = mkBootimgShell pkgs;
      });
      packages = forAllSystems ({ pkgs, ... }:
        {
          shadow-linux-audio-spike =
            if pkgs.stdenv.isLinux then
              mkShadowLinuxAudioSpikeFor pkgs
            else
              mkUnavailablePackage pkgs "shadow-linux-audio-spike-unavailable"
                "shadow-linux-audio-spike is only available on Linux hosts";
          shadow-linux-audio-spike-aarch64-linux-gnu =
            mkShadowLinuxAudioSpikeFor pkgs.pkgsCross.aarch64-multiplatform;
          shadow-camera-provider-host = mkShadowCameraProviderHostFor pkgs;
          shadow-runtime-host = mkShadowRuntimeHostFor pkgs;
          shadow-runtime-host-aarch64-linux-gnu =
            mkShadowRuntimeHostFor pkgs.pkgsCross.aarch64-multiplatform;
          shadow-runtime-host-x86_64-linux-gnu =
            mkShadowRuntimeHostFor pkgs.pkgsCross.gnu64;
          drm-rect = mkDrmRect pkgs;
          drm-rect-device = mkDrmRectFor pkgs.pkgsCross.aarch64-multiplatform-musl;
          init-wrapper-device = mkInitWrapperFor pkgs.pkgsCross.aarch64-multiplatform-musl;
          shadow-session = mkShadowSession pkgs;
          shadow-session-device = mkShadowSessionFor pkgs.pkgsCross.aarch64-multiplatform-musl;
          default = mkShadowSession pkgs;
          ui-vm-ci =
            if pkgs.stdenv.isDarwin then
              self.nixosConfigurations."${pkgs.stdenv.hostPlatform.system}-shadow-ui-vm-ci".config.microvm.declaredRunner
            else
              mkUnavailablePackage pkgs "shadow-ui-vm-ci-unavailable"
                "ui-vm-ci requires a macOS host. Use just run target=vm.";
          vm-smoke-inputs = mkVmSmokeInputsFor pkgs;
        }
        // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          shadow-blitz-demo-aarch64-linux-gnu-gpu =
            mkShadowBlitzDemoFor pkgs.pkgsCross.aarch64-multiplatform {
              features = [ "gpu" ];
            };
          shadow-blitz-demo-aarch64-linux-gnu-gpu-softbuffer =
            mkShadowBlitzDemoFor pkgs.pkgsCross.aarch64-multiplatform {
              features = [ "gpu_softbuffer" ];
            };
          shadow-blitz-demo-host-system-fonts =
            mkShadowBlitzDemoFor pkgs {
              features = [ "host_system_fonts" ];
              pnameSuffix = "host-system-fonts";
              useDefaultFeatures = true;
            };
          shadow-compositor = mkShadowCompositorFor pkgs;
          shadow-pinned-turnip-mesa-aarch64-linux =
            mkShadowPinnedTurnipMesaFor pkgs.pkgsCross.aarch64-multiplatform;
          shadow-local-turnip-mesa-aarch64-linux =
            mkShadowLocalTurnipMesaFor pkgs.pkgsCross.aarch64-multiplatform;
          shadow-compositor-guest = mkShadowGuestCompositor pkgs;
          shadow-compositor-guest-device =
            mkShadowGuestCompositorFor pkgs.pkgsCross.aarch64-multiplatform-musl;
        });
      legacyPackages = forAllSystems ({ pkgs, ... }:
        let
          hostSystem = pkgs.stdenv.hostPlatform.system;
          runtimeHostPackageAttr = runtimeHostPackageAttrForHostSystem hostSystem;
        in
          {
            ci = {
              vmRuntimeHost = self.packages.${hostSystem}.${runtimeHostPackageAttr};
              vmUiRunner = self.packages.${hostSystem}.ui-vm-ci;
              vmSmokeInputs = mkVmSmokeInputsFor pkgs;
            };
          });
      checks = forAllSystems ({ pkgs, ... }:
        mkShadowUiChecksFor pkgs
      );
    };
}
