{ hostSystem, microvm, nixpkgs, requiredBinaryNames, shadowUiVmSessionPackage, sshPort }:

let
  lib = nixpkgs.lib;
  guestSystem = builtins.replaceStrings [ "-darwin" ] [ "-linux" ] hostSystem;
  hostIsDarwin = lib.hasSuffix "-darwin" hostSystem;
  requiredSessionBinaries = [ "shadow-compositor" ] ++ requiredBinaryNames;
  requiredSessionBinaryArgs = lib.escapeShellArgs requiredSessionBinaries;
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
        sshShareDir = "/mnt/shadow-ui-vm-ssh";
        sshAuthorizedKeysSource = "${sshShareDir}/authorized_keys";
        sessionLog = "${logDir}/shadow-ui-session.log";
        sessionEnv = "${stateDir}/shadow-ui-session-env.sh";
        runtimeArtifactManifest = "${runtimeArtifactDir}/artifact-manifest.json";
        runtimeSessionConfig = "${runtimeArtifactDir}/session-config.json";
        systemEnvScript = "${runtimeArtifactDir}/runtime-system-session-env.sh";
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
            if [[ ! -f ${runtimeArtifactManifest} ]]; then
              echo "shadow-ui-session: missing host-prepared runtime manifest ${runtimeArtifactManifest}" >&2
              exit 1
            fi
            if [[ ! -f ${runtimeSessionConfig} ]]; then
              echo "shadow-ui-session: missing host-prepared session config ${runtimeSessionConfig}" >&2
              exit 1
            fi
            RUNTIME_ARTIFACT_MANIFEST=${runtimeArtifactManifest} \
            RUNTIME_SESSION_CONFIG=${runtimeSessionConfig} \
            RUNTIME_ARTIFACT_DIR=${runtimeArtifactDir} \
            RUNTIME_STATE_DIR=${stateDir} \
            python3 - <<'PY'
import json
import os
from pathlib import Path

manifest_path = Path(os.environ["RUNTIME_ARTIFACT_MANIFEST"])
config_path = Path(os.environ["RUNTIME_SESSION_CONFIG"])
artifact_dir = Path(os.environ["RUNTIME_ARTIFACT_DIR"])
state_dir = Path(os.environ["RUNTIME_STATE_DIR"])
with manifest_path.open("r", encoding="utf-8") as handle:
    manifest = json.load(handle)
with config_path.open("r", encoding="utf-8") as handle:
    config = json.load(handle)

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

for app_id in sorted(apps):
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

if config.get("schemaVersion") != 1:
    raise SystemExit("shadow-ui-session: session config schemaVersion must be 1")
if config.get("profile") != "vm-shell":
    raise SystemExit(
        f"shadow-ui-session: session config profile must be vm-shell, got {config.get('profile')!r}",
    )
if config.get("stateDir") != str(state_dir):
    raise SystemExit(
        f"shadow-ui-session: session config stateDir must be {state_dir!s}, got {config.get('stateDir')!r}",
    )

artifacts = config.get("artifacts")
if not isinstance(artifacts, dict):
    raise SystemExit("shadow-ui-session: session config artifacts must be an object")
if artifacts.get("guestRoot") != str(artifact_dir):
    raise SystemExit(
        f"shadow-ui-session: session config guest root must be {artifact_dir!s}, got {artifacts.get('guestRoot')!r}",
    )
if artifacts.get("root") != manifest.get("artifactRoot"):
    raise SystemExit(
        "shadow-ui-session: session config artifact root does not match runtime manifest",
    )

system = config.get("system")
if not isinstance(system, dict):
    raise SystemExit("shadow-ui-session: session config system must be an object")
if system.get("binaryPath") != manifest.get("systemBinaryPath"):
    raise SystemExit(
        "shadow-ui-session: session config system binary path does not match runtime manifest",
    )
if system.get("packageAttr") != manifest.get("systemPackageAttr"):
    raise SystemExit(
        "shadow-ui-session: session config system package attr does not match runtime manifest",
    )

startup = config.get("startup")
if not isinstance(startup, dict):
    raise SystemExit("shadow-ui-session: session config startup must be an object")
startup_app_id = startup.get("appId")
if startup_app_id is not None and (
    not isinstance(startup_app_id, str) or not startup_app_id
):
    raise SystemExit("shadow-ui-session: session config startup.appId must be null or a non-empty string")

services = config.get("services")
if not isinstance(services, dict):
    raise SystemExit("shadow-ui-session: session config services must be an object")
expected_cashu_dir = str(state_dir / "runtime-cashu")
expected_nostr_db_path = str(state_dir / "runtime-nostr.sqlite3")
expected_nostr_socket = str(state_dir / "runtime-nostr.sock")
if services.get("cashuDataDir") != expected_cashu_dir:
    raise SystemExit(
        "shadow-ui-session: session config cashu dir does not match expected VM state path",
    )
if services.get("nostrDbPath") != expected_nostr_db_path:
    raise SystemExit(
        "shadow-ui-session: session config nostr db path does not match expected VM state path",
    )
if services.get("nostrServiceSocket") != expected_nostr_socket:
    raise SystemExit(
        "shadow-ui-session: session config nostr socket does not match expected VM state path",
    )

runtime = config.get("runtime")
if not isinstance(runtime, dict):
    raise SystemExit("shadow-ui-session: session config runtime must be an object")
runtime_apps = runtime.get("apps")
if not isinstance(runtime_apps, dict):
    raise SystemExit("shadow-ui-session: session config runtime.apps must be an object")
if set(runtime_apps) != set(apps):
    raise SystemExit("shadow-ui-session: session config runtime.apps set does not match runtime manifest")

expected_default_app_id = "counter" if "counter" in apps else next(iter(apps), None)
expected_default_bundle_path = (
    apps[expected_default_app_id]["guestBundlePath"]
    if expected_default_app_id is not None
    else None
)
if runtime.get("defaultAppId") != expected_default_app_id:
    raise SystemExit(
        "shadow-ui-session: session config default runtime app does not match runtime manifest",
    )
if runtime.get("defaultBundlePath") != expected_default_bundle_path:
    raise SystemExit(
        "shadow-ui-session: session config default runtime bundle does not match runtime manifest",
    )

for app_id in sorted(apps):
    runtime_app = runtime_apps.get(app_id)
    if not isinstance(runtime_app, dict):
        raise SystemExit(f"shadow-ui-session: session config runtime app {app_id} must be an object")
    manifest_app = apps[app_id]
    if runtime_app.get("bundleEnv") != manifest_app.get("bundleEnv"):
        raise SystemExit(
            f"shadow-ui-session: session config bundle env mismatch for app {app_id}",
        )
    if runtime_app.get("bundlePath") != manifest_app.get("guestBundlePath"):
        raise SystemExit(
            f"shadow-ui-session: session config bundle path mismatch for app {app_id}",
        )
    if runtime_app.get("config") != manifest_app.get("runtimeAppConfig"):
        raise SystemExit(
            f"shadow-ui-session: session config runtime config mismatch for app {app_id}",
        )

print("runtime manifest and session config validated")
PY
            for binary in ${requiredSessionBinaryArgs}; do
              if [[ ! -x ${shadowUiVmSessionPackage}/bin/$binary ]]; then
                echo "shadow-ui-session: missing session binary ${shadowUiVmSessionPackage}/bin/$binary" >&2
                exit 1
              fi
            done
            echo "session binaries validated"
            runtime_config_env="$(mktemp ${stateDir}/runtime-config-env.XXXXXX)"
            RUNTIME_SESSION_CONFIG=${runtimeSessionConfig} \
            python3 - <<'PY' >"$runtime_config_env"
import json
import os
import shlex
from pathlib import Path

config_path = Path(os.environ["RUNTIME_SESSION_CONFIG"])
with config_path.open("r", encoding="utf-8") as handle:
    config = json.load(handle)

def emit(name: str, value: str) -> None:
    print(f"export {name}={shlex.quote(value)}")

def assign(name: str, value: str) -> None:
    print(f"{name}={shlex.quote(value)}")

emit("SHADOW_RUNTIME_SESSION_CONFIG", str(config_path))
emit("SHADOW_SESSION_APP_PROFILE", config["profile"])

system = config["system"]
binary_path = system.get("binaryPath")
if isinstance(binary_path, str) and binary_path:
    emit("SHADOW_SYSTEM_BINARY_PATH", binary_path)

services = config["services"]
assign("shadow_session_cashu_data_dir", services["cashuDataDir"])
assign("shadow_session_nostr_db_path", services["nostrDbPath"])
assign("shadow_session_nostr_service_socket", services["nostrServiceSocket"])
emit("SHADOW_RUNTIME_CASHU_DATA_DIR", services["cashuDataDir"])
emit("SHADOW_RUNTIME_NOSTR_DB_PATH", services["nostrDbPath"])
emit("SHADOW_RUNTIME_NOSTR_SERVICE_SOCKET", services["nostrServiceSocket"])
audio_backend = services.get("audioBackend")
assign(
    "shadow_session_audio_backend",
    audio_backend if isinstance(audio_backend, str) and audio_backend else "",
)
camera = services.get("camera")
camera_endpoint = ""
camera_allow_mock = ""
camera_timeout_ms = ""
if isinstance(camera, dict):
    endpoint = camera.get("endpoint")
    if isinstance(endpoint, str) and endpoint:
        camera_endpoint = endpoint
    allow_mock = camera.get("allowMock")
    if isinstance(allow_mock, bool):
        camera_allow_mock = "1" if allow_mock else "0"
    timeout_ms = camera.get("timeoutMs")
    if isinstance(timeout_ms, int) and timeout_ms > 0:
        camera_timeout_ms = str(timeout_ms)
assign("shadow_session_camera_endpoint", camera_endpoint)
assign("shadow_session_camera_allow_mock", camera_allow_mock)
assign("shadow_session_camera_timeout_ms", camera_timeout_ms)

runtime = config["runtime"]
default_bundle_path = runtime.get("defaultBundlePath")
if isinstance(default_bundle_path, str) and default_bundle_path:
    emit("SHADOW_RUNTIME_APP_BUNDLE_PATH", default_bundle_path)
for app_id in sorted(runtime["apps"]):
    app = runtime["apps"][app_id]
    bundle_env = app.get("bundleEnv")
    bundle_path = app.get("bundlePath")
    if isinstance(bundle_env, str) and bundle_env and isinstance(bundle_path, str) and bundle_path:
        emit(bundle_env, bundle_path)

startup = config["startup"]
startup_app_id = startup.get("appId")
if (
    isinstance(startup_app_id, str)
    and startup_app_id
    and startup_app_id != "shell"
):
    emit("SHADOW_COMPOSITOR_AUTO_LAUNCH", "1")
    emit("SHADOW_COMPOSITOR_START_APP_ID", startup_app_id)
PY
            # shellcheck source=/dev/null
            source "$runtime_config_env"
            rm -f "$runtime_config_env"
            echo "runtime config source=session-config"
            if [[ -f ${systemEnvScript} ]]; then
              # shellcheck source=/dev/null
              source ${systemEnvScript}
              echo "runtime env overlay=host-cache"
            else
              echo "runtime env overlay=none"
            fi
            runtime_bundle_path="''${SHADOW_RUNTIME_APP_BUNDLE_PATH:-}"
            system_path="''${SHADOW_SYSTEM_BINARY_PATH:-}"
            startup_app="''${SHADOW_COMPOSITOR_START_APP_ID:-shell}"
            echo "runtime bundle=''${runtime_bundle_path:-unset}"
            echo "system binary=''${system_path:-unset}"
            echo "runtime session config=$SHADOW_RUNTIME_SESSION_CONFIG"
            echo "startup app=$startup_app"
            echo "app launch mode=metadata"
            echo "runtime nostr db=''${shadow_session_nostr_db_path:-unset}"
            echo "runtime nostr socket=''${shadow_session_nostr_service_socket:-unset}"
            echo "runtime cashu dir=''${shadow_session_cashu_data_dir:-unset}"
            echo "runtime audio backend=''${shadow_session_audio_backend:-unset}"
            echo "runtime camera endpoint=''${shadow_session_camera_endpoint:-unset}"
            echo "runtime camera allow_mock=''${shadow_session_camera_allow_mock:-unset}"

            ${shadowUiVmSessionPackage}/bin/shadow-compositor &
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
              "export SHADOW_RUNTIME_SESSION_CONFIG=\"$SHADOW_RUNTIME_SESSION_CONFIG\"" \
              "export SHADOW_SESSION_APP_PROFILE=\"$SHADOW_SESSION_APP_PROFILE\"" \
              "export SHADOW_RUNTIME_APP_BUNDLE_PATH=\"$runtime_bundle_path\"" \
              "export SHADOW_SYSTEM_BINARY_PATH=\"$system_path\"" \
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
        };
        security.sudo = {
          enable = true;
          wheelNeedsPassword = false;
        };

        systemd.services.shadow-ui-install-authorized-keys = {
          description = "Install Shadow UI VM SSH authorized keys";
          wantedBy = [ "multi-user.target" ];
          before = [ "sshd.service" ];
          after = [ "local-fs.target" ];
          path = with pkgs; [
            coreutils
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            install -d -m 0700 -o shadow -g shadow ${homeDir}/.ssh
            if [[ ! -f ${sshAuthorizedKeysSource} ]]; then
              echo "shadow-ui-vm: missing SSH authorized keys file ${sshAuthorizedKeysSource}" >&2
              exit 1
            fi
            install -m 0600 -o shadow -g shadow \
              ${sshAuthorizedKeysSource} \
              ${homeDir}/.ssh/authorized_keys
          '';
        };

        environment.systemPackages =
          guestSystemPkgs
          ++ [
            shadowUiVmSessionPackage
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
          "d ${homeDir} 0755 shadow shadow -"
          "d ${logDir} 0755 shadow shadow -"
          "d ${runtimeLibDir} 0755 shadow shadow -"
        ];

        microvm = {
          hypervisor = "qemu";
          vcpu = 4;
          mem = 4096;
          socket = ".shadow-vm/shadow-ui-vm.sock";
          graphics = { enable = false; } // lib.optionalAttrs hostIsDarwin { backend = "cocoa"; };
          qemu.extraArgs =
            [
              "-display"
            ]
            ++ (if hostIsDarwin then [ "cocoa" ] else [ "none" ])
            ++ [
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
            {
              proto = "9p";
              tag = "shadow-vm-ssh";
              source = ".shadow-vm/ssh";
              mountPoint = sshShareDir;
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
              host.address = "127.0.0.1";
              host.port = sshPort;
              guest.port = 22;
            }
          ];
          vmHostPackages = nixpkgs.legacyPackages.${hostSystem};
        };
      })
  ];
}
