#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

BOOT_IMAGE=""
INIT_BOOT_IMAGE=""
WAIT_FOR=""
TIMEOUT_SECS="${CF_WAIT_TIMEOUT:-180}"

usage() {
  cat <<'EOF'
Usage: scripts/cf_launch.sh [options]

Options:
  --boot PATH         Use a local boot.img override.
  --init-boot PATH    Use a local init_boot.img override.
  --wait-for REGEX    Wait for a regex to appear in logs before returning.
  --timeout SECS      Wait timeout when --wait-for is used.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --boot)
      BOOT_IMAGE="${2:?missing value for --boot}"
      shift 2
      ;;
    --init-boot)
      INIT_BOOT_IMAGE="${2:?missing value for --init-boot}"
      shift 2
      ;;
    --wait-for)
      WAIT_FOR="${2:?missing value for --wait-for}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECS="${2:?missing value for --timeout}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "cf_launch: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

INSTANCE="$(deterministic_instance_name "${CUTTLEFISH_INSTANCE_OVERRIDE:-}")"
ADB_PORT="$(adb_port_for_instance "$INSTANCE")"
UUID="$(uuid_for_instance "$INSTANCE")"
REMOTE_INSTANCE_DIR="/var/lib/cuttlefish/instances/$INSTANCE"
REMOTE_ASSEMBLY_DIR="/var/lib/cuttlefish/assembly/$INSTANCE"
REMOTE_WORK_DIR="$(remote_artifact_dir "$INSTANCE")"
REMOTE_BOOT_IMAGE="/var/lib/cuttlefish/images/boot.img"
REMOTE_INIT_BOOT_IMAGE="/var/lib/cuttlefish/images/init_boot.img"
REMOTE_BOOTLOADER="/var/lib/cuttlefish/etc/bootloader_x86_64/bootloader.qemu"
REMOTE_LAUNCHER_LOG="$(launcher_log_path "$INSTANCE")"
REMOTE_PID_FILE="${REMOTE_INSTANCE_DIR}/direct-launch.pid"

record_instance "$INSTANCE"
cleanup_remote_instance "$INSTANCE" "$ADB_PORT"

if [[ -n "$BOOT_IMAGE" ]]; then
  [[ -f "$BOOT_IMAGE" ]] || {
    echo "cf_launch: boot image not found: $BOOT_IMAGE" >&2
    exit 1
  }
  remote_shell "mkdir -p $(printf '%q' "$REMOTE_WORK_DIR")"
  REMOTE_BOOT_IMAGE="${REMOTE_WORK_DIR}/boot.img"
  copy_to_remote "$BOOT_IMAGE" "$REMOTE_BOOT_IMAGE"
fi

if [[ -n "$INIT_BOOT_IMAGE" ]]; then
  [[ -f "$INIT_BOOT_IMAGE" ]] || {
    echo "cf_launch: init_boot image not found: $INIT_BOOT_IMAGE" >&2
    exit 1
  }
  remote_shell "mkdir -p $(printf '%q' "$REMOTE_WORK_DIR")"
  REMOTE_INIT_BOOT_IMAGE="${REMOTE_WORK_DIR}/init_boot.img"
  copy_to_remote "$INIT_BOOT_IMAGE" "$REMOTE_INIT_BOOT_IMAGE"
fi

printf 'Launching cuttlefish instance %s on %s\n' "$INSTANCE" "$REMOTE_HOST"
printf '  adb: 127.0.0.1:%s\n' "$ADB_PORT"
printf '  boot: %s\n' "$REMOTE_BOOT_IMAGE"
printf '  init_boot: %s\n' "$REMOTE_INIT_BOOT_IMAGE"

remote_bash <<EOF
set -euo pipefail
instance="$INSTANCE"
adb_port="$ADB_PORT"
uuid="$UUID"
instance_dir="$REMOTE_INSTANCE_DIR"
assembly_dir="$REMOTE_ASSEMBLY_DIR"
launcher_log="$REMOTE_LAUNCHER_LOG"
pid_file="$REMOTE_PID_FILE"
boot_image="$REMOTE_BOOT_IMAGE"
init_boot_image="$REMOTE_INIT_BOOT_IMAGE"
bootloader="$REMOTE_BOOTLOADER"
sudo install -d -m 0775 -o root -g cvdnetwork "\$instance_dir" "\$assembly_dir"
cd /var/lib/cuttlefish/instances
nohup sudo -u root -g root env \
  CUTTLEFISH_INSTANCE="\$instance" \
  CUTTLEFISH_INSTANCE_NUM="\$instance" \
  CUTTLEFISH_ADB_TCP_PORT="\$adb_port" \
  CUTTLEFISH_DISABLE_HOST_GPU=1 \
  GFXSTREAM_DISABLE_GRAPHICS_DETECTOR=1 \
  GFXSTREAM_HEADLESS=1 \
  /run/current-system/sw/bin/cuttlefish-fhs -- launch_cvd \
    --system_image_dir=/var/lib/cuttlefish/images \
    --instance_dir="\$instance_dir" \
    --assembly_dir="\$assembly_dir" \
    --uuid="\$uuid" \
    --vm_manager=qemu_cli \
    --enable_wifi=false \
    --enable_host_bluetooth=false \
    --enable_modem_simulator=false \
    --start_webrtc=false \
    --start_webrtc_sig_server=false \
    --report_anonymous_usage_stats=n \
    --daemon=false \
    --console=true \
    --extra_kernel_cmdline=console=ttyS0,115200 \
    --verbosity=DEBUG \
    --resume=false \
    --boot_image="\$boot_image" \
    --init_boot_image="\$init_boot_image" \
    --bootloader="\$bootloader" \
    >"\$launcher_log" 2>&1 </dev/null &
echo \$! | sudo tee "\$pid_file" >/dev/null
EOF

if [[ -n "$WAIT_FOR" ]]; then
  printf 'Waiting for pattern: %s\n' "$WAIT_FOR"
  wait_for_remote_pattern "$INSTANCE" "$WAIT_FOR" "$TIMEOUT_SECS"
  printf 'Pattern observed for instance %s\n' "$INSTANCE"
else
  printf 'Launch requested for instance %s\n' "$INSTANCE"
fi
