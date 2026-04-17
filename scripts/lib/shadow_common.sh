#!/usr/bin/env bash

REMOTE_HOST="${CUTTLEFISH_REMOTE_HOST:-justin@100.73.239.5}"
REMOTE_HOME_CACHE="${REMOTE_HOME_CACHE:-}"
HOST_SHORT="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "")"
HOST_FQDN="$(hostname -f 2>/dev/null || echo "")"
GOOGLESOURCE_AVB_TESTKEY_URL="${GOOGLESOURCE_AVB_TESTKEY_URL:-https://android.googlesource.com/platform/external/avb/+/refs/heads/sdk-release/test/data/testkey_rsa4096.pem?format=TEXT}"
REMOTE_FLAKE_DIR_CACHE="${REMOTE_FLAKE_DIR_CACHE:-}"
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)
SSH_RETRIES="${SHADOW_SSH_RETRIES:-3}"
SSH_RETRY_SLEEP="${SHADOW_SSH_RETRY_SLEEP:-2}"

ssh_retry() {
  local status attempt
  status=0
  for attempt in $(seq 1 "$SSH_RETRIES"); do
    if ssh "${SSH_OPTS[@]}" "$@"; then
      return 0
    fi
    status=$?
    if (( attempt == SSH_RETRIES )); then
      return "$status"
    fi
    sleep "$SSH_RETRY_SLEEP"
  done
  return "$status"
}

scp_retry() {
  local status attempt
  status=0
  for attempt in $(seq 1 "$SSH_RETRIES"); do
    if scp "${SSH_OPTS[@]}" -q "$@"; then
      return 0
    fi
    status=$?
    if (( attempt == SSH_RETRIES )); then
      return "$status"
    fi
    sleep "$SSH_RETRY_SLEEP"
  done
  return "$status"
}

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
  if [[ "${SHADOW_BOOTIMG_SHELL:-}" == "1" ]] \
    && command -v adb >/dev/null 2>&1 \
    && command -v just >/dev/null 2>&1 \
    && command -v payload-dumper-go >/dev/null 2>&1; then
    return 0
  fi
  exec env -u SHADOW_BOOTIMG_SHELL nix develop "$(flake_path)" -c "$0" "$@"
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
    ssh_retry "$REMOTE_HOST" /bin/bash -s <<<"$script"
  fi
}

remote_bash() {
  if is_local_host; then
    /bin/bash
  else
    ssh_retry "$REMOTE_HOST" /bin/bash
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
    ssh_retry "$REMOTE_HOST" /bin/bash -lc "$(printf '%q' "$command")"
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
    scp_retry "$src" "${REMOTE_HOST}:$dest"
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
  local instance port pid_file remote_work_dir tombstone_port vsock_id remote_script
  instance="$1"
  port="${2:-$(adb_port_for_instance "$instance")}"
  tombstone_port="$((port + 80))"
  vsock_id="$((instance + 2))"
  pid_file="/var/lib/cuttlefish/instances/${instance}/direct-launch.pid"
  remote_work_dir="$(remote_artifact_dir "$instance")"
  remote_script="$(cat <<EOF
set -euo pipefail
instance="$instance"
port="$port"
tombstone_port="$tombstone_port"
vsock_id="$vsock_id"
pid_file="$pid_file"
if [[ -f "\$pid_file" ]]; then
  pid="\$(sudo -n cat "\$pid_file" 2>/dev/null || true)"
  if [[ -n "\$pid" ]]; then
    pid_args="\$(ps -o args= -p "\$pid" 2>/dev/null || true)"
    if [[ "\$pid_args" == *"/var/lib/cuttlefish/instances/\${instance}/"* || "\$pid_args" == *"/var/lib/cuttlefish/assembly/\${instance}"* || "\$pid_args" == *"cvd-\${instance}"* || "\$pid_args" == *"$remote_work_dir"* ]]; then
      sudo -n pkill -TERM -P "\$pid" >/dev/null 2>&1 || true
      sudo -n kill -TERM "\$pid" >/dev/null 2>&1 || true
      sleep 1
      sudo -n pkill -KILL -P "\$pid" >/dev/null 2>&1 || true
      sudo -n kill -KILL "\$pid" >/dev/null 2>&1 || true
    fi
  fi
fi
for listen_port in "\$port" "\$tombstone_port"; do
  while read -r pid; do
    [[ -n "\$pid" ]] || continue
    parent="\$(ps -o ppid= -p "\$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    grandparent=""
    if [[ -n "\$parent" ]]; then
      grandparent="\$(ps -o ppid= -p "\$parent" 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    for target_pid in "\$pid" "\$parent" "\$grandparent"; do
      [[ -n "\$target_pid" ]] || continue
      comm="\$(ps -o comm= -p "\$target_pid" 2>/dev/null | tr -d '[:space:]' || true)"
      if [[ "\$comm" == socket_vsock* ]]; then
        sudo -n kill -TERM "\$target_pid" >/dev/null 2>&1 || true
      fi
    done
    sleep 1
    for target_pid in "\$pid" "\$parent" "\$grandparent"; do
      [[ -n "\$target_pid" ]] || continue
      comm="\$(ps -o comm= -p "\$target_pid" 2>/dev/null | tr -d '[:space:]' || true)"
      if [[ "\$comm" == socket_vsock* ]]; then
        sudo -n kill -KILL "\$target_pid" >/dev/null 2>&1 || true
      fi
    done
  done < <(
    ps -eo pid=,comm=,args= | awk -v port="\${listen_port}" -v cid="\${vsock_id}" '
      \$2 ~ /^socket_vsock/ &&
      (\$0 ~ ("--server_tcp_port=" port) || \$0 ~ ("--client_tcp_port=" port) || \$0 ~ ("--server_vsock_id=" cid)) {
        print \$1
      }
    ' | sort -u
  )
done
while read -r pid; do
  [[ -n "\$pid" ]] || continue
  sudo -n kill -TERM "\$pid" >/dev/null 2>&1 || true
done < <(
  ps -eo pid=,comm=,args= | awk -v instance="\${instance}" -v workdir="$remote_work_dir" '
    \$2 ~ /^(run_cvd|launch_cvd|assemble_cvd|qemu-system-x86|crosvm|process_sandbox|adb_connector|casimir|wmediumd_contr|kernel_log_moni|log_tee|echo_server)/ &&
    (\$0 ~ ("cvd-" instance "([^0-9]|$)") ||
     \$0 ~ ("/var/lib/cuttlefish/instances/" instance "(/|$)") ||
     \$0 ~ ("/tmp/cf_(avd|env|img)_0/(cvd|env)-" instance "(/|$)") ||
     \$0 ~ workdir) {
      print \$1
    }
  ' | sort -u
)
sleep 1
while read -r pid; do
  [[ -n "\$pid" ]] || continue
  sudo -n kill -KILL "\$pid" >/dev/null 2>&1 || true
done < <(
  ps -eo pid=,comm=,args= | awk -v instance="\${instance}" -v workdir="$remote_work_dir" '
    \$2 ~ /^(run_cvd|launch_cvd|assemble_cvd|qemu-system-x86|crosvm|process_sandbox|adb_connector|casimir|wmediumd_contr|kernel_log_moni|log_tee|echo_server)/ &&
    (\$0 ~ ("cvd-" instance "([^0-9]|$)") ||
     \$0 ~ ("/var/lib/cuttlefish/instances/" instance "(/|$)") ||
     \$0 ~ ("/tmp/cf_(avd|env|img)_0/(cvd|env)-" instance "(/|$)") ||
     \$0 ~ workdir) {
      print \$1
    }
  ' | sort -u
)
sudo -n ip tuntap del mode tap "cvd-mtap-\${instance}" >/dev/null 2>&1 || true
sudo -n ip tuntap del mode tap "cvd-tap-\${instance}" >/dev/null 2>&1 || true
sudo -n ip link del "cvd-eth-\${instance}" >/dev/null 2>&1 || true
sudo -n rm -rf \
  "/var/lib/cuttlefish/instances/\${instance}" \
  "/var/lib/cuttlefish/instances/\${instance}.\${instance}" \
  "/var/lib/cuttlefish/instances/\${instance}_runtime" \
  "/var/lib/cuttlefish/assembly/\${instance}" \
  "/tmp/cf_avd_0/cvd-\${instance}" \
  "/tmp/cf_env_0/env-\${instance}" \
  "/tmp/cf_img_0/cvd-\${instance}" \
  "$remote_work_dir"
while read -r pid; do
  [[ -n "\$pid" ]] || continue
  sudo -n kill -TERM "\$pid" >/dev/null 2>&1 || true
done < <(
  sudo -n lsof -nP +L1 2>/dev/null \
    | awk -v instance="\${instance}" '\$0 ~ ("/var/lib/cuttlefish/instances/" instance "/") { print \$2 }' \
    | sort -u
)
sleep 1
while read -r pid; do
  [[ -n "\$pid" ]] || continue
  sudo -n kill -KILL "\$pid" >/dev/null 2>&1 || true
done < <(
  sudo -n lsof -nP +L1 2>/dev/null \
    | awk -v instance="\${instance}" '\$0 ~ ("/var/lib/cuttlefish/instances/" instance "/") { print \$2 }' \
    | sort -u
)
EOF
)"
  remote_shell "$remote_script"
}

list_remote_instances() {
  remote_shell "$(cat <<'EOF'
set -euo pipefail
{
  sudo -n find /var/lib/cuttlefish/instances -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null || true
  sudo -n find /var/lib/cuttlefish/assembly -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null || true
  sudo -n ps -eo args= 2>/dev/null || true
} | sed -nE \
  -e 's/^([0-9]+)(\.[0-9]+|_runtime)?$/\1/p' \
  -e 's#.*(/var/lib/cuttlefish/(instances|assembly)/)([0-9]+)([/._].*|$)#\3#p' \
  -e 's#.*(/tmp/cf_(avd|env|img)_0/(cvd|env)-)([0-9]+)(/.*|$)#\4#p' \
  -e 's#.*\bcvd-([0-9]+)\b.*#\1#p' \
  | sort -nu
EOF
)"
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
  if [[ -f "\$launcher_log" ]] && grep -Eq 'assemble_cvd failed|Unknown target architecture|main.cc:263 assemble_cvd returned -1|main.cc:297 run_cvd returned -1|Address already in use|Bind failed|Setup failed for cuttlefish::TombstoneReceiver' "\$launcher_log"; then
    tail -n 200 "\$launcher_log" >&2 || true
    exit 2
  fi
  for path in "\$kernel_log" "\$kernel_log_fallback" "\$console_log" "\$launcher_log"; do
    if [[ -f "\$path" ]] && grep -Eq '\[shadow-init\] background payload (launch failed|exited with (exit status: [1-9]|signal: ))' "\$path"; then
      tail -n 200 "\$path" >&2 || true
      exit 2
    fi
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
