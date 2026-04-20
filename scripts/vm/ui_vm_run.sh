#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./ui_vm_common.sh
source "$SCRIPT_DIR/lib/ui_vm_common.sh"
# shellcheck source=./ci_vm_smoke_common.sh
source "$SCRIPT_DIR/lib/ci_vm_smoke_common.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER_LINK="$REPO_ROOT/.shadow-vm/ui-vm-runner"
SOCKET_PATH="$REPO_ROOT/.shadow-vm/shadow-ui-vm.sock"
RUNTIME_ARTIFACT_DIR="$(ui_vm_runtime_artifact_dir)"
RUNTIME_ENV_PATH="$(ui_vm_runtime_env_path)"
RUNTIME_GUEST_DIR="$(ui_vm_runtime_guest_dir)"
# shellcheck source=./session_apps.sh
source "$SCRIPT_DIR/lib/session_apps.sh"
export SHADOW_SESSION_APP_PROFILE="vm-shell"

ui_vm_start_app_id="$(shadow_session_shell_app_id)"
prepared_inputs_path="${SHADOW_UI_VM_PREPARED_INPUTS:-}"

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --app)
        ui_vm_start_app_id="${2:-}"
        shift 2
        ;;
      --prepared-inputs)
        prepared_inputs_path="${2:-}"
        shift 2
        ;;
      *)
        echo "vm: unsupported argument $1" >&2
        exit 1
        ;;
    esac
  done
}

parse_args "$@"

cd "$REPO_ROOT"
mkdir -p .shadow-vm "$RUNTIME_ARTIFACT_DIR"
runtime_env_tmp=""
ui_vm_state_dir="/var/lib/shadow-ui"
ui_vm_ssh_port_value="${SHADOW_UI_VM_SSH_PORT:-$(ui_vm_ssh_port)}"
runtime_audio_backend="${SHADOW_RUNTIME_AUDIO_BACKEND:-}"
podcast_fixture_dir="$REPO_ROOT/runtime/app-podcast-player/fixture"

cleanup_runtime_env_tmp() {
  if [[ -n "${runtime_env_tmp:-}" ]]; then
    rm -f "$runtime_env_tmp"
  fi
}

prepare_runner_link() {
  local package_path="$1"
  local binary_path="$2"
  local ssh_port="$3"
  local runner_tmp

  runner_tmp="$(mktemp -d "$REPO_ROOT/.shadow-vm/ui-vm-runner.XXXXXX")"
  mkdir -p "$runner_tmp/bin"
  ln -s "$package_path" "$runner_tmp/store"
  ln -s "$package_path/bin/microvm-shutdown" "$runner_tmp/bin/microvm-shutdown"
  if [[ -x "$package_path/bin/microvm-balloon" ]]; then
    ln -s "$package_path/bin/microvm-balloon" "$runner_tmp/bin/microvm-balloon"
  fi

  python3 - "$binary_path" "$ssh_port" "$runner_tmp/bin/microvm-run" <<'PY'
import pathlib
import re
import sys

source_path = pathlib.Path(sys.argv[1])
ssh_port = sys.argv[2]
target_path = pathlib.Path(sys.argv[3])
script = source_path.read_text(encoding="utf-8")
rewritten, count = re.subn(
    r"hostfwd=tcp::\d+-:22,",
    f"hostfwd=tcp::{ssh_port}-:22,",
    script,
    count=1,
)
if count != 1:
    raise SystemExit("vm: failed to rewrite ui-vm runner SSH port")
target_path.write_text(rewritten, encoding="utf-8")
target_path.chmod(0o755)
PY

  rm -rf "$RUNNER_LINK"
  mv "$runner_tmp" "$RUNNER_LINK"
}

trap cleanup_runtime_env_tmp EXIT

if [[ -z "$prepared_inputs_path" ]]; then
  prepared_inputs_path="$(vm_smoke_inputs_path "$REPO_ROOT")"
fi

prepared_source_root="$(vm_smoke_metadata_value "$prepared_inputs_path" sourceStorePath)"
system_package_attr="$(vm_smoke_metadata_value "$prepared_inputs_path" systemPackageAttr)"
system_binary_path="$(vm_smoke_metadata_value "$prepared_inputs_path" systemBinaryPath)"
ui_vm_runner_package_path="$(vm_smoke_metadata_value "$prepared_inputs_path" uiVmRunnerPackagePath)"
ui_vm_runner_binary_path="$(vm_smoke_metadata_value "$prepared_inputs_path" uiVmRunnerBinaryPath)"

if lsof -nP -iTCP:"$ui_vm_ssh_port_value" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "vm: SSH port $ui_vm_ssh_port_value is already in use" >&2
  echo "vm: stop the current worktree VM first with 'just stop target=vm' or set SHADOW_UI_VM_SSH_PORT" >&2
  exit 1
fi

if [[ -S "$SOCKET_PATH" ]]; then
  rm -f "$SOCKET_PATH"
fi

rm -f .shadow-vm/nix-store-overlay.img
runtime_env_tmp="$(mktemp "$RUNTIME_ARTIFACT_DIR/runtime-system-session-env.XXXXXX")"
SHADOW_PODCAST_PLAYER_ASSET_DIR="$podcast_fixture_dir" \
SHADOW_PODCAST_PLAYER_EPISODE_IDS=00 \
scripts/runtime/runtime_prepare_host_session_env.sh \
  --flake-ref "$prepared_source_root" \
  --system-package "$system_package_attr" \
  --system-binary-path "$system_binary_path" \
  --include-podcast \
  --artifact-root "$RUNTIME_ARTIFACT_DIR" \
  --artifact-guest-root "$RUNTIME_GUEST_DIR" \
  --audio-backend "$runtime_audio_backend" \
  --state-dir "$ui_vm_state_dir" >"$runtime_env_tmp"
if shadow_session_app_is_shell "$ui_vm_start_app_id"; then
  :
elif shadow_session_app_supports_auto_open "$ui_vm_start_app_id" "vm-shell"; then
  {
    printf 'export SHADOW_COMPOSITOR_AUTO_LAUNCH=1\n'
    printf 'export SHADOW_COMPOSITOR_START_APP_ID=%q\n' "$ui_vm_start_app_id"
  } >>"$runtime_env_tmp"
else
  echo "vm: unsupported --app $ui_vm_start_app_id; expected $(shadow_session_apps_usage "vm-shell")" >&2
  exit 1
fi
mv "$runtime_env_tmp" "$RUNTIME_ENV_PATH"
chmod 0644 "$RUNTIME_ENV_PATH"
runtime_env_tmp=""

[[ -d "$ui_vm_runner_package_path" ]] || {
  echo "vm: prepared runner package not found: $ui_vm_runner_package_path" >&2
  exit 1
}
[[ -x "$ui_vm_runner_binary_path" ]] || {
  echo "vm: prepared runner binary not found: $ui_vm_runner_binary_path" >&2
  exit 1
}

prepare_runner_link "$ui_vm_runner_package_path" "$ui_vm_runner_binary_path" "$ui_vm_ssh_port_value"

echo "vm: launching Shadow UI VM"
echo "vm: qemu window will host the real Linux compositor"
echo "vm: ssh endpoint shadow@127.0.0.1:$ui_vm_ssh_port_value"
echo "vm: state image .shadow-vm/shadow-ui-state.img"
echo "vm: runtime artifacts .shadow-vm/runtime-artifacts"
echo "vm: logical inputs $prepared_inputs_path"
echo "vm: prepared source $prepared_source_root"
echo "vm: first boot or dependency changes may spend time building Linux artifacts through Nix"
echo "vm: use 'sc -t vm doctor' or 'sc -t vm wait-ready' while the screen is blank"

trap - EXIT
exec "$RUNNER_LINK/bin/microvm-run"
