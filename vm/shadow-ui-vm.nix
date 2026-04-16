{ hostSystem, microvm, nixpkgs, shadowBlitzDemoPackage, shadowCompositorPackage, sshPort }:

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
        homeDir = "${stateDir}/home";
        logDir = "${stateDir}/log";
        runtimeLibDir = "${stateDir}/runtime-libs";
        runtimeArtifactDir = "/opt/shadow-runtime";
        sessionLog = "${logDir}/shadow-ui-session.log";
        sessionEnv = "${stateDir}/shadow-ui-session-env.sh";
        runtimeArtifactManifest = "${runtimeArtifactDir}/artifact-manifest.json";
        runtimeHostEnvScript = "${runtimeArtifactDir}/runtime-host-session-env.sh";
        guestSystemPkgs = with pkgs; [
          bash
          coreutils
          findutils
          gnugrep
          procps
          python3
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
        guestLibraryPath = lib.makeLibraryPath guestRuntimeLibs;
        shadowUiGuestEnv = pkgs.writeText "shadow-ui-env.sh" ''
          export HOME=${homeDir}
          export XDG_CACHE_HOME="$HOME/.cache"
          export LD_LIBRARY_PATH="${runtimeLibDir}:${guestLibraryPath}:''${LD_LIBRARY_PATH:-}"
          export LIBGL_DRIVERS_PATH="${pkgs.mesa}/lib/dri:''${LIBGL_DRIVERS_PATH:-}"
          export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
          export SHADOW_APP_CLIENT=${shadowBlitzDemoPackage}/bin/shadow-blitz-demo

          mkdir -p "$HOME" "$XDG_CACHE_HOME" ${logDir} ${runtimeLibDir}
          cp -fL ${pkgs.libglvnd}/lib/libEGL.so.1 ${runtimeLibDir}/libEGL.so.1
          cp -fL ${pkgs.libglvnd}/lib/libGL.so.1 ${runtimeLibDir}/libGL.so.1
          cp -fL ${pkgs.libglvnd}/lib/libOpenGL.so.0 ${runtimeLibDir}/libOpenGL.so.0
          cp -fL ${pkgs.libglvnd}/lib/libGLESv2.so.2 ${runtimeLibDir}/libGLESv2.so.2

          cat >${sessionEnv} <<EOF
          export HOME="$HOME"
          export XDG_CACHE_HOME="$XDG_CACHE_HOME"
          export LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
          export LIBGL_DRIVERS_PATH="$LIBGL_DRIVERS_PATH"
          export XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
          export SHADOW_APP_CLIENT="$SHADOW_APP_CLIENT"
          EOF
        '';
        shadowUiSession = pkgs.writeShellApplication {
          name = "shadow-ui-session";
          runtimeInputs = with pkgs; [
            bash
            coreutils
          ] ++ guestSystemPkgs ++ guestRuntimeLibs;
          text = ''
            set -euo pipefail
            # shellcheck source=/dev/null
            source ${shadowUiGuestEnv}

            : >${sessionLog}
            exec >>${sessionLog} 2>&1

            echo "== shadow-ui-session $(date --iso-8601=seconds) =="
            echo "WAYLAND_DISPLAY=''${WAYLAND_DISPLAY:-unset}"
            echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
            echo "runtime artifact dir=${runtimeArtifactDir}"

            echo "preparing runtime app session"
            if [[ ! -f ${runtimeHostEnvScript} ]]; then
              echo "shadow-ui-session: missing host-prepared runtime env ${runtimeHostEnvScript}" >&2
              exit 1
            fi
            if [[ ! -f ${runtimeArtifactManifest} ]]; then
              echo "shadow-ui-session: missing host-prepared runtime manifest ${runtimeArtifactManifest}" >&2
              exit 1
            fi
            RUNTIME_ARTIFACT_MANIFEST=${runtimeArtifactManifest} \
            RUNTIME_ARTIFACT_DIR=${runtimeArtifactDir} \
            python3 - <<'PY'
import json
import os
from pathlib import Path

manifest_path = Path(os.environ["RUNTIME_ARTIFACT_MANIFEST"])
artifact_dir = Path(os.environ["RUNTIME_ARTIFACT_DIR"])
with manifest_path.open("r", encoding="utf-8") as handle:
    manifest = json.load(handle)

if manifest.get("schemaVersion") != 1:
    raise SystemExit("shadow-ui-session: runtime manifest schemaVersion must be 1")
if manifest.get("profile") != "vm-shell":
    raise SystemExit(
        f"shadow-ui-session: runtime manifest profile must be vm-shell, got {manifest.get('profile')!r}",
    )
if manifest.get("artifactGuestRoot") != str(artifact_dir):
    raise SystemExit(
        "shadow-ui-session: runtime manifest artifactGuestRoot does not match mounted artifact dir",
    )

apps = manifest.get("apps")
if not isinstance(apps, dict):
    raise SystemExit("shadow-ui-session: runtime manifest apps must be an object")

required_apps = {"camera", "cashu", "counter", "podcast", "timeline"}
missing = sorted(required_apps - set(apps))
if missing:
    raise SystemExit(
        "shadow-ui-session: runtime manifest missing apps: " + ", ".join(missing),
    )

for app_id in sorted(required_apps):
    app = apps[app_id]
    guest_bundle = app.get("guestBundlePath")
    if not isinstance(guest_bundle, str) or not guest_bundle:
        raise SystemExit(f"shadow-ui-session: app {app_id} missing guestBundlePath")
    guest_bundle_path = Path(guest_bundle)
    try:
        guest_bundle_path.relative_to(artifact_dir)
    except ValueError as error:
        raise SystemExit(
            f"shadow-ui-session: app {app_id} bundle is outside artifact dir: {guest_bundle}",
        ) from error
    if not guest_bundle_path.is_file():
        raise SystemExit(
            f"shadow-ui-session: app {app_id} bundle does not exist: {guest_bundle}",
        )

print("runtime manifest validated")
PY
            # shellcheck source=/dev/null
            source ${runtimeHostEnvScript}
            echo "runtime env source=host-cache"
            export SHADOW_RUNTIME_CASHU_DATA_DIR=${stateDir}/runtime-cashu
            export SHADOW_RUNTIME_NOSTR_DB_PATH=${stateDir}/runtime-nostr.sqlite3
            echo "runtime bundle=$SHADOW_RUNTIME_APP_BUNDLE_PATH"
            echo "runtime host=$SHADOW_RUNTIME_HOST_BINARY_PATH"
            echo "app client=$SHADOW_APP_CLIENT"
            echo "runtime nostr db=$SHADOW_RUNTIME_NOSTR_DB_PATH"
            echo "runtime cashu dir=$SHADOW_RUNTIME_CASHU_DATA_DIR"

            ${shadowCompositorPackage}/bin/shadow-compositor &
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
              "export LD_LIBRARY_PATH=\"$LD_LIBRARY_PATH\"" \
              "export LIBGL_DRIVERS_PATH=\"$LIBGL_DRIVERS_PATH\"" \
              "export XDG_RUNTIME_DIR=\"$XDG_RUNTIME_DIR\"" \
              "export SHADOW_APP_CLIENT=\"$SHADOW_APP_CLIENT\"" \
              "export SHADOW_RUNTIME_APP_BUNDLE_PATH=\"$SHADOW_RUNTIME_APP_BUNDLE_PATH\"" \
              "export SHADOW_RUNTIME_HOST_BINARY_PATH=\"$SHADOW_RUNTIME_HOST_BINARY_PATH\"" \
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

        environment.systemPackages =
          guestSystemPkgs
          ++ [
            shadowBlitzDemoPackage
            shadowCompositorPackage
          ];

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
                && grep -Eq '(^|/)shadow-compositor($| )' <<<"$process_snapshot" \
                && ! command -v cargo >/dev/null 2>&1 \
                && ! command -v rustc >/dev/null 2>&1 \
                && [[ -S "$runtime_dir/shadow-control.sock" ]]; then
                echo "shadow-ui smoke: compositor is running without guest toolchains"
                exit 0
              fi
              sleep 1
            done

            echo "shadow-ui smoke: compositor did not appear" >&2
            echo "shadow-ui smoke: relevant processes:" >&2
            ps -ef | grep -E 'greetd|cage|shadow-' | grep -v grep >&2 || true
            echo "shadow-ui smoke: cargo present? $(command -v cargo >/dev/null 2>&1 && echo yes || echo no)" >&2
            echo "shadow-ui smoke: rustc present? $(command -v rustc >/dev/null 2>&1 && echo yes || echo no)" >&2
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
            "cocoa"
            "-device"
            "virtio-gpu,xres=660,yres=1240"
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
              tag = "shadow-runtime";
              source = ".shadow-vm/runtime-artifacts";
              mountPoint = runtimeArtifactDir;
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
              host.port = sshPort;
              guest.port = 22;
            }
          ];
          vmHostPackages = nixpkgs.legacyPackages.${hostSystem};
        };
      })
  ];
}
