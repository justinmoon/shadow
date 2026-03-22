#!/usr/bin/env bash

REMOTE_HOST="${CUTTLEFISH_REMOTE_HOST:-hetzner}"
REMOTE_HOME_CACHE="${REMOTE_HOME_CACHE:-}"
HOST_SHORT="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "")"
HOST_FQDN="$(hostname -f 2>/dev/null || echo "")"
GOOGLESOURCE_AVB_TESTKEY_URL="${GOOGLESOURCE_AVB_TESTKEY_URL:-https://android.googlesource.com/platform/external/avb/+/refs/heads/sdk-release/test/data/testkey_rsa4096.pem?format=TEXT}"
REMOTE_FLAKE_DIR_CACHE="${REMOTE_FLAKE_DIR_CACHE:-}"

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

state_file() {
  printf '%s/.cuttlefish-instance\n' "$(repo_root)"
}

artifacts_dir() {
  printf '%s/artifacts\n' "$(repo_root)"
}

stock_images_dir() {
  printf '%s/stock\n' "$(artifacts_dir)"
}

keys_dir() {
  printf '%s/keys\n' "$(artifacts_dir)"
}

build_dir() {
  printf '%s/build\n' "$(repo_root)"
}

flake_path() {
  printf '%s#bootimg\n' "$(repo_root)"
}

ensure_bootimg_shell() {
  if [[ "${SHADOW_BOOTIMG_SHELL:-}" == "1" ]]; then
    return 0
  fi
  exec nix develop "$(flake_path)" -c "$0" "$@"
}

cached_boot_image() {
  printf '%s/boot.img\n' "$(stock_images_dir)"
}

cached_init_boot_image() {
  printf '%s/init_boot.img\n' "$(stock_images_dir)"
}

cached_avb_testkey() {
  printf '%s/avb_testkey_rsa4096.pem\n' "$(keys_dir)"
}

record_instance() {
  printf '%s\n' "$1" >"$(state_file)"
}

recorded_instance() {
  local path
  path="$(state_file)"
  if [[ -f "$path" ]]; then
    tr -d '[:space:]' <"$path"
  fi
}

clear_recorded_instance() {
  rm -f "$(state_file)"
}

worktree_basename() {
  local root
  root="$(repo_root)"
  if [[ "$root" == *"/worktrees/"* ]]; then
    basename "$root"
  else
    git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main"
  fi
}

deterministic_instance_name() {
  local raw checksum
  raw="${1:-}"
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$raw"
    return
  fi
  if [[ -z "$raw" ]]; then
    raw="$(worktree_basename)"
  fi
  [[ -z "$raw" ]] && raw="main"
  raw="${raw,,}"
  raw="${raw//[^a-z0-9-]/-}"
  raw="${raw#-}"
  raw="${raw%-}"
  [[ -z "$raw" ]] && raw="main"
  checksum="$(printf '%s' "$raw" | cksum | awk '{print $1}')"
  printf '%s\n' $((100 + (checksum % 900)))
}

active_instance_name() {
  if [[ -n "${CUTTLEFISH_INSTANCE_OVERRIDE:-}" ]]; then
    deterministic_instance_name "$CUTTLEFISH_INSTANCE_OVERRIDE"
    return
  fi
  if [[ -n "${CUTTLEFISH_INSTANCE:-}" ]]; then
    deterministic_instance_name "$CUTTLEFISH_INSTANCE"
    return
  fi
  if [[ -f "$(state_file)" ]]; then
    recorded_instance
    return
  fi
  deterministic_instance_name ""
}

adb_port_for_instance() {
  local base instance
  base="${CUTTLEFISH_BASE_ADB_PORT:-6520}"
  instance="$1"
  printf '%s\n' $((base + instance - 1))
}

uuid_for_instance() {
  local instance
  instance="$1"
  printf '699acfc4-c8c4-11e7-882b-%012x\n' "$instance"
}

is_local_host() {
  case "${REMOTE_HOST}" in
    ""|"local"|"localhost"|"127.0.0.1"|"$HOST_SHORT"|"$HOST_FQDN")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

remote_shell() {
  local script
  script="$1"
  if is_local_host; then
    bash -lc "$script"
  else
    ssh "$REMOTE_HOST" "bash -lc $(printf '%q' "$script")"
  fi
}

remote_bash() {
  if is_local_host; then
    /bin/bash
  else
    ssh "$REMOTE_HOST" /bin/bash
  fi
}

remote_flake_dir() {
  if [[ -z "${REMOTE_FLAKE_DIR_CACHE:-}" ]]; then
    REMOTE_FLAKE_DIR_CACHE="$(remote_home)/.cache/shadow-flake"
  fi
  printf '%s\n' "$REMOTE_FLAKE_DIR_CACHE"
}

sync_remote_flake() {
  local remote_dir
  remote_dir="$(remote_flake_dir)"
  remote_shell "mkdir -p $(printf '%q' "$remote_dir")"
  copy_to_remote "$(repo_root)/flake.nix" "${remote_dir}/flake.nix"
  copy_to_remote "$(repo_root)/flake.lock" "${remote_dir}/flake.lock"
}

remote_nix_bash() {
  local script command
  script="$1"
  if is_local_host; then
    nix develop "$(flake_path)" -c bash -c "$script"
  else
    sync_remote_flake
    command="cd $(printf '%q' "$(remote_flake_dir)") && nix develop .#bootimg -c bash -c $(printf '%q' "$script")"
    ssh "$REMOTE_HOST" /bin/bash -lc "$(printf '%q' "$command")"
  fi
}

remote_home() {
  if [[ -z "${REMOTE_HOME_CACHE:-}" ]]; then
    if is_local_host; then
      REMOTE_HOME_CACHE="$HOME"
    else
      REMOTE_HOME_CACHE="$(remote_shell 'printf %s "$HOME"')"
    fi
  fi
  printf '%s\n' "$REMOTE_HOME_CACHE"
}

remote_artifact_dir() {
  printf '%s/cuttlefish-instances/%s\n' "$(remote_home)" "$1"
}

copy_to_remote() {
  local src dest
  src="$1"
  dest="$2"
  if is_local_host; then
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
  else
    scp -q "$src" "${REMOTE_HOST}:$dest"
  fi
}

launcher_log_path() {
  printf '/var/lib/cuttlefish/instances/%s/direct-launch.log\n' "$1"
}

kernel_log_path() {
  printf '/var/lib/cuttlefish/instances/%s/instances/cvd-%s/kernel.log\n' "$1" "$1"
}

kernel_log_fallback_path() {
  printf '/var/lib/cuttlefish/instances/%s/instances/cvd-%s/logs/kernel.log\n' "$1" "$1"
}

console_log_path() {
  printf '/var/lib/cuttlefish/instances/%s/instances/cvd-%s/console_log\n' "$1" "$1"
}

cleanup_remote_instance() {
  local instance port
  instance="$1"
  port="${2:-$(adb_port_for_instance "$instance")}"
  remote_bash <<EOF
set -euo pipefail
instance="$instance"
port="$port"
sudo pkill -f "cvd-\${instance}|launch_cvd|qemu-system-x86_64.*\${port}" >/dev/null 2>&1 || true
sudo ip tuntap del mode tap "cvd-mtap-\${instance}" >/dev/null 2>&1 || true
sudo ip tuntap del mode tap "cvd-tap-\${instance}" >/dev/null 2>&1 || true
sudo ip link del "cvd-eth-\${instance}" >/dev/null 2>&1 || true
sudo rm -rf \
  "/var/lib/cuttlefish/instances/\${instance}" \
  "/var/lib/cuttlefish/assembly/\${instance}" \
  "/tmp/cf_avd_0/cvd-\${instance}" \
  "/tmp/cf_env_0/env-\${instance}" \
  "/tmp/cf_img_0/cvd-\${instance}" \
  "$(remote_artifact_dir "$instance")"
EOF
}

wait_for_remote_pattern() {
  local instance pattern timeout q_pattern
  instance="$1"
  pattern="$2"
  timeout="$3"
  q_pattern="$(printf '%q' "$pattern")"
  remote_bash <<EOF
set -euo pipefail
instance="$instance"
pattern=$q_pattern
timeout="$timeout"
deadline=\$(( \$(date +%s) + timeout ))
launcher_log="$(launcher_log_path "$instance")"
kernel_log="$(kernel_log_path "$instance")"
kernel_log_fallback="$(kernel_log_fallback_path "$instance")"
console_log="$(console_log_path "$instance")"
while (( \$(date +%s) < deadline )); do
  if [[ -f "\$launcher_log" ]] && grep -Eq 'assemble_cvd failed|Unknown target architecture|main.cc:263 assemble_cvd returned -1' "\$launcher_log"; then
    tail -n 200 "\$launcher_log" >&2 || true
    exit 2
  fi
  for path in "\$kernel_log" "\$kernel_log_fallback" "\$console_log" "\$launcher_log"; do
    if [[ -f "\$path" ]] && grep -Eq "\$pattern" "\$path"; then
      exit 0
    fi
  done
  sleep 2
done
for path in "\$launcher_log" "\$kernel_log" "\$kernel_log_fallback" "\$console_log"; do
  if [[ -f "\$path" ]]; then
    echo "==== \$path ====" >&2
    tail -n 120 "\$path" >&2 || true
  fi
done
exit 1
EOF
}
