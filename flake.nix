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
      systemPackageAttrForHostSystem = hostSystem:
        if lib.hasPrefix "aarch64-" hostSystem then
          "shadow-system-aarch64-linux-gnu"
        else if lib.hasPrefix "x86_64-" hostSystem then
          "shadow-system-x86_64-linux-gnu"
        else
          throw "unsupported host system for Shadow system package selection: ${hostSystem}";
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      publicDevShellNames = [
        "default"
        "bootimg"
        "ui"
        "runtime"
        "android"
      ];
      repoRoot =
        if uiVmSource != null then
          /. + uiVmSource
        else
          ./.;
      appManifestPath =
        if uiVmSource != null then
          /. + "${uiVmSource}/runtime/apps.json"
        else
          ./runtime/apps.json;
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
      shadowSystemSrc = repoSourceFromPrefixes [
        "rust/Cargo.toml"
        "rust/Cargo.lock"
        "rust/shadow-sdk"
        "rust/shadow-system"
        "rust/shadow-runtime-protocol"
        "rust/vendor/temporal_rs"
        "rust/vendor/xilem"
      ];
      shadowInitWrapperSrc = repoSourceFromPrefixes [
        "rust/init-wrapper"
      ];
      shadowRuntimeBundleTestSrc = repoSourceFromPrefixes [
        "deno.json"
        "deno.lock"
        "runtime/app-counter"
        "runtime/app-runtime"
        "scripts/runtime/runtime_compile_solid.ts"
        "scripts/runtime/runtime_prepare_app_bundle.ts"
        "scripts/runtime/runtime_prepare_app_bundle_test.ts"
      ];
      shadowPixelBootShellCommonPrefixes = [
        "scripts/lib/pixel_common.sh"
        "scripts/lib/pixel_root_boot_common.sh"
        "scripts/lib/pixel_runtime_session_common.sh"
        "scripts/lib/shadow_common.sh"
      ];
      shadowPixelBootBootimgCommonPrefixes = shadowPixelBootShellCommonPrefixes ++ [
        "scripts/lib/bootimg_common.sh"
        "scripts/lib/cpio_edit.py"
      ];
      shadowPixelBootNixBuildPrefixes = [
        "flake.nix"
        "flake.lock"
      ];
      shadowPixelBootHelloInitSmokeSrc = repoSourceFromPrefixes (
        shadowPixelBootBootimgCommonPrefixes
        ++ shadowPixelBootNixBuildPrefixes
        ++ [
          "scripts/ci/pixel_boot_hello_init_smoke.sh"
          "scripts/pixel/pixel_boot_build.sh"
          "scripts/pixel/pixel_build_hello_init.sh"
          "scripts/pixel/pixel_boot_build_hello_init.sh"
          "scripts/pixel/pixel_hello_init.c"
        ]
      );
      shadowPixelBootOrangeInitSmokeSrc = repoSourceFromPrefixes (
        shadowPixelBootBootimgCommonPrefixes
        ++ shadowPixelBootNixBuildPrefixes
        ++ [
          "scripts/ci/pixel_boot_orange_init_smoke.sh"
          "scripts/pixel/pixel_boot_build.sh"
          "scripts/pixel/pixel_build_hello_init.sh"
          "scripts/pixel/pixel_build_orange_init.sh"
          "scripts/pixel/pixel_boot_build_orange_init.sh"
          "scripts/pixel/pixel_hello_init.c"
          "rust/drm-rect/Cargo.toml"
          "rust/drm-rect/Cargo.lock"
          "rust/drm-rect/src/lib.rs"
          "rust/drm-rect/src/main.rs"
        ]
      );
      shadowPixelBootToolingSmokeSrc = repoSourceFromPrefixes (
        shadowPixelBootBootimgCommonPrefixes
        ++ [
          "scripts/ci/pixel_boot_recover_traces_smoke.sh"
          "scripts/ci/pixel_boot_tooling_smoke.sh"
          "scripts/pixel/pixel_boot_build.sh"
          "scripts/pixel/pixel_boot_build_init_symlink_probe.sh"
          "scripts/pixel/pixel_boot_build_log_probe.sh"
          "scripts/pixel/pixel_boot_build_rc_probe.sh"
          "scripts/pixel/pixel_boot_build_system_init_symlink_probe.sh"
          "scripts/pixel/pixel_boot_build_system_init_wrapper_probe.sh"
          "scripts/pixel/pixel_boot_collect_logs.sh"
          "scripts/pixel/pixel_boot_flash.sh"
          "scripts/pixel/pixel_boot_flash_run.sh"
          "scripts/pixel/pixel_boot_oneshot.sh"
          "scripts/pixel/pixel_boot_recover.sh"
          "scripts/pixel/pixel_boot_recover_traces.sh"
          "scripts/pixel/pixel_build_init_wrapper.sh"
          "scripts/pixel/pixel_build_init_wrapper_c.sh"
        ]
      );
      shadowPixelBootRecoverTracesSmokeSrc = repoSourceFromPrefixes (
        shadowPixelBootShellCommonPrefixes
        ++ [
          "scripts/ci/pixel_boot_recover_traces_smoke.sh"
          "scripts/pixel/pixel_boot_recover_traces.sh"
        ]
      );
      shadowPixelBootCollectLogsSmokeSrc = repoSourceFromPrefixes (
        shadowPixelBootShellCommonPrefixes
        ++ [
          "scripts/ci/pixel_boot_collect_logs_smoke.sh"
          "scripts/pixel/pixel_boot_collect_logs.sh"
        ]
      );
      shadowPixelBootSafetySmokeSrc = repoSourceFromPrefixes (
        shadowPixelBootShellCommonPrefixes
        ++ [
          "scripts/ci/pixel_boot_safety_smoke.sh"
          "scripts/pixel/pixel_boot_flash.sh"
          "scripts/pixel/pixel_boot_recover.sh"
          "scripts/pixel/pixel_boot_restore.sh"
        ]
      );
      shadowUiSrc = repoSourceFromPrefixes [
        "ui/Cargo.toml"
        "ui/Cargo.lock"
        "ui/apps"
        "ui/crates"
        "ui/third_party"
        "rust/Cargo.toml"
        "rust/Cargo.lock"
        "rust/shadow-sdk"
        "rust/shadow-system"
        "rust/shadow-runtime-protocol"
        "rust/vendor/temporal_rs"
        "rust/vendor/xilem"
      ];
      shadowUiWorkspaceMemberCargoTomlPrefixes = [
        "ui/apps/shadow-blitz-demo/Cargo.toml"
        "ui/apps/shadow-rust-demo/Cargo.toml"
        "ui/apps/shadow-rust-timeline/Cargo.toml"
        "ui/crates/shadow-compositor/Cargo.toml"
        "ui/crates/shadow-compositor-common/Cargo.toml"
        "ui/crates/shadow-compositor-guest/Cargo.toml"
        "ui/crates/shadow-ui-core/Cargo.toml"
        "ui/crates/shadow-ui-software/Cargo.toml"
      ];
      shadowUiWorkspaceMemberTargetPrefixes = [
        "ui/apps/shadow-rust-demo/src/main.rs"
        "ui/apps/shadow-rust-timeline/src/main.rs"
        "ui/crates/shadow-compositor/src/main.rs"
        "ui/crates/shadow-compositor-common/src/lib.rs"
        "ui/crates/shadow-compositor-guest/src/main.rs"
        "ui/crates/shadow-ui-software/src/lib.rs"
      ];
      shadowUiRustWorkspaceManifestPrefixes = [
        "rust/Cargo.toml"
        "rust/shadow-sdk/Cargo.toml"
        "rust/shadow-system/Cargo.toml"
      ];
      shadowUiRustWorkspaceTargetPrefixes = [
        "rust/shadow-sdk/src/lib.rs"
        "rust/shadow-system/src/main.rs"
      ];
      shadowUiCoreSrc = repoSourceFromPrefixes (
        [
          "ui/Cargo.toml"
          "ui/Cargo.lock"
        ]
        ++ shadowUiWorkspaceMemberCargoTomlPrefixes
        ++ shadowUiWorkspaceMemberTargetPrefixes
        ++ shadowUiRustWorkspaceManifestPrefixes
        ++ shadowUiRustWorkspaceTargetPrefixes
        ++ [
          "ui/crates/shadow-ui-core"
          "ui/third_party"
          "rust/vendor/xilem"
          "rust/shadow-runtime-protocol"
        ]
      );
      shadowCompositorSrc = repoSourceFromPrefixes (
        [
          "ui/Cargo.toml"
          "ui/Cargo.lock"
        ]
        ++ shadowUiWorkspaceMemberCargoTomlPrefixes
        ++ shadowUiWorkspaceMemberTargetPrefixes
        ++ shadowUiRustWorkspaceManifestPrefixes
        ++ shadowUiRustWorkspaceTargetPrefixes
        ++ [
          "ui/crates/shadow-ui-core"
          "ui/crates/shadow-ui-software"
          "ui/crates/shadow-compositor-common"
          "ui/crates/shadow-compositor"
          "ui/third_party"
          "rust/vendor/xilem"
          "rust/shadow-runtime-protocol"
        ]
      );
      shadowCompositorGuestSrc = repoSourceFromPrefixes (
        [
          "ui/Cargo.toml"
          "ui/Cargo.lock"
        ]
        ++ shadowUiWorkspaceMemberCargoTomlPrefixes
        ++ shadowUiWorkspaceMemberTargetPrefixes
        ++ shadowUiRustWorkspaceManifestPrefixes
        ++ shadowUiRustWorkspaceTargetPrefixes
        ++ [
          "ui/apps/shadow-blitz-demo"
          "ui/crates/shadow-ui-core"
          "ui/crates/shadow-ui-software"
          "ui/crates/shadow-compositor-common"
          "ui/crates/shadow-compositor-guest"
          "ui/third_party"
          "rust/vendor/xilem"
          "rust/shadow-runtime-protocol"
        ]
      );
      shadowVmAppBinaryNames =
        let
          manifest = builtins.fromJSON (builtins.readFile appManifestPath);
          vmApps = builtins.filter (
            app:
            let
              profiles = app.profiles or [ ];
            in
              builtins.elem "vm-shell" profiles
          ) (manifest.apps or [ ]);
          binaryNames = builtins.map (app: app.binaryName or "") vmApps;
        in
          lib.unique (builtins.filter (name: name != "") binaryNames);
      shadowLinuxAudioSpikeSrc = repoSourceFromPrefixes [
        "rust/shadow-linux-audio-spike"
      ];
      shadowBlitzDemoSrc = repoSourceFromPrefixes (
        [
          "ui/Cargo.toml"
          "ui/Cargo.lock"
        ]
        ++ shadowUiWorkspaceMemberCargoTomlPrefixes
        ++ shadowUiWorkspaceMemberTargetPrefixes
        ++ shadowUiRustWorkspaceManifestPrefixes
        ++ shadowUiRustWorkspaceTargetPrefixes
        ++ [
          "ui/apps/shadow-blitz-demo"
          "ui/crates/shadow-ui-core"
          "ui/third_party"
          "rust/vendor/xilem"
          "rust/shadow-runtime-protocol"
        ]
      );
      shadowUiAppsSrc = repoSourceFromPrefixes (
        [
          "ui/Cargo.toml"
          "ui/Cargo.lock"
        ]
        ++ shadowUiWorkspaceMemberCargoTomlPrefixes
        ++ shadowUiWorkspaceMemberTargetPrefixes
        ++ shadowUiRustWorkspaceManifestPrefixes
        ++ shadowUiRustWorkspaceTargetPrefixes
        ++ [
          "ui/apps/shadow-rust-demo"
          "ui/apps/shadow-rust-timeline"
          "ui/crates/shadow-ui-core"
          "ui/third_party"
          "rust/shadow-sdk"
          "rust/shadow-runtime-protocol"
          "rust/vendor/temporal_rs"
          "rust/vendor/xilem"
        ]
      );
      shadowUiFmtSrc = repoSourceFromPrefixes [
        "ui/Cargo.toml"
        "ui/apps"
        "ui/crates"
        "ui/third_party"
        "rust/Cargo.toml"
        "rust/shadow-sdk"
        "rust/shadow-system"
        "rust/shadow-runtime-protocol"
        "rust/vendor/temporal_rs"
        "rust/vendor/xilem"
      ];
      shadowVmSmokeControllerPrefixes = [
        "scripts/ci/required_vm_smoke.sh"
        "scripts/ci/ui_vm_smoke.sh"
        "scripts/lib/ci_vm_smoke_common.sh"
        "scripts/lib/session_apps.sh"
        "scripts/lib/shadow_common.sh"
        "scripts/lib/ui_vm_common.sh"
        "scripts/shadowctl"
        "scripts/vm/ui_vm_run.sh"
        "scripts/vm/ui_vm_stop.sh"
      ];
      shadowVmSmokeRuntimeBuilderPrefixes = [
        "deno.json"
        "deno.lock"
        "flake.nix"
        "flake.lock"
        "justfile"
        "patches"
        "runtime"
        "scripts"
        "vm"
        "rust/Cargo.toml"
        "rust/Cargo.lock"
        "rust/shadow-sdk"
        "rust/shadow-system"
        "rust/shadow-runtime-protocol"
        "rust/vendor/temporal_rs"
        "rust/vendor/xilem"
        "ui/Cargo.toml"
        "ui/Cargo.lock"
        "ui/apps"
        "ui/crates"
        "ui/third_party"
      ];
      shadowVmSmokeSrc = repoSourceFromPrefixes (
        shadowVmSmokeControllerPrefixes
        ++ shadowVmSmokeRuntimeBuilderPrefixes
      );
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
        cargoTomlPath: membersOrSpec:
        let
          workspaceSpec =
            if builtins.isList membersOrSpec then
              {
                members = membersOrSpec;
                defaultMembers = membersOrSpec;
              }
            else
              membersOrSpec;
          members = workspaceSpec.members;
          defaultMembers = workspaceSpec.defaultMembers;
          memberLines = lib.concatMapStringsSep "" (member: "    \"${member}\",\n") members;
          replacement = "members = [\n${memberLines}]";
          defaultMemberLines =
            if defaultMembers == null then
              null
            else
              lib.concatMapStringsSep "" (member: "    \"${member}\",\n") defaultMembers;
          defaultReplacement =
            if defaultMembers == null then
              null
            else
              "default-members = [\n${defaultMemberLines}]";
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
            ${
              lib.optionalString (defaultMembers != null) ''
                data = re.sub(
                    r"default-members = \[\n(?:    \".*\",\n)+\]",
                    ${builtins.toJSON defaultReplacement},
                    data,
                    count=1,
                )
              ''
            }
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
      mkDrvPathManifestEntry = attr: drv: {
        inherit attr;
        drvPath = drv.drvPath;
      };
      mkDrvPathManifestCheck = pkgs: name: payload:
        pkgs.writeText name (builtins.unsafeDiscardStringContext (builtins.toJSON payload));
      mkRustyV8ArchiveFor = cross:
        cross.fetchurl {
          name = "librusty_v8-${rustyV8ReleaseVersion}";
          url = "https://github.com/denoland/rusty_v8/releases/download/v${rustyV8ReleaseVersion}/librusty_v8_release_${cross.stdenv.hostPlatform.rust.rustcTarget}.a.gz";
          sha256 = rustyV8ReleaseShas.${cross.stdenv.hostPlatform.system};
          meta.sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
        };
      mkInitWrapperFor = cross: { mode ? "standard" }:
        assert lib.elem mode [ "standard" "minimal" ];
        cross.rustPlatform.buildRustPackage {
          pname = "init-wrapper" + lib.optionalString (mode != "standard") "-${mode}";
          version = "0.1.0";
          src = ./rust/init-wrapper;
          cargoLock.lockFile = ./rust/init-wrapper/Cargo.lock;
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = cross.stdenv.hostPlatform.config;
          SHADOW_INIT_WRAPPER_MODE = mode;
          RUSTFLAGS = lib.optionalString cross.stdenv.hostPlatform.isMusl "-C target-feature=+crt-static";
        };
      mkInitWrapperCFor = cross: {
        presentedPath ? "/init",
        stockInitPath ? "/init.stock",
        packageSuffix ? "",
      }:
        let
          wrapperSource = builtins.path {
            path = ./scripts/pixel/pixel_init_wrapper_handoff.c;
            name = "pixel-init-wrapper-handoff.c";
          };
          wrapperDefines = [
            ''-DSHADOW_INIT_WRAPPER_PRESENTED_PATH="${presentedPath}"''
            ''-DSHADOW_INIT_WRAPPER_STOCK_INIT_PATH="${stockInitPath}"''
          ];
        in cross.stdenv.mkDerivation {
          pname = "init-wrapper-c" + lib.optionalString (packageSuffix != "") "-${packageSuffix}";
          version = "0.1.0";
          dontUnpack = true;
          dontConfigure = true;
          doCheck = false;
          strictDeps = true;
          buildPhase = ''
            runHook preBuild
            $CC -static -Os -s -std=c11 -Wall -Wextra -Werror \
              ${lib.concatMapStringsSep " " lib.escapeShellArg wrapperDefines} \
              ${wrapperSource} \
              -o init-wrapper
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp init-wrapper $out/bin/init-wrapper
            runHook postInstall
          '';
        };
      mkHelloInitFor = cross:
        let
          initSource = builtins.path {
            path = ./scripts/pixel/pixel_hello_init.c;
            name = "pixel-hello-init.c";
          };
        in
        cross.stdenv.mkDerivation {
          pname = "hello-init";
          version = "0.1.0";
          dontUnpack = true;
          dontConfigure = true;
          doCheck = false;
          strictDeps = true;
          buildPhase = ''
            runHook preBuild
            $CC -static -Os -s -std=c11 -Wall -Wextra -Werror \
              ${initSource} \
              -o hello-init
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp hello-init $out/bin/hello-init
            runHook postInstall
          '';
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
            "apps/shadow-blitz-demo"
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
      mkShadowGpuSmokeFor = cross:
        cross.rustPlatform.buildRustPackage {
          pname = "shadow-gpu-smoke";
          version = "0.1.0";
          src = shadowUiSrc;
          cargoRoot = "ui";
          buildAndTestSubdir = "ui";
          cargoLock = {
            lockFile = ./ui/Cargo.lock;
            outputHashes = uiBlitzOutputHashes;
          };
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = cross.stdenv.hostPlatform.config;
          cargoBuildFlags = [ "-p" "shadow-gpu-smoke" ];
          cargoInstallFlags = [ "-p" "shadow-gpu-smoke" ];
          postPatch = mkUiWorkspaceMembersPostPatch "ui/Cargo.toml" [
            "crates/shadow-gpu-smoke"
          ];
          nativeBuildInputs = [
            cross.buildPackages.pkg-config
            cross.buildPackages.python3
          ];
          depsBuildBuild =
            lib.optionals cross.stdenv.buildPlatform.isDarwin [
              cross.buildPackages.stdenv.cc
              cross.buildPackages.libiconv
            ];
          buildInputs = lib.optionals cross.stdenv.hostPlatform.isLinux [
            cross.libdrm
            cross.mesa
            cross.vulkan-loader
          ];
          postInstall = lib.optionalString cross.stdenv.hostPlatform.isLinux ''
            mkdir -p "$out/runtime-libs"
            ln -s "${cross.libdrm}" "$out/runtime-libs/libdrm"
            ln -s "${cross.mesa}" "$out/runtime-libs/mesa-drivers"
            ln -s "${cross.vulkan-loader}" "$out/runtime-libs/vulkan-loader"
            if [ -d "${cross.mesa}/share/vulkan/icd.d" ]; then
              mkdir -p "$out/share/vulkan"
              ln -s "${cross.mesa}/share/vulkan/icd.d" "$out/share/vulkan/icd.d"
            fi
          '';
          meta.mainProgram = "shadow-gpu-smoke";
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
      mkShadowRustUiAppFor =
        cross:
        pname:
        appPath:
        cross.rustPlatform.buildRustPackage {
          inherit pname;
          version = "0.1.0";
          src = shadowUiSrc;
          cargoRoot = "ui";
          buildAndTestSubdir = "ui";
          cargoLock = {
            lockFile = ./ui/Cargo.lock;
            outputHashes = uiBlitzOutputHashes;
          };
          doCheck = false;
          strictDeps = true;
          CARGO_BUILD_TARGET = cross.stdenv.hostPlatform.config;
          cargoBuildFlags = [ "-p" pname ];
          cargoInstallFlags = [ "-p" pname ];
          nativeBuildInputs = [
            cross.buildPackages.pkg-config
            cross.buildPackages.python3
          ];
          postPatch = mkUiWorkspaceMembersPostPatch "ui/Cargo.toml" [
            "crates/shadow-ui-core"
            appPath
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
          meta.mainProgram = pname;
        };
      mkShadowRustDemoFor = cross:
        mkShadowRustUiAppFor cross "shadow-rust-demo" "apps/shadow-rust-demo";
      mkShadowRustTimelineFor = cross:
        mkShadowRustUiAppFor cross "shadow-rust-timeline" "apps/shadow-rust-timeline";
      mkShadowUiVmSessionPackage =
        pkgs:
        {
          shadowCompositorPackage,
          appPackagesByBinaryName,
          requiredBinaryNames,
        }:
        let
          missingBinaryNames = builtins.filter (
            name: !(builtins.hasAttr name appPackagesByBinaryName)
          ) requiredBinaryNames;
          copyAppBinaries = lib.concatMapStringsSep "\n" (
            name:
            let
              package = appPackagesByBinaryName.${name};
            in
              ''
                cp -fL ${package}/bin/${name} "$out/bin/${name}"
                chmod 0555 "$out/bin/${name}"
              ''
          ) requiredBinaryNames;
        in
          if missingBinaryNames != [ ] then
            throw "shadow-ui-vm-session missing packages for VM app binaries: ${lib.concatStringsSep ", " missingBinaryNames}"
          else
            pkgs.runCommand "shadow-ui-vm-session" { } ''
              mkdir -p "$out/bin"
              cp -fL ${shadowCompositorPackage}/bin/shadow-compositor "$out/bin/shadow-compositor"
              chmod 0555 "$out/bin/shadow-compositor"
              ${copyAppBinaries}
            '';
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
      mkShadowSystemFor = cross:
        let
          craneLib = crane.mkLib cross;
          commonArgs = {
            pname = "shadow-system";
            version = "0.1.0";
            src = shadowSystemSrc;
            cargoLock = ./rust/Cargo.lock;
            cargoToml = ./rust/Cargo.toml;
            cargoExtraArgs = "--locked -p shadow-system";
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
            pname = "shadow-system-deps";
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
          meta.mainProgram = "shadow-system";
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
          mkUiCheckFamily =
            {
              pname,
              src,
              workspaceMembers ? null,
              artifactCargoExtraArgs ? "",
              useDummySrc ? true,
            }:
            let
              # Narrowed workspaces need to refresh Cargo.lock offline after trimming members.
              leafCargoExtraArgs =
                if workspaceMembers != null then
                  "--offline"
                else
                  "--locked";
              artifactLockedCargoExtraArgs =
                lib.concatStringsSep " " (
                  [ "--locked" ]
                  ++ lib.optionals (artifactCargoExtraArgs != "") [ artifactCargoExtraArgs ]
                );
              artifactBuildCargoExtraArgs =
                lib.concatStringsSep " " (
                  [
                    (
                      if workspaceMembers != null then
                        "--offline"
                      else
                        "--locked"
                    )
                  ]
                  ++ lib.optionals (artifactCargoExtraArgs != "") [ artifactCargoExtraArgs ]
                );
              commonArgs = {
                inherit pname src;
                version = "0.1.0";
                cargoLock = ./ui/Cargo.lock;
                cargoToml = ./ui/Cargo.toml;
                outputHashes = uiCraneOutputHashes;
                cargoExtraArgs = leafCargoExtraArgs;
                doCheck = false;
                strictDeps = true;
                CARGO_PROFILE = "";
                postUnpack = ''
                  cd "$sourceRoot/ui"
                  sourceRoot="."
                '';
                nativeBuildInputs = uiCheckNativeBuildInputsFor pkgs;
                buildInputs = uiCheckRuntimeLibsFor pkgs;
              }
              // lib.optionalAttrs (workspaceMembers != null) {
                postPatch = mkUiWorkspaceMembersPostPatch "Cargo.toml" workspaceMembers;
              };
              artifactBaseArgs = builtins.removeAttrs commonArgs [ "cargoExtraArgs" ];
              artifactVendorArgs = artifactBaseArgs // {
                cargoExtraArgs = artifactLockedCargoExtraArgs;
              };
              artifactBuildArgs = artifactBaseArgs // {
                cargoExtraArgs = artifactBuildCargoExtraArgs;
              };
              cargoVendorDir = craneLib.vendorCargoDeps artifactVendorArgs;
              cargoArgs = commonArgs // { inherit cargoVendorDir; };
              cargoArtifacts = craneLib.buildDepsOnly (
                if useDummySrc then
                  ((builtins.removeAttrs (artifactBuildArgs // {
                    inherit cargoVendorDir;
                  }) [ "src" ]) // {
                    pname = "${pname}-deps";
                    dummySrc = craneLib.mkDummySrc artifactBuildArgs;
                  })
                else
                  ((builtins.removeAttrs (artifactBuildArgs // {
                    inherit cargoVendorDir;
                    pname = "${pname}-deps";
                  }) [ "src" ]) // {
                    dummySrc = artifactBuildArgs.src;
                  })
              );
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
                    "cargo check ${leafCargoExtraArgs} ${cargoCheckExtraArgs}";
                  checkPhaseCargoCommand = "";
                  installPhaseCommand = "mkdir -p $out";
                });
            in
              {
                inherit mkUiCargoCheck mkUiTestArgs;
              };
          broadUiCheckFamily = mkUiCheckFamily {
            pname = "shadow-ui-workspace";
            src = shadowUiSrc;
          };
          shadowUiCoreCheckFamily = mkUiCheckFamily {
            pname = "shadow-ui-core-workspace";
            src = shadowUiCoreSrc;
            workspaceMembers = [
              "crates/shadow-ui-core"
            ];
            artifactCargoExtraArgs = "-p shadow-ui-core";
          };
          shadowBlitzDemoCpuCheckFamily = mkUiCheckFamily {
            pname = "shadow-ui-blitz-demo-cpu-workspace";
            src = shadowBlitzDemoSrc;
            workspaceMembers = [
              "crates/shadow-ui-core"
              "apps/shadow-blitz-demo"
            ];
            artifactCargoExtraArgs = "-p shadow-blitz-demo --no-default-features --features cpu";
            useDummySrc = false;
          };
          shadowBlitzDemoGpuCheckFamily = mkUiCheckFamily {
            pname = "shadow-ui-blitz-demo-gpu-workspace";
            src = shadowBlitzDemoSrc;
            workspaceMembers = [
              "crates/shadow-ui-core"
              "apps/shadow-blitz-demo"
            ];
            artifactCargoExtraArgs = "-p shadow-blitz-demo --no-default-features --features gpu";
            useDummySrc = false;
          };
          shadowCompositorCheckFamily = mkUiCheckFamily {
            pname = "shadow-ui-compositor-workspace";
            src = shadowCompositorSrc;
            workspaceMembers = [
              "crates/shadow-ui-core"
              "crates/shadow-ui-software"
              "crates/shadow-compositor-common"
              "crates/shadow-compositor"
            ];
            artifactCargoExtraArgs = "-p shadow-compositor";
            useDummySrc = false;
          };
          shadowCompositorGuestCheckFamily = mkUiCheckFamily {
            pname = "shadow-ui-compositor-guest-workspace";
            src = shadowCompositorGuestSrc;
            workspaceMembers = [
              "apps/shadow-blitz-demo"
              "crates/shadow-ui-core"
              "crates/shadow-ui-software"
              "crates/shadow-compositor-common"
              "crates/shadow-compositor-guest"
            ];
            artifactCargoExtraArgs = "-p shadow-compositor-guest";
            useDummySrc = false;
          };
          shadowAppsCheckFamily = mkUiCheckFamily {
            pname = "shadow-ui-apps-workspace";
            src = shadowUiAppsSrc;
            workspaceMembers = [
              "crates/shadow-ui-core"
              "apps/shadow-rust-demo"
              "apps/shadow-rust-timeline"
            ];
            useDummySrc = false;
          };
          shadowGpuSmokeCheckFamily = mkUiCheckFamily {
            pname = "shadow-ui-gpu-smoke-workspace";
            src = shadowUiSrc;
            workspaceMembers = [
              "crates/shadow-gpu-smoke"
            ];
            artifactCargoExtraArgs = "-p shadow-gpu-smoke";
            useDummySrc = false;
          };
          leafChecks =
            {
              uiFmt = craneLib.cargoFmt {
                pname = "shadow-ui-workspace";
                version = "0.1.0";
                src = shadowUiFmtSrc;
                cargoToml = ./ui/Cargo.toml;
                cargoExtraArgs = "--all";
                postUnpack = ''
                  cd "$sourceRoot/ui"
                  sourceRoot="."
                '';
              };
              uiShadowUiCoreTests = craneLib.cargoTest (shadowUiCoreCheckFamily.mkUiTestArgs {
                pname = "shadow-ui-core";
              } // {
                cargoTestExtraArgs = "-p shadow-ui-core";
              });
              uiShadowBlitzDemoAppTests = craneLib.cargoTest (shadowBlitzDemoCpuCheckFamily.mkUiTestArgs {
                pname = "shadow-blitz-demo-app-tests";
              } // {
                cargoTestExtraArgs =
                  "-p shadow-blitz-demo --no-default-features --features cpu app::tests::";
              });
              uiShadowBlitzDemoRuntimeDocumentTests = craneLib.cargoTest (shadowBlitzDemoCpuCheckFamily.mkUiTestArgs {
                pname = "shadow-blitz-demo-runtime-document-tests";
              } // {
                cargoTestExtraArgs =
                  "-p shadow-blitz-demo --no-default-features --features cpu runtime_document";
              });
              uiShadowCompositorGuestTests = craneLib.cargoTest (shadowCompositorGuestCheckFamily.mkUiTestArgs {
                pname = "shadow-compositor-guest-tests";
              } // {
                cargoTestExtraArgs = "-p shadow-compositor-guest";
              });
              uiShadowRustDemoCheck = shadowAppsCheckFamily.mkUiCargoCheck {
                pname = "shadow-rust-demo-check";
                cargoCheckExtraArgs = "-p shadow-rust-demo";
              };
              uiShadowRustTimelineCheck = shadowAppsCheckFamily.mkUiCargoCheck {
                pname = "shadow-rust-timeline-check";
                cargoCheckExtraArgs = "-p shadow-rust-timeline";
              };
              uiShadowBlitzDemoHostSystemFontsCheck = shadowBlitzDemoCpuCheckFamily.mkUiCargoCheck {
                pname = "shadow-blitz-demo-host-system-fonts-check";
                cargoCheckExtraArgs =
                  "-p shadow-blitz-demo --no-default-features --features cpu,host_system_fonts";
              };
              uiShadowBlitzDemoGpuCheck = shadowBlitzDemoGpuCheckFamily.mkUiCargoCheck {
                pname = "shadow-blitz-demo-gpu-check";
                cargoCheckExtraArgs =
                  "-p shadow-blitz-demo --no-default-features --features gpu";
              };
              uiShadowGpuSmokeCheck = shadowGpuSmokeCheckFamily.mkUiCargoCheck {
                pname = "shadow-gpu-smoke-check";
                cargoCheckExtraArgs = "-p shadow-gpu-smoke";
              };
              uiShadowGpuSmokePackageCheck = mkShadowGpuSmokeFor pkgs;
            }
            // lib.optionalAttrs pkgs.stdenv.isLinux {
              uiShadowCompositorTests = craneLib.cargoTest (shadowCompositorCheckFamily.mkUiTestArgs {
                pname = "shadow-compositor-tests";
              } // {
                cargoTestExtraArgs = "-p shadow-compositor";
              });
              uiShadowCompositorCheck = shadowCompositorCheckFamily.mkUiCargoCheck {
                pname = "shadow-compositor-check";
                cargoCheckExtraArgs = "-p shadow-compositor";
              };
              uiShadowCompositorGuestCheck = shadowCompositorGuestCheckFamily.mkUiCargoCheck {
                pname = "shadow-compositor-guest-check";
                cargoCheckExtraArgs = "-p shadow-compositor-guest";
              };
            };
          fmtSuiteMembers = [ "uiFmt" ];
          coreSuiteMembers = [ "uiShadowUiCoreTests" ];
          appsSuiteMembers = [
            "uiShadowRustDemoCheck"
            "uiShadowRustTimelineCheck"
          ];
          blitzDemoSuiteMembers = [
            "uiShadowBlitzDemoAppTests"
            "uiShadowBlitzDemoRuntimeDocumentTests"
            "uiShadowBlitzDemoHostSystemFontsCheck"
            "uiShadowBlitzDemoGpuCheck"
          ];
          compositorSuiteMembers =
            [ "uiShadowCompositorGuestTests" ]
            ++ lib.optionals pkgs.stdenv.isLinux [
              "uiShadowCompositorTests"
              "uiShadowCompositorCheck"
              "uiShadowCompositorGuestCheck"
            ];
          allSuiteMembers =
            fmtSuiteMembers
            ++ coreSuiteMembers
            ++ appsSuiteMembers
            ++ blitzDemoSuiteMembers
            ++ compositorSuiteMembers;
          mkUiCheckSuite = suiteName: members:
            pkgs.linkFarm suiteName (
              builtins.map (name: { inherit name; path = leafChecks.${name}; }) members
            );
        in
          leafChecks
          // {
            uiCheckFmt = mkUiCheckSuite "shadow-ui-check-fmt" fmtSuiteMembers;
            uiCheckCore = mkUiCheckSuite "shadow-ui-check-core" coreSuiteMembers;
            uiCheckApps = mkUiCheckSuite "shadow-ui-check-apps" appsSuiteMembers;
            uiCheckBlitzDemo = mkUiCheckSuite "shadow-ui-check-blitz-demo" blitzDemoSuiteMembers;
            uiCheckCompositor = mkUiCheckSuite "shadow-ui-check-compositor" compositorSuiteMembers;
            uiCheck = mkUiCheckSuite "shadow-ui-check" allSuiteMembers;
          };
      mkInitWrapperCheckFor = pkgs:
        let
          craneLib = crane.mkLib pkgs;
          initWrapperCommonArgs = {
            pname = "shadow-init-wrapper";
            version = "0.1.0";
            src = shadowInitWrapperSrc;
            cargoLock = ./rust/init-wrapper/Cargo.lock;
            cargoToml = ./rust/init-wrapper/Cargo.toml;
            cargoExtraArgs = "--locked";
            doCheck = false;
            strictDeps = true;
            postUnpack = ''
              cd "$sourceRoot/rust/init-wrapper"
              sourceRoot="."
            '';
          };
          initWrapperCargoVendorDir = craneLib.vendorCargoDeps initWrapperCommonArgs;
          initWrapperCargoArgs = initWrapperCommonArgs // {
            cargoVendorDir = initWrapperCargoVendorDir;
          };
          initWrapperCargoArtifacts = craneLib.buildDepsOnly ((builtins.removeAttrs initWrapperCargoArgs [ "src" ]) // {
            pname = "shadow-init-wrapper-deps";
            dummySrc = craneLib.mkDummySrc initWrapperCommonArgs;
          });
        in
          craneLib.mkCargoDerivation (initWrapperCargoArgs // {
            pname = "shadow-init-wrapper-check";
            cargoArtifacts = initWrapperCargoArtifacts;
            doInstallCargoArtifacts = false;
            buildPhaseCargoCommand = "cargo check --locked";
            checkPhaseCargoCommand = "";
            installPhaseCommand = "mkdir -p $out";
          });
      mkShadowRuntimeChecksFor = pkgs:
        let
          craneLib = crane.mkLib pkgs;
          runtimeRustCommonArgs = {
            pname = "shadow-runtime-workspace";
            version = "0.1.0";
            src = shadowSystemSrc;
            cargoLock = ./rust/Cargo.lock;
            cargoToml = ./rust/Cargo.toml;
            cargoExtraArgs = "--locked";
            doCheck = false;
            strictDeps = true;
            postUnpack = ''
              cd "$sourceRoot/rust"
              sourceRoot="."
            '';
            nativeBuildInputs = [ pkgs.pkg-config ];
            depsBuildBuild =
              lib.optionals pkgs.stdenv.buildPlatform.isDarwin [
                pkgs.stdenv.cc
                pkgs.libiconv
              ];
            RUSTY_V8_ARCHIVE = mkRustyV8ArchiveFor pkgs;
          };
          runtimeRustCargoVendorDir = craneLib.vendorCargoDeps runtimeRustCommonArgs;
          runtimeRustCargoArgs = runtimeRustCommonArgs // {
            cargoVendorDir = runtimeRustCargoVendorDir;
          };
          runtimeRustCargoArtifacts = craneLib.buildDepsOnly ((builtins.removeAttrs runtimeRustCargoArgs [ "src" ]) // {
            pname = "shadow-runtime-workspace-deps";
            dummySrc = craneLib.mkDummySrc (runtimeRustCommonArgs // {
              extraDummyScript = ''
                rm -rf "$out/rust/vendor/temporal_rs"
                mkdir -p "$out/rust/vendor"
                cp --recursive --no-preserve=ownership ${./rust/vendor/temporal_rs} "$out/rust/vendor/temporal_rs"
                chmod +w -R "$out/rust/vendor/temporal_rs"
              '';
            });
          });
          mkRuntimeRustTestArgs =
            {
              pname,
            }:
            runtimeRustCargoArgs
            // {
              inherit pname;
              cargoArtifacts = runtimeRustCargoArtifacts;
              doCheck = true;
              doInstallCargoArtifacts = false;
              installPhaseCommand = "mkdir -p $out";
            };
          runtimeBundleDenoCache = pkgs.stdenvNoCC.mkDerivation {
            pname = "shadow-runtime-bundle-test-deno-cache";
            version = "0.1.0";
            src = shadowRuntimeBundleTestSrc;
            nativeBuildInputs = [ pkgs.deno ];
            dontUnpack = true;
            phases = [ "buildPhase" ];
            outputHashMode = "recursive";
            outputHashAlgo = "sha256";
            outputHash = "sha256-iXh8mICg/xokpFNQQCgRC0DNUNf8AAFqnlSTNckJ0E8=";
            buildPhase = ''
              export HOME="$TMPDIR/home"
              export DENO_DIR="$TMPDIR/deno-dir"
              mkdir -p "$HOME" "$DENO_DIR"
              cp -R "$src" source
              chmod -R u+w source
              cd source
              deno test \
                --lock=deno.lock \
                --allow-read \
                --allow-write \
                --allow-run \
                --allow-env \
                scripts/runtime/runtime_prepare_app_bundle_test.ts
              mkdir -p "$out/deno-dir"
              cp -R "$DENO_DIR"/. "$out/deno-dir"/
              if [ -d node_modules ]; then
                cp -R node_modules "$out/node_modules"
              fi
            '';
          };
          leafChecks = {
            runtimeShadowSdkNostrTests = craneLib.cargoTest (mkRuntimeRustTestArgs {
              pname = "shadow-sdk-nostr-tests";
            } // {
              cargoTestExtraArgs = "-p shadow-sdk --features nostr";
            });
            runtimeShadowSystemTests = craneLib.cargoTest (mkRuntimeRustTestArgs {
              pname = "shadow-system-tests";
            } // {
              cargoTestExtraArgs = "-p shadow-system";
            });
            runtimePrepareAppBundleTests = pkgs.runCommand "shadow-runtime-prepare-app-bundle-tests" {
              nativeBuildInputs = [ pkgs.deno ];
            } ''
              export HOME="$TMPDIR/home"
              export DENO_DIR="$TMPDIR/deno-dir"
              mkdir -p "$HOME" "$DENO_DIR"
              cp -R ${shadowRuntimeBundleTestSrc} source
              chmod -R u+w source
              cp -R ${runtimeBundleDenoCache}/deno-dir/. "$DENO_DIR"/
              chmod -R u+w "$DENO_DIR"
              if [ -d ${runtimeBundleDenoCache}/node_modules ]; then
                cp -R ${runtimeBundleDenoCache}/node_modules source/node_modules
                chmod -R u+w source/node_modules
              fi
              cd source
              deno test \
                --lock=deno.lock \
                --cached-only \
                --allow-read \
                --allow-write \
                --allow-run \
                --allow-env \
                scripts/runtime/runtime_prepare_app_bundle_test.ts
              mkdir -p "$out"
            '';
          };
        in
          leafChecks
          // {
            runtimeCheck = pkgs.linkFarm "shadow-runtime-check" (
              lib.mapAttrsToList (name: path: { inherit name path; }) leafChecks
            );
          };
      mkShadowPreMergeChecksFor = pkgs: uiChecks: runtimeChecks:
        let
          hostSystem = pkgs.stdenv.hostPlatform.system;
          systemPackageAttr = systemPackageAttrForHostSystem hostSystem;
          preMergeSurfaceCheck =
            mkDrvPathManifestCheck pkgs "shadow-pre-merge-surface-check.json" {
              schemaVersion = 1;
              hostSystem = hostSystem;
              entries =
                (builtins.map
                  (
                    shellName:
                    mkDrvPathManifestEntry
                      "devShells.${hostSystem}.${shellName}"
                      self.devShells.${hostSystem}.${shellName}
                  )
                  publicDevShellNames
                )
                ++ [
                  (mkDrvPathManifestEntry
                    "packages.${hostSystem}.${systemPackageAttr}"
                    self.packages.${hostSystem}.${systemPackageAttr})
                  (mkDrvPathManifestEntry
                    "packages.${hostSystem}.ui-vm-ci"
                    self.packages.${hostSystem}.ui-vm-ci)
                  (mkDrvPathManifestEntry
                    "packages.${hostSystem}.vm-smoke-inputs"
                    self.packages.${hostSystem}.vm-smoke-inputs)
                ];
            };
        in
          {
            inherit preMergeSurfaceCheck;
            preMergeCheck = pkgs.linkFarm "shadow-pre-merge-check" [
              {
                name = "pre-merge-surface-check.json";
                path = preMergeSurfaceCheck;
              }
              {
                name = "runtime-check";
                path = runtimeChecks.runtimeCheck;
              }
              {
                name = "ui-check-compositor";
                path = uiChecks.uiCheckCompositor;
              }
            ];
          };
      mkShadowNightlyChecksFor = pkgs:
        let
          pixelBootSmokeNativeBuildInputs = with pkgs; [
            bash
            coreutils
            file
            findutils
            gawk
            gnugrep
            gnused
            gzip
            lz4
            perl
            python3
          ];
          mkPixelBootSmokeCheck =
            {
              pname,
              script,
              src,
            }:
            pkgs.runCommand pname {
              nativeBuildInputs = pixelBootSmokeNativeBuildInputs;
            } ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME" "$TMPDIR/check-bin"
              printf '%s\n' \
                '#!/usr/bin/env bash' \
                'set -euo pipefail' \
                'if [ "$#" -gt 0 ] && [ "$1" = "-st" ]; then' \
                '  shift' \
                '  timeout="$1"' \
                '  shift' \
                '  lock_path="$1"' \
                '  shift' \
                '  exec "$@"' \
                'fi' \
                'lock_path="$1"' \
                'shift' \
                'exec "$@"' \
                >"$TMPDIR/check-bin/lockf"
              chmod 0755 "$TMPDIR/check-bin/lockf"
              export PATH="$TMPDIR/check-bin:$PATH"
              cp -R ${src} source
              chmod -R u+w source
              cd source
              bash ${script}
              mkdir -p "$out"
            '';
          leafChecks = {
            pixelBootInitWrapperCheck = mkInitWrapperCheckFor pkgs;
            pixelBootHelloInitSmoke = mkPixelBootSmokeCheck {
              pname = "shadow-pixel-boot-hello-init-smoke";
              script = "./scripts/ci/pixel_boot_hello_init_smoke.sh";
              src = shadowPixelBootHelloInitSmokeSrc;
            };
            pixelBootOrangeInitSmoke = mkPixelBootSmokeCheck {
              pname = "shadow-pixel-boot-orange-init-smoke";
              script = "./scripts/ci/pixel_boot_orange_init_smoke.sh";
              src = shadowPixelBootOrangeInitSmokeSrc;
            };
            pixelBootToolingSmoke = mkPixelBootSmokeCheck {
              pname = "shadow-pixel-boot-tooling-smoke";
              script = "./scripts/ci/pixel_boot_tooling_smoke.sh";
              src = shadowPixelBootToolingSmokeSrc;
            };
            pixelBootRecoverTracesSmoke = mkPixelBootSmokeCheck {
              pname = "shadow-pixel-boot-recover-traces-smoke";
              script = "./scripts/ci/pixel_boot_recover_traces_smoke.sh";
              src = shadowPixelBootRecoverTracesSmokeSrc;
            };
            pixelBootCollectLogsSmoke = mkPixelBootSmokeCheck {
              pname = "shadow-pixel-boot-collect-logs-smoke";
              script = "./scripts/ci/pixel_boot_collect_logs_smoke.sh";
              src = shadowPixelBootCollectLogsSmokeSrc;
            };
            pixelBootSafetySmoke = mkPixelBootSmokeCheck {
              pname = "shadow-pixel-boot-safety-smoke";
              script = "./scripts/ci/pixel_boot_safety_smoke.sh";
              src = shadowPixelBootSafetySmokeSrc;
            };
          };
        in
          leafChecks
          // {
            pixelBootCheck = pkgs.linkFarm "shadow-pixel-boot-check" (
              lib.mapAttrsToList (name: path: { inherit name path; }) leafChecks
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
            requiredBinaryNames = shadowVmAppBinaryNames;
            shadowUiVmSessionPackage = self.packages.${guestSystem}.shadow-ui-vm-session;
            sshPort = uiVmSshPort;
          };
      mkVmSmokeInputsFor = pkgs:
        let
          hostSystem = pkgs.stdenv.hostPlatform.system;
          systemPackageAttr = systemPackageAttrForHostSystem hostSystem;
          systemPackage = self.packages.${hostSystem}.${systemPackageAttr};
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
            ln -s ${systemPackage} "$out/system"
            ln -s ${uiVmRunnerPackage} "$out/ui-vm-runner"
            cat >"$out/metadata.json" <<EOF
            {
              "schemaVersion": 1,
              "sourceStorePath": "${shadowVmSmokeSrc}",
              "systemPackageAttr": "${systemPackageAttr}",
              "systemBinaryPath": "${systemPackage}/bin/shadow-system",
              "systemPackagePath": "${systemPackage}",
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
        let
          linuxShadowBlitzDemoHostSystemFonts = mkShadowBlitzDemoFor pkgs {
            features = [ "cpu" "host_system_fonts" ];
            pnameSuffix = "host-system-fonts";
            useDefaultFeatures = false;
          };
          linuxShadowCompositor = mkShadowCompositorFor pkgs;
          linuxShadowRustDemo = mkShadowRustDemoFor pkgs;
          linuxShadowRustTimeline = mkShadowRustTimelineFor pkgs;
          linuxShadowVmAppPackagesByBinaryName = {
            "shadow-blitz-demo" = linuxShadowBlitzDemoHostSystemFonts;
            "shadow-rust-demo" = linuxShadowRustDemo;
            "shadow-rust-timeline" = linuxShadowRustTimeline;
          };
          linuxShadowUiVmSession = mkShadowUiVmSessionPackage pkgs {
            shadowCompositorPackage = linuxShadowCompositor;
            appPackagesByBinaryName = linuxShadowVmAppPackagesByBinaryName;
            requiredBinaryNames = shadowVmAppBinaryNames;
          };
        in
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
          shadow-system = mkShadowSystemFor pkgs;
          shadow-system-aarch64-linux-gnu =
            mkShadowSystemFor pkgs.pkgsCross.aarch64-multiplatform;
          shadow-system-x86_64-linux-gnu =
            mkShadowSystemFor pkgs.pkgsCross.gnu64;
          shadow-gpu-smoke = mkShadowGpuSmokeFor pkgs;
          shadow-gpu-smoke-aarch64-linux-gnu =
            if pkgs.stdenv.isLinux then
              mkShadowGpuSmokeFor pkgs.pkgsCross.aarch64-multiplatform
            else
              mkUnavailablePackage pkgs "shadow-gpu-smoke-aarch64-linux-gnu-unavailable"
                "shadow-gpu-smoke-aarch64-linux-gnu is only exposed on Linux host package sets; use packages.aarch64-linux.* when building for Pixel bundles.";
          drm-rect = mkDrmRect pkgs;
          drm-rect-device = mkDrmRectFor pkgs.pkgsCross.aarch64-multiplatform-musl;
          init-wrapper-device = mkInitWrapperFor pkgs.pkgsCross.aarch64-multiplatform-musl { };
          init-wrapper-device-minimal = mkInitWrapperFor pkgs.pkgsCross.aarch64-multiplatform-musl {
            mode = "minimal";
          };
          init-wrapper-c-device = mkInitWrapperCFor pkgs.pkgsCross.aarch64-multiplatform-musl { };
          init-wrapper-c-device-system-init =
            mkInitWrapperCFor pkgs.pkgsCross.aarch64-multiplatform-musl {
              presentedPath = "/system/bin/init";
              stockInitPath = "/system/bin/init.stock";
              packageSuffix = "system-init";
            };
          hello-init-device = mkHelloInitFor pkgs.pkgsCross.aarch64-multiplatform-musl;
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
          shadow-compositor-guest-aarch64-linux-gnu =
            mkShadowGuestCompositorFor pkgs.pkgsCross.aarch64-multiplatform;
          shadow-blitz-demo-host-system-fonts = linuxShadowBlitzDemoHostSystemFonts;
          shadow-compositor = linuxShadowCompositor;
          shadow-ui-vm-session = linuxShadowUiVmSession;
          shadow-pinned-turnip-mesa-aarch64-linux =
            mkShadowPinnedTurnipMesaFor pkgs.pkgsCross.aarch64-multiplatform;
          shadow-local-turnip-mesa-aarch64-linux =
            mkShadowLocalTurnipMesaFor pkgs.pkgsCross.aarch64-multiplatform;
          shadow-compositor-guest = mkShadowGuestCompositor pkgs;
          shadow-compositor-guest-device =
            mkShadowGuestCompositorFor pkgs.pkgsCross.aarch64-multiplatform-musl;
          shadow-rust-demo = linuxShadowRustDemo;
          shadow-rust-timeline = linuxShadowRustTimeline;
        });
      legacyPackages = forAllSystems ({ pkgs, ... }:
        let
          hostSystem = pkgs.stdenv.hostPlatform.system;
          systemPackageAttr = systemPackageAttrForHostSystem hostSystem;
          nightlyCiChecks = mkShadowNightlyChecksFor pkgs;
        in
          {
            ci = {
              vmSystem = self.packages.${hostSystem}.${systemPackageAttr};
              vmUiRunner = self.packages.${hostSystem}.ui-vm-ci;
              vmSmokeInputs = mkVmSmokeInputsFor pkgs;
              pixelBootCheck = nightlyCiChecks.pixelBootCheck;
              pixelBootChecks = nightlyCiChecks;
            };
          });
      checks = forAllSystems ({ pkgs, ... }:
        let
          uiChecks = mkShadowUiChecksFor pkgs;
          runtimeChecks = mkShadowRuntimeChecksFor pkgs;
        in
          uiChecks
          // runtimeChecks
          // mkShadowPreMergeChecksFor pkgs uiChecks runtimeChecks
      );
    };
}
