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
    in {
      devShells = forAllSystems ({ pkgs }: {
        bootimg = mkBootimgShell pkgs;
        default = mkBootimgShell pkgs;
      });
      packages = forAllSystems ({ pkgs }: {
        init-wrapper = mkInitWrapper pkgs;
        default = mkInitWrapper pkgs;
      });
    };
}
