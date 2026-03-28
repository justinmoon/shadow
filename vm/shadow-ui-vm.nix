{ hostSystem, microvm, nixpkgs, repoSource }:

let
  lib = nixpkgs.lib;
  guestSystem = builtins.replaceStrings [ "-darwin" ] [ "-linux" ] hostSystem;
in
nixpkgs.lib.nixosSystem {
  system = guestSystem;

  modules = [
    microvm.nixosModules.microvm
    ({ config, pkgs, ... }:
      let
        stateDir = "/var/lib/shadow-ui";
        repoDir = "/work/shadow";
        targetDir = "${stateDir}/target";
        homeDir = "${stateDir}/home";
        logDir = "${stateDir}/log";
        runtimeLibDir = "${stateDir}/runtime-libs";
        sessionLog = "${logDir}/shadow-ui-session.log";
        westonLog = "${logDir}/weston.log";
        westonConfig = "${stateDir}/weston.ini";
        sessionEnv = "${stateDir}/shadow-ui-session-env.sh";
        guestToolPkgs = with pkgs; [
          cargo
          clang
          deno
          epiphany
          git
          just
          pkg-config
          python3
          rustc
          weston
        ];
        guestRuntimeLibs = with pkgs; [
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
        ];
        guestPkgConfigPath = lib.concatStringsSep ":" [
          (lib.makeSearchPathOutput "dev" "lib/pkgconfig" guestRuntimeLibs)
          (lib.makeSearchPathOutput "dev" "share/pkgconfig" guestRuntimeLibs)
          (lib.makeSearchPathOutput "out" "lib/pkgconfig" guestRuntimeLibs)
          (lib.makeSearchPathOutput "out" "share/pkgconfig" guestRuntimeLibs)
        ];
        guestLibraryPath = lib.makeLibraryPath guestRuntimeLibs;
        guestLinkFlags = lib.concatMapStringsSep " " (pkg: "-L${pkg}/lib") guestRuntimeLibs;
        shadowUiSession = pkgs.writeShellApplication {
          name = "shadow-ui-session";
          runtimeInputs = with pkgs; [
            bash
            coreutils
          ] ++ guestToolPkgs ++ guestRuntimeLibs;
          text = ''
            set -euo pipefail

            export HOME=${homeDir}
            export XDG_CACHE_HOME="$HOME/.cache"
            export CARGO_TARGET_DIR=${targetDir}
            export PKG_CONFIG_PATH="${guestPkgConfigPath}:''${PKG_CONFIG_PATH:-}"
            export LD_LIBRARY_PATH="${runtimeLibDir}:${guestLibraryPath}:''${LD_LIBRARY_PATH:-}"
            export LIBRARY_PATH="${guestLibraryPath}:''${LIBRARY_PATH:-}"
            export NIX_LDFLAGS="${guestLinkFlags} ''${NIX_LDFLAGS:-}"
            export LIBGL_DRIVERS_PATH="${pkgs.mesa}/lib/dri:''${LIBGL_DRIVERS_PATH:-}"
            export RUST_BACKTRACE=1
            uid="$(id -u)"
            export XDG_RUNTIME_DIR="/run/user/$uid"
            export GDK_BACKEND=wayland

            mkdir -p "$HOME" "$XDG_CACHE_HOME" "$CARGO_TARGET_DIR" ${logDir} ${runtimeLibDir} "$XDG_RUNTIME_DIR"
            chmod 700 "$XDG_RUNTIME_DIR"
            # On the shared /nix/store mount under macOS/QEMU, libglvnd soname symlinks can
            # resolve poorly through the overlay. Stage concrete copies into writable state.
            cp -fL ${pkgs.libglvnd}/lib/libEGL.so.1 ${runtimeLibDir}/libEGL.so.1
            cp -fL ${pkgs.libglvnd}/lib/libGL.so.1 ${runtimeLibDir}/libGL.so.1
            cp -fL ${pkgs.libglvnd}/lib/libOpenGL.so.0 ${runtimeLibDir}/libOpenGL.so.0
            cp -fL ${pkgs.libglvnd}/lib/libGLESv2.so.2 ${runtimeLibDir}/libGLESv2.so.2
            cat >${sessionEnv} <<EOF
            export HOME="$HOME"
            export XDG_CACHE_HOME="$XDG_CACHE_HOME"
            export CARGO_TARGET_DIR="$CARGO_TARGET_DIR"
            export PKG_CONFIG_PATH="$PKG_CONFIG_PATH"
            export LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
            export LIBRARY_PATH="$LIBRARY_PATH"
            export NIX_LDFLAGS="$NIX_LDFLAGS"
            export LIBGL_DRIVERS_PATH="$LIBGL_DRIVERS_PATH"
            export RUST_BACKTRACE="$RUST_BACKTRACE"
            export XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
            export DBUS_SESSION_BUS_ADDRESS="''${DBUS_SESSION_BUS_ADDRESS:-}"
            export GDK_BACKEND="$GDK_BACKEND"
            EOF
            cd ${repoDir}
            : >${sessionLog}
            exec >>${sessionLog} 2>&1

            echo "== shadow-ui-session $(date --iso-8601=seconds) =="
            echo "cwd: $(pwd)"
            echo "WAYLAND_DISPLAY=''${WAYLAND_DISPLAY:-unset}"
            echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
            cat >${westonConfig} <<EOF
            [core]
            idle-time=0

            [output]
            name=Virtual-1
            transform=normal
            EOF

            ${pkgs.weston}/bin/weston \
              --backend=drm \
              --idle-time=0 \
              --socket=wayland-0 \
              --config=${westonConfig} \
              >${westonLog} 2>&1 &
            weston_pid=$!

            cleanup() {
              kill "$weston_pid" 2>/dev/null || true
              wait "$weston_pid" 2>/dev/null || true
            }
            trap cleanup EXIT

            for _ in $(seq 1 120); do
              if [[ -S "$XDG_RUNTIME_DIR/wayland-0" ]]; then
                export WAYLAND_DISPLAY=wayland-0
                break
              fi
              sleep 1
            done

            if [[ ! -S "$XDG_RUNTIME_DIR/wayland-0" ]]; then
              echo "shadow-ui-session: weston did not create wayland-0" >&2
              echo "shadow-ui-session: weston log:" >&2
              cat ${westonLog} >&2 || true
              exit 1
            fi

            cargo run --locked --manifest-path ui/Cargo.toml -p shadow-ui-desktop &
            shell_pid=$!
            shell_logged=0

            while kill -0 "$weston_pid" 2>/dev/null; do
              if [[ "$shell_logged" -eq 0 ]] && ! kill -0 "$shell_pid" 2>/dev/null; then
                wait "$shell_pid" || true
                echo "shadow-ui-session: shadow-ui-desktop exited"
                shell_logged=1
              fi
              sleep 1
            done

            wait "$weston_pid"
          '';
        };
        initialSession = {
          user = "shadow";
          command = "${pkgs.dbus}/bin/dbus-run-session ${shadowUiSession}/bin/shadow-ui-session";
        };
      in {
        networking.hostName = "shadow-ui-vm";
        system.stateVersion = lib.trivial.release;

        nix.settings.experimental-features = [ "nix-command" "flakes" ];

        hardware.graphics.enable = true;
        fonts = {
          fontDir.enable = true;
          fontconfig.enable = true;
          packages = with pkgs; [ dejavu_fonts ];
        };
        services.dbus.enable = true;
        services.openssh = {
          enable = true;
          settings = {
            PasswordAuthentication = false;
            PermitRootLogin = "no";
          };
        };
        services.greetd = {
          enable = true;
          restart = false;
          settings = {
            initial_session = initialSession;
            default_session = initialSession;
          };
        };

        users.users.shadow = {
          isNormalUser = true;
          extraGroups = [ "wheel" "video" "input" ];
          home = homeDir;
          createHome = true;
          openssh.authorizedKeys.keys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK9qcRB7tF1e8M9CX8zoPfNmQgWqvnee0SKASlM0aMlm mail@justinmoon.com"
          ];
        };
        security.sudo = {
          enable = true;
          wheelNeedsPassword = false;
        };

        environment.systemPackages = guestToolPkgs;

        systemd.services.shadow-ui-smoke = {
          description = "Verify the Shadow UI guest session";
          wantedBy = [ "multi-user.target" ];
          after = [ "greetd.service" ];
          serviceConfig = {
            Type = "oneshot";
            StandardOutput = "journal+console";
            StandardError = "journal+console";
          };
          script = ''
            for _ in $(seq 1 600); do
              process_snapshot="$(ps -eo args=)"
              if grep -Eq '(^|/)weston($| )|/bin/weston($| )' <<<"$process_snapshot"; then
                echo "shadow-ui smoke: compositor is running"
                exit 0
              fi
              sleep 1
            done

            echo "shadow-ui smoke: compositor did not appear" >&2
            echo "shadow-ui smoke: relevant processes:" >&2
            ps -ef | grep -E 'greetd|weston|shadow-|cargo run --manifest-path ui/Cargo.toml' | grep -v grep >&2 || true
            echo "shadow-ui smoke: greetd status:" >&2
            systemctl --no-pager --full status greetd.service >&2 || true
            echo "shadow-ui smoke: greetd journal:" >&2
            journalctl -b -u greetd.service --no-pager -n 80 >&2 || true
            exit 1
          '';
          path = with pkgs; [
            coreutils
            procps
            gnugrep
            systemd
          ];
        };

        systemd.tmpfiles.rules = [
          "d ${stateDir} 0755 shadow shadow -"
          "d ${targetDir} 0755 shadow shadow -"
          "d ${logDir} 0755 shadow shadow -"
          "d ${runtimeLibDir} 0755 shadow shadow -"
        ];

        microvm = {
          hypervisor = "qemu";
          vcpu = 4;
          mem = 4096;
          socket = ".shadow-vm/shadow-ui-vm.sock";
          graphics = {
            enable = true;
            backend = "cocoa";
          };
          writableStoreOverlay = "/nix/.rw-store";
          volumes = [
            {
              image = ".shadow-vm/nix-store-overlay.img";
              mountPoint = config.microvm.writableStoreOverlay;
              size = 8192;
            }
            {
              image = ".shadow-vm/shadow-ui-state.img";
              mountPoint = stateDir;
              size = 16384;
            }
          ];
          shares = [
            {
              proto = "9p";
              tag = "ro-store";
              source = "/nix/store";
              mountPoint = "/nix/.ro-store";
            }
            {
              proto = "9p";
              tag = "shadow-src";
              source = repoSource;
              mountPoint = repoDir;
            }
          ];
          interfaces = [
            {
              type = "user";
              id = "shadow-net";
              mac = "02:00:00:10:10:01";
            }
          ];
          forwardPorts = [
            {
              from = "host";
              host.port = 2222;
              guest.port = 22;
            }
          ];
          vmHostPackages = nixpkgs.legacyPackages.${hostSystem};
        };
      })
  ];
}
