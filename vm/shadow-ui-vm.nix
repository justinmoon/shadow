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
        buildLog = "${logDir}/shadow-ui-build.log";
        sessionEnv = "${stateDir}/shadow-ui-session-env.sh";
        guestToolPkgs = with pkgs; [
          cargo
          clang
          just
          pkg-config
          python3
          rustc
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
        shadowUiGuestEnv = pkgs.writeText "shadow-ui-env.sh" ''
          export HOME=${homeDir}
          export XDG_CACHE_HOME="$HOME/.cache"
          export CARGO_TARGET_DIR=${targetDir}
          export PKG_CONFIG_PATH="${guestPkgConfigPath}:''${PKG_CONFIG_PATH:-}"
          export LD_LIBRARY_PATH="${runtimeLibDir}:${guestLibraryPath}:''${LD_LIBRARY_PATH:-}"
          export LIBRARY_PATH="${guestLibraryPath}:''${LIBRARY_PATH:-}"
          export NIX_LDFLAGS="${guestLinkFlags} ''${NIX_LDFLAGS:-}"
          export LIBGL_DRIVERS_PATH="${pkgs.mesa}/lib/dri:''${LIBGL_DRIVERS_PATH:-}"
          export RUST_BACKTRACE=1
          export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

          mkdir -p "$HOME" "$XDG_CACHE_HOME" "$CARGO_TARGET_DIR" ${logDir} ${runtimeLibDir}
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
          EOF
        '';
        shadowUiWarmup = pkgs.writeShellApplication {
          name = "shadow-ui-warmup";
          runtimeInputs = with pkgs; [
            bash
            coreutils
          ] ++ guestToolPkgs ++ guestRuntimeLibs;
          text = ''
            set -euo pipefail
            # shellcheck source=/dev/null
            source ${shadowUiGuestEnv}

            cd ${repoDir}
            : >${buildLog}
            exec >>${buildLog} 2>&1

            echo "== shadow-ui-warmup $(date --iso-8601=seconds) =="
            cargo build --locked --manifest-path ui/Cargo.toml \
              -p shadow-compositor \
              -p shadow-counter
          '';
        };
        shadowUiSession = pkgs.writeShellApplication {
          name = "shadow-ui-session";
          runtimeInputs = with pkgs; [
            bash
            coreutils
          ] ++ guestToolPkgs ++ guestRuntimeLibs;
          text = ''
            set -euo pipefail
            # shellcheck source=/dev/null
            source ${shadowUiGuestEnv}

            cd ${repoDir}
            : >${sessionLog}
            exec >>${sessionLog} 2>&1

            echo "== shadow-ui-session $(date --iso-8601=seconds) =="
            echo "cwd: $(pwd)"
            echo "WAYLAND_DISPLAY=''${WAYLAND_DISPLAY:-unset}"
            echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"

            cargo run --locked --manifest-path ui/Cargo.toml -p shadow-compositor &
            compositor_pid=$!

            cleanup() {
              if kill -0 "$compositor_pid" 2>/dev/null; then
                kill "$compositor_pid" 2>/dev/null || true
                wait "$compositor_pid" 2>/dev/null || true
              fi
            }
            trap cleanup EXIT

            control_socket="$XDG_RUNTIME_DIR/shadow-control.sock"
            for _ in $(seq 1 900); do
              if [[ -S "$control_socket" ]]; then
                break
              fi
              if ! kill -0 "$compositor_pid" 2>/dev/null; then
                echo "shadow-ui-session: compositor exited before control socket appeared" >&2
                wait "$compositor_pid"
                exit 1
              fi
              sleep 1
            done

            if [[ ! -S "$control_socket" ]]; then
              echo "shadow-ui-session: timed out waiting for compositor control socket" >&2
              exit 1
            fi

            nested_wayland=""
            for _ in $(seq 1 900); do
              nested_wayland="$(
                SHADOW_CONTROL_SOCKET="$control_socket" python3 - <<'PY'
import os
import socket
import sys

path = os.environ["SHADOW_CONTROL_SOCKET"]
try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(path)
        client.sendall(b"state\n")
        client.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
except OSError:
    sys.exit(0)

for line in b"".join(chunks).decode("utf-8").splitlines():
    if line.startswith("socket="):
        print(line.removeprefix("socket="))
        break
PY
              )"
              if [[ -n "$nested_wayland" ]]; then
                break
              fi
              if ! kill -0 "$compositor_pid" 2>/dev/null; then
                echo "shadow-ui-session: compositor exited before nested wayland socket appeared" >&2
                wait "$compositor_pid"
                exit 1
              fi
              sleep 1
            done

            if [[ -z "$nested_wayland" ]]; then
              echo "shadow-ui-session: timed out waiting for nested wayland socket" >&2
              exit 1
            fi

            printf '%s\n' \
              "export HOME=\"$HOME\"" \
              "export XDG_CACHE_HOME=\"$XDG_CACHE_HOME\"" \
              "export CARGO_TARGET_DIR=\"$CARGO_TARGET_DIR\"" \
              "export PKG_CONFIG_PATH=\"$PKG_CONFIG_PATH\"" \
              "export LD_LIBRARY_PATH=\"$LD_LIBRARY_PATH\"" \
              "export LIBRARY_PATH=\"$LIBRARY_PATH\"" \
              "export NIX_LDFLAGS=\"$NIX_LDFLAGS\"" \
              "export LIBGL_DRIVERS_PATH=\"$LIBGL_DRIVERS_PATH\"" \
              "export RUST_BACKTRACE=\"$RUST_BACKTRACE\"" \
              "export XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\"" \
              "export WAYLAND_DISPLAY=\"$nested_wayland\"" \
              "export SHADOW_COMPOSITOR_CONTROL=\"$control_socket\"" \
              >${sessionEnv}

            echo "shadow-ui-session: compositor ready on $nested_wayland"
            wait "$compositor_pid"
          '';
        };
        initialSession = {
          user = "shadow";
          command =
            "${pkgs.dbus}/bin/dbus-run-session ${pkgs.cage}/bin/cage -- ${shadowUiSession}/bin/shadow-ui-session";
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

        systemd.services.shadow-ui-warmup = {
          description = "Prebuild the Shadow UI guest binaries";
          before = [ "greetd.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            User = "shadow";
            Group = "shadow";
            StandardOutput = "journal+console";
            StandardError = "journal+console";
          };
          script = ''
            exec ${shadowUiWarmup}/bin/shadow-ui-warmup
          '';
        };

        systemd.services.greetd = {
          after = [ "shadow-ui-warmup.service" ];
          requires = [ "shadow-ui-warmup.service" ];
        };

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
              uid="$(id -u shadow 2>/dev/null || id -u)"
              runtime_dir="/run/user/$uid"
              process_snapshot="$(ps -eo args=)"
              if grep -Fq '/bin/cage --' <<<"$process_snapshot" \
                && grep -Eq '(^|/)shadow-compositor($| )|cargo run( --locked)? --manifest-path ui/Cargo.toml -p shadow-compositor' <<<"$process_snapshot" \
                && [[ -S "$runtime_dir/shadow-control.sock" ]]; then
                echo "shadow-ui smoke: compositor is running"
                exit 0
              fi
              sleep 1
            done

            echo "shadow-ui smoke: compositor did not appear" >&2
            echo "shadow-ui smoke: relevant processes:" >&2
            ps -ef | grep -E 'greetd|cage|shadow-|cargo run --manifest-path ui/Cargo.toml' | grep -v grep >&2 || true
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
            enable = false;
            backend = "cocoa";
          };
          qemu.extraArgs = [
            "-display"
            "cocoa,zoom-to-fit=on"
            "-device"
            "virtio-gpu,xres=640,yres=1220"
            "-device"
            "qemu-xhci"
            "-device"
            "usb-tablet"
            "-device"
            "usb-kbd"
          ];
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
