#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

KEEP_IDS="${SHADOW_CF_PRUNE_KEEP:-}"

usage() {
  cat <<'EOF'
Usage: scripts/cf_prune.sh [--keep ID[,ID...]]

Kill and remove stale Cuttlefish instances on the remote host.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)
      KEEP_IDS="${2:?missing value for --keep}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "cf_prune: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

should_keep() {
  local candidate keep_list keep
  candidate="$1"
  keep_list="$2"
  IFS=',' read -r -a keep <<<"$keep_list"
  for item in "${keep[@]}"; do
    [[ -n "$item" ]] || continue
    if [[ "$candidate" == "$item" ]]; then
      return 0
    fi
  done
  return 1
}

force_prune_all() {
  remote_shell "$(cat <<'EOF'
set -euo pipefail
while read -r pid; do
  [[ -n "$pid" ]] || continue
  sudo kill -TERM "$pid" >/dev/null 2>&1 || true
done < <(
  ps -eo pid=,comm=,args= \
    | grep -E ' (run_cvd|launch_cvd|assemble_cvd|qemu-system-x86|adb_connector|socket_vsock_pr|process_sandbox|tombstone_recei|cf_vhost_user_i|screen_recordin|control_env_pro|gnss_grpc_proxy|log_tee|kernel_log_moni|wmediumd_contr|echo_server|casimir) ' \
    | grep -E '/var/lib/cuttlefish/|/tmp/cf_avd_0/|/tmp/cf_env_0/|/tmp/cf_img_0/' \
    | awk '{print $1}' \
    | sort -u
)
sleep 2
while read -r pid; do
  [[ -n "$pid" ]] || continue
  sudo kill -KILL "$pid" >/dev/null 2>&1 || true
done < <(
  ps -eo pid=,comm=,args= \
    | grep -E ' (run_cvd|launch_cvd|assemble_cvd|qemu-system-x86|adb_connector|socket_vsock_pr|process_sandbox|tombstone_recei|cf_vhost_user_i|screen_recordin|control_env_pro|gnss_grpc_proxy|log_tee|kernel_log_moni|wmediumd_contr|echo_server|casimir) ' \
    | grep -E '/var/lib/cuttlefish/|/tmp/cf_avd_0/|/tmp/cf_env_0/|/tmp/cf_img_0/' \
    | awk '{print $1}' \
    | sort -u
)
sudo rm -rf /var/lib/cuttlefish/instances/* /var/lib/cuttlefish/assembly/* /tmp/cf_avd_0/* /tmp/cf_env_0/* /tmp/cf_img_0/* "$HOME"/cuttlefish-instances/*
while read -r pid; do
  [[ -n "$pid" ]] || continue
  sudo kill -TERM "$pid" >/dev/null 2>&1 || true
done < <(
  sudo lsof -nP +L1 2>/dev/null \
    | awk '/\/var\/lib\/cuttlefish\/instances\/[0-9]+\// { print $2 }' \
    | sort -u
)
sleep 1
while read -r pid; do
  [[ -n "$pid" ]] || continue
  sudo kill -KILL "$pid" >/dev/null 2>&1 || true
done < <(
  sudo lsof -nP +L1 2>/dev/null \
    | awk '/\/var\/lib\/cuttlefish\/instances\/[0-9]+\// { print $2 }' \
    | sort -u
)
EOF
)"
}

main() {
  local ids id

  if [[ -z "${KEEP_IDS//[[:space:]]/}" ]]; then
    echo "Force pruning all remote cuttlefish state on $REMOTE_HOST"
    force_prune_all
    return 0
  fi

  ids="$(list_remote_instances)"

  if [[ -z "${ids//[[:space:]]/}" ]]; then
    echo "No remote cuttlefish instances to prune on $REMOTE_HOST"
    return 0
  fi

  while read -r id; do
    [[ -n "$id" ]] || continue
    if should_keep "$id" "$KEEP_IDS"; then
      printf 'Keeping cuttlefish instance %s on %s\n' "$id" "$REMOTE_HOST"
      continue
    fi
    printf 'Pruning cuttlefish instance %s on %s\n' "$id" "$REMOTE_HOST"
    cleanup_remote_instance "$id"
  done <<<"$ids"
}

main "$@"
