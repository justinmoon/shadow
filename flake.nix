{
  description = "Shadow boot bring-up tooling";

  nixConfig = {
    extra-substituters = [ "https://microvm.cachix.org" ];
    extra-trusted-public-keys = [ "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys=" ];
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
      uiVmNameEnv = builtins.getEnv "SHADOW_UI_VM_NAME";
      uiVmHostNameEnv = builtins.getEnv "SHADOW_UI_VM_HOSTNAME";
      uiVmSshPortEnv = builtins.getEnv "SHADOW_UI_VM_SSH_PORT";
      uiVmQmpSocketEnv = builtins.getEnv "SHADOW_UI_VM_QMP_SOCKET";
      uiVmMacAddressEnv = builtins.getEnv "SHADOW_UI_VM_MAC_ADDRESS";
      uiVmUuidEnv = builtins.getEnv "SHADOW_UI_VM_UUID";
      uiVmSource =
        if uiVmSourceEnv != "" then
          uiVmSourceEnv
        else
          throw "Set SHADOW_UI_VM_SOURCE and build with --impure before using the ui-vm package.";
      uiVmName =
        if uiVmNameEnv != "" then
          uiVmNameEnv
        else
          "shadow-ui-vm";
      uiVmHostName =
        if uiVmHostNameEnv != "" then
          uiVmHostNameEnv
        else
          uiVmName;
      uiVmSshPort =
        if uiVmSshPortEnv != "" then
          builtins.fromJSON uiVmSshPortEnv
        else
          2222;
      uiVmQmpSocket =
        if uiVmQmpSocketEnv != "" then
          uiVmQmpSocketEnv
        else
          ".shadow-vm/shadow-ui-vm.sock";
      uiVmMacAddress =
        if uiVmMacAddressEnv != "" then
          uiVmMacAddressEnv
        else
          "02:00:00:10:10:01";
      uiVmUuid =
        if uiVmUuidEnv != "" then
          uiVmUuidEnv
        else
          "";
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f:
        lib.genAttrs systems (system:
          f { pkgs = import nixpkgs { inherit system; }; });
      mkUnavailablePackage = pkgs: name: message:
        pkgs.writeShellScriptBin name ''
          echo ${builtins.toJSON message} >&2
          exit 1
        '';
      darwinSystems = builtins.filter (system: lib.hasSuffix "-darwin" system) systems;
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
            cargo
            clang
            clippy
            deno
            just
            pkg-config
            python3
            rustc
            rustfmt
          ];
          runtimeLibs = pkgs.lib.optionals pkgs.stdenv.isLinux (with pkgs; [
            bzip2
            expat
            fontconfig
            freetype
            libdrm
            libglvnd
            libpng
            libX11
            libXcursor
            libXi
            libXrandr
            libxkbcommon
            mesa
            vulkan-loader
            wayland
            wayland-protocols
            zlib
          ]);
          shellPkgs = toolPkgs ++ runtimeLibs;
          pkgConfigPath = pkgs.lib.concatStringsSep ":" [
            (pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" runtimeLibs)
            (pkgs.lib.makeSearchPathOutput "dev" "share/pkgconfig" runtimeLibs)
            (pkgs.lib.makeSearchPathOutput "out" "lib/pkgconfig" runtimeLibs)
            (pkgs.lib.makeSearchPathOutput "out" "share/pkgconfig" runtimeLibs)
          ];
          libraryPath = pkgs.lib.makeLibraryPath runtimeLibs;
          linkFlags = pkgs.lib.concatMapStringsSep " " (pkg: "-L${pkg}/lib") runtimeLibs;
        in pkgs.mkShell {
          packages = shellPkgs;

          shellHook = ''
            export PATH="${pkgs.lib.makeBinPath toolPkgs}:$PATH"
            export IN_NIX_SHELL=1
            export SHADOW_UI_SHELL=1
            export PKG_CONFIG_PATH="${pkgConfigPath}:''${PKG_CONFIG_PATH:-}"
            ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
              export LD_LIBRARY_PATH="${libraryPath}:''${LD_LIBRARY_PATH:-}"
              export LIBRARY_PATH="${libraryPath}:''${LIBRARY_PATH:-}"
              export NIX_LDFLAGS="${linkFlags} ''${NIX_LDFLAGS:-}"
            ''}
          '';
        };
    in {
      nixosConfigurations =
        lib.listToAttrs (map (hostSystem: {
          name = "${hostSystem}-${uiVmName}";
          value = import ./vm/shadow-ui-vm.nix {
            inherit hostSystem microvm nixpkgs;
            repoSource = uiVmSource;
            instanceName = uiVmName;
            hostName = uiVmHostName;
            sshPort = uiVmSshPort;
            qmpSocket = uiVmQmpSocket;
            macAddress = uiVmMacAddress;
            instanceUuid = uiVmUuid;
          };
        }) darwinSystems);
      devShells = forAllSystems ({ pkgs }: {
        bootimg = mkBootimgShell pkgs;
        ui = mkUiShell pkgs;
        # Keep the default on the boot flow to avoid changing the existing bring-up entrypoint.
        default = mkBootimgShell pkgs;
      });
      packages = forAllSystems ({ pkgs }: {
        init-wrapper = mkInitWrapper pkgs;
        ui-vm =
          if pkgs.stdenv.isDarwin then
            self.nixosConfigurations."${pkgs.stdenv.hostPlatform.system}-${uiVmName}".config.microvm.declaredRunner
          else
            mkUnavailablePackage pkgs "shadow-ui-vm-unavailable"
              "ui-vm is only available on macOS hosts. Use just ui-vm-run from an Apple Silicon or Intel Mac.";
        default = mkInitWrapper pkgs;
      });
    };
}
