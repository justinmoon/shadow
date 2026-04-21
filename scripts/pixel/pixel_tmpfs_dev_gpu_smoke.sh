#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs

original_args=("$@")
primary_control_serial="${PIXEL_GPU_TMPFS_DEV_PRIMARY_SERIAL:-11151JEC200472}"
profile="${PIXEL_GPU_TMPFS_DEV_PROFILE:-dri+kgsl}"
scene="${PIXEL_GPU_TMPFS_DEV_SCENE:-raw-vulkan-physical-device-count-query-exit-smoke}"
run_root="$(pixel_runs_dir)/gpu-smoke-devtmpfs"
run_dir="${PIXEL_GPU_TMPFS_DEV_RUN_DIR-}"
device_dir="${PIXEL_GPU_TMPFS_DEV_DEVICE_DIR:-/data/local/tmp/shadow-gpu-smoke-devtmpfs}"
extra_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      profile="${2:?pixel_tmpfs_dev_gpu_smoke: --profile requires a value}"
      shift 2
      ;;
    --profile=*)
      profile="${1#*=}"
      shift
      ;;
    --scene)
      scene="${2:?pixel_tmpfs_dev_gpu_smoke: --scene requires a value}"
      shift 2
      ;;
    --scene=*)
      scene="${1#*=}"
      shift
      ;;
    --)
      shift
      extra_args+=("$@")
      break
      ;;
    *)
      extra_args+=("$1")
      shift
      ;;
  esac
done

resolve_tmpfs_dev_serial() {
  if [[ -n "${PIXEL_SERIAL:-}" ]]; then
    pixel_resolve_serial
    return 0
  fi

  if pixel_connected_serials | grep -Fxq "$primary_control_serial"; then
    printf '%s\n' "$primary_control_serial"
    return 0
  fi

  pixel_resolve_serial
}

serial="$(resolve_tmpfs_dev_serial)"
pixel_adb "$serial" get-state >/dev/null
pixel_require_host_lock "$serial" "$0" "${original_args[@]}"

if [[ -z "$run_dir" ]]; then
  run_dir="$(pixel_prepare_named_run_dir "$run_root")"
else
  mkdir -p "$run_dir"
fi

profile_slug="$(printf '%s' "$profile" | tr -c 'A-Za-z0-9._-' '_')"
device_summary_path="$device_dir/summary.json"
device_profile_path="$device_dir/dev-profile.tsv"
device_launcher_path="$device_dir/run-shadow-gpu-smoke"
device_preload_path="$device_dir/lib/shadow-openlog-preload.so"
device_binary_path="$device_dir/shadow-gpu-smoke"
device_home_path="$device_dir/home"
prepare_output_path="$run_dir/prepare-output.json"
preload_build_output_path="$run_dir/preload-build.txt"
device_command_path="$run_dir/device-command.sh"
device_output_path="$run_dir/device-output.txt"
checkpoint_log_path="$run_dir/checkpoints.txt"
pull_summary_log_path="$run_dir/pull-summary.txt"
pull_profile_log_path="$run_dir/pull-dev-profile.txt"
kgsl_holder_scan_path="$run_dir/kgsl-holder-scan.tsv"
kgsl_holder_scan_stderr_path="$run_dir/kgsl-holder-scan.stderr.txt"
status_path="$run_dir/status.json"
summary_path="$run_dir/summary.json"
profile_path="$run_dir/dev-profile.tsv"
summary_expected=true

if [[ "$scene" == "raw-vulkan-physical-device-count-query-exit-smoke" ]]; then
  summary_expected=false
fi

require_safe_device_dir() {
  local path="$1"
  case "$path" in
    /data/local/tmp/shadow-gpu-smoke-devtmpfs* )
      ;;
    * )
      echo "pixel_tmpfs_dev_gpu_smoke: unsafe PIXEL_GPU_TMPFS_DEV_DEVICE_DIR: $path" >&2
      echo "expected a path under /data/local/tmp/shadow-gpu-smoke-devtmpfs*" >&2
      return 1
      ;;
  esac

  if [[ "$path" == "/data/local/tmp" || "$path" == "/data/local/tmp/" ]]; then
    echo "pixel_tmpfs_dev_gpu_smoke: refusing unsafe device dir root: $path" >&2
    return 1
  fi
}

quote_args() {
  local quoted=()
  local arg
  for arg in "$@"; do
    quoted+=("$(printf '%q' "$arg")")
  done
  printf '%s' "${quoted[*]}"
}

profile_node_sources_for() {
  case "$1" in
    dri+kgsl)
      printf '%s\n' \
        /dev/kgsl-3d0 \
        /dev/dri/card0 \
        /dev/dri/renderD128
      ;;
    dri+kgsl+ion)
      printf '%s\n' \
        /dev/kgsl-3d0 \
        /dev/dri/card0 \
        /dev/dri/renderD128 \
        /dev/ion
      ;;
    *)
      echo "pixel_tmpfs_dev_gpu_smoke: unsupported profile: $1" >&2
      echo "supported profiles: dri+kgsl, dri+kgsl+ion" >&2
      return 1
      ;;
  esac
}

baseline_node_sources=(
  /dev/null
)
optional_baseline_node_sources=(
  /dev/zero
  /dev/full
  /dev/random
  /dev/urandom
  /dev/tty
)
dir_sources=(
  /dev
)
profile_node_sources=()
profile_includes_ion=false
while IFS= read -r source_path; do
  [[ -n "$source_path" ]] || continue
  profile_node_sources+=("$source_path")
done < <(profile_node_sources_for "$profile")

for source_path in "${profile_node_sources[@]}"; do
  if [[ "$source_path" == /dev/dri/* ]]; then
    dir_sources+=(/dev/dri)
    break
  fi
done

if [[ "$profile" == *ion* ]]; then
  profile_includes_ion=true
fi

device_nodes_requested=("${baseline_node_sources[@]}" "${profile_node_sources[@]}")
baseline_nodes_csv="$(IFS=,; printf '%s' "${baseline_node_sources[*]}")"
profile_nodes_csv="$(IFS=,; printf '%s' "${profile_node_sources[*]}")"

printf '[tmpfs-dev] serial=%s\n' "$serial" | tee -a "$checkpoint_log_path"
printf '[tmpfs-dev] primary_control_serial=%s\n' "$primary_control_serial" | tee -a "$checkpoint_log_path"
printf '[tmpfs-dev] run_dir=%s\n' "$run_dir" | tee -a "$checkpoint_log_path"
printf '[tmpfs-dev] device_dir=%s\n' "$device_dir" | tee -a "$checkpoint_log_path"
printf '[tmpfs-dev] profile=%s scene=%s\n' "$profile" "$scene" | tee -a "$checkpoint_log_path"

require_safe_device_dir "$device_dir"

PIXEL_GPU_SMOKE_DEVICE_DIR="$device_dir" \
  "$SCRIPT_DIR/pixel/pixel_prepare_gpu_smoke_bundle.sh" >"$prepare_output_path"
"$SCRIPT_DIR/pixel/pixel_build_openlog_preload.sh" >"$preload_build_output_path" 2>&1

bundle_dir="$(pixel_artifact_path shadow-gpu-smoke-gnu)"
launcher_artifact="$(pixel_artifact_path run-shadow-gpu-smoke)"
openlog_artifact="$(pixel_artifact_path shadow-openlog-preload.so)"
if [[ ! -d "$bundle_dir" || ! -x "$launcher_artifact" ]]; then
  echo "pixel_tmpfs_dev_gpu_smoke: missing prepared gpu-smoke bundle artifacts" >&2
  exit 1
fi
if [[ ! -f "$openlog_artifact" ]]; then
  echo "pixel_tmpfs_dev_gpu_smoke: missing openlog preload artifact: $openlog_artifact" >&2
  exit 1
fi

pixel_root_shell "$serial" "
set -e
rm -rf '$device_dir'
" >/dev/null

pixel_adb "$serial" shell "
set -e
mkdir -p '$device_dir'
" >/dev/null

pixel_adb "$serial" push "$bundle_dir/." "$device_dir/" >/dev/null
pixel_adb "$serial" push "$launcher_artifact" "$device_launcher_path" >/dev/null
pixel_adb "$serial" push "$openlog_artifact" "$device_preload_path" >/dev/null

device_args=(
  --scene "$scene"
  --summary-path "$device_summary_path"
)
if [[ "${#extra_args[@]}" -gt 0 ]]; then
  device_args+=("${extra_args[@]}")
fi

cat >"$device_command_path" <<EOF
set -eu

DEVICE_DIR=$(printf '%q' "$device_dir")
DEVICE_SUMMARY_PATH=$(printf '%q' "$device_summary_path")
DEVICE_PROFILE_PATH=$(printf '%q' "$device_profile_path")
DEVICE_PRELOAD_PATH=$(printf '%q' "$device_preload_path")
DEVICE_BINARY_PATH=$(printf '%q' "$device_binary_path")
DEVICE_LAUNCHER_PATH=$(printf '%q' "$device_launcher_path")
DEVICE_HOME_PATH=$(printf '%q' "$device_home_path")
DEVICE_LIB_DIR=$(printf '%q' "$device_dir/lib")
DEVICE_VULKAN_ICD_PATH=$(printf '%q' "$device_dir/share/vulkan/icd.d/freedreno_icd.aarch64.json")
PROFILE=$(printf '%q' "$profile")
SCENE=$(printf '%q' "$scene")

require_command() {
  command -v "\$1" >/dev/null 2>&1 || {
    echo "[tmpfs-dev] missing-command=\$1" >&2
    exit 127
  }
}

append_dir_spec() {
  local source_path spec
  source_path="\$1"
  spec="\$(toybox stat -c 'dir|%a|%u|%g|-|-|%n' "\$source_path")" || {
    echo "[tmpfs-dev] missing-dir-source=\$source_path" >&2
    exit 1
  }
  printf '%s\n' "\$spec" >>"\$DEVICE_PROFILE_PATH"
  echo "[tmpfs-dev] captured-dir source=\$source_path"
}

append_char_spec() {
  local source_path spec
  source_path="\$1"
  spec="\$(toybox stat -c 'char|%a|%u|%g|%t|%T|%n' "\$source_path")" || {
    echo "[tmpfs-dev] missing-node-source=\$source_path" >&2
    exit 1
  }
  printf '%s\n' "\$spec" >>"\$DEVICE_PROFILE_PATH"
  echo "[tmpfs-dev] captured-node source=\$source_path"
}

append_optional_char_spec() {
  local source_path spec
  source_path="\$1"
  spec="\$(toybox stat -c 'char|%a|%u|%g|%t|%T|%n' "\$source_path" 2>/dev/null)" || {
    echo "[tmpfs-dev] skipped-optional-node source=\$source_path"
    return 0
  }
  printf '%s\n' "\$spec" >>"\$DEVICE_PROFILE_PATH"
  echo "[tmpfs-dev] captured-optional-node source=\$source_path"
}

append_symlink_spec() {
  local link_path link_target
  link_path="\$1"
  link_target="\$2"
  printf 'symlink|-|-|-|-|-|%s|%s\n' "\$link_path" "\$link_target" >>"\$DEVICE_PROFILE_PATH"
  echo "[tmpfs-dev] planned-symlink path=\$link_path target=\$link_target"
}

require_command toybox
require_command unshare
require_command mount
require_command chmod
require_command chown
require_command mknod
require_command mkdir
require_command ln
require_command find

rm -f "\$DEVICE_SUMMARY_PATH" "\$DEVICE_PROFILE_PATH"
mkdir -p "\$DEVICE_DIR"
: >"\$DEVICE_PROFILE_PATH"

while IFS= read -r source_path; do
  [ -n "\$source_path" ] || continue
  append_dir_spec "\$source_path"
done <<'TMPFS_DEV_DIRS'
$(printf '%s\n' "${dir_sources[@]}")
TMPFS_DEV_DIRS

while IFS= read -r source_path; do
  [ -n "\$source_path" ] || continue
  append_char_spec "\$source_path"
done <<'TMPFS_DEV_NODES'
$(printf '%s\n' "${device_nodes_requested[@]}")
TMPFS_DEV_NODES

while IFS= read -r source_path; do
  [ -n "\$source_path" ] || continue
  append_optional_char_spec "\$source_path"
done <<'TMPFS_DEV_OPTIONAL_NODES'
$(printf '%s\n' "${optional_baseline_node_sources[@]}")
TMPFS_DEV_OPTIONAL_NODES

append_symlink_spec /dev/fd /proc/self/fd
append_symlink_spec /dev/stdin /proc/self/fd/0
append_symlink_spec /dev/stdout /proc/self/fd/1
append_symlink_spec /dev/stderr /proc/self/fd/2

find "\$DEVICE_LIB_DIR" -maxdepth 1 -type f -name 'ld-linux-*' -exec chmod 0755 {} +
chmod 0755 "\$DEVICE_BINARY_PATH" "\$DEVICE_LAUNCHER_PATH" "\$DEVICE_PRELOAD_PATH"

echo "[tmpfs-dev] profile=\$PROFILE scene=\$SCENE"
echo "[tmpfs-dev] namespace-launch=1"

export \
  DEVICE_DIR \
  DEVICE_SUMMARY_PATH \
  DEVICE_PROFILE_PATH \
  DEVICE_PRELOAD_PATH \
  DEVICE_BINARY_PATH \
  DEVICE_LAUNCHER_PATH \
  DEVICE_HOME_PATH \
  DEVICE_LIB_DIR \
  DEVICE_VULKAN_ICD_PATH \
  PROFILE \
  SCENE

set +e
unshare -m /system/bin/sh <<'TMPFS_DEV_NAMESPACE'
set -eu

apply_dir_spec() {
  local target_path mode uid gid
  target_path="\$1"
  mode="\$2"
  uid="\$3"
  gid="\$4"

  if [ "\$target_path" != "/dev" ]; then
    mkdir -p "\$target_path"
  fi
  chmod "\$mode" "\$target_path"
  chown "\$uid:\$gid" "\$target_path"
}

apply_char_spec() {
  local target_path mode uid gid major_hex minor_hex
  target_path="\$1"
  mode="\$2"
  uid="\$3"
  gid="\$4"
  major_hex="\$5"
  minor_hex="\$6"

  rm -f "\$target_path"
  mknod "\$target_path" c \$((0x\$major_hex)) \$((0x\$minor_hex))
  chmod "\$mode" "\$target_path"
  chown "\$uid:\$gid" "\$target_path"
}

apply_symlink_spec() {
  local link_path link_target
  link_path="\$1"
  link_target="\$2"
  rm -f "\$link_path"
  ln -s "\$link_target" "\$link_path"
}

echo "[tmpfs-dev] namespace-entered=1"
mount -t tmpfs tmpfs /dev
echo "[tmpfs-dev] tmpfs-mounted=1"

while IFS='|' read -r kind mode uid gid major_hex minor_hex path target; do
  [ -n "\$kind" ] || continue
  case "\$kind" in
    dir)
      apply_dir_spec "\$path" "\$mode" "\$uid" "\$gid"
      echo "[tmpfs-dev] dir-ready path=\$path mode=\$mode uid=\$uid gid=\$gid"
      ;;
    char)
      apply_char_spec "\$path" "\$mode" "\$uid" "\$gid" "\$major_hex" "\$minor_hex"
      echo "[tmpfs-dev] node-ready path=\$path mode=\$mode uid=\$uid gid=\$gid major=\$major_hex minor=\$minor_hex"
      ;;
    symlink)
      apply_symlink_spec "\$path" "\$target"
      echo "[tmpfs-dev] symlink-ready path=\$path target=\$target"
      ;;
    *)
      echo "[tmpfs-dev] unexpected-profile-entry=\$kind" >&2
      exit 1
      ;;
  esac
done <"\$DEVICE_PROFILE_PATH"

mkdir -p "\$DEVICE_HOME_PATH" "\$DEVICE_HOME_PATH/.cache" "\$DEVICE_HOME_PATH/.config" "\$DEVICE_HOME_PATH/.cache/mesa"
loader_path="\$(find "\$DEVICE_LIB_DIR" -maxdepth 1 -type f -name 'ld-linux-*' | head -n 1)"
if [ -z "\$loader_path" ]; then
  echo "[tmpfs-dev] missing-loader=1" >&2
  exit 1
fi

echo "[tmpfs-dev] exec loader=\$loader_path preload=\$DEVICE_PRELOAD_PATH"
exec env \
  LD_PRELOAD="\$DEVICE_PRELOAD_PATH" \
  HOME="\$DEVICE_HOME_PATH" \
  XDG_CACHE_HOME="\$DEVICE_HOME_PATH/.cache" \
  XDG_CONFIG_HOME="\$DEVICE_HOME_PATH/.config" \
  MESA_SHADER_CACHE_DIR="\$DEVICE_HOME_PATH/.cache/mesa" \
  LD_LIBRARY_PATH="\$DEVICE_LIB_DIR" \
  WGPU_BACKEND=vulkan \
  VK_ICD_FILENAMES="\$DEVICE_VULKAN_ICD_PATH" \
  MESA_LOADER_DRIVER_OVERRIDE=kgsl \
  TU_DEBUG=noconform \
  "\$loader_path" --library-path "\$DEVICE_LIB_DIR" "\$DEVICE_BINARY_PATH" $(quote_args "${device_args[@]}")
TMPFS_DEV_NAMESPACE
run_status="\$?"
set -e

echo "[tmpfs-dev] run-status=\$run_status"
exit "\$run_status"
EOF

set +e
pixel_root_shell "$serial" "$(cat "$device_command_path")" >"$device_output_path" 2>&1
run_status="$?"
set -e

summary_pulled=false
profile_pulled=false
if pixel_root_shell "$serial" "
set -e
if [ -f '$device_summary_path' ]; then
  chmod 0644 '$device_summary_path'
fi
if [ -f '$device_profile_path' ]; then
  chmod 0644 '$device_profile_path'
fi
" >/dev/null; then
  :
fi

if pixel_adb "$serial" shell "[ -f '$device_summary_path' ]" >/dev/null 2>&1; then
  pixel_adb "$serial" pull "$device_summary_path" "$summary_path" >"$pull_summary_log_path" 2>&1
  summary_pulled=true
else
  printf 'missing: %s\n' "$device_summary_path" >"$pull_summary_log_path"
fi

if pixel_adb "$serial" shell "[ -f '$device_profile_path' ]" >/dev/null 2>&1; then
  pixel_adb "$serial" pull "$device_profile_path" "$profile_path" >"$pull_profile_log_path" 2>&1
  profile_pulled=true
else
  printf 'missing: %s\n' "$device_profile_path" >"$pull_profile_log_path"
fi

set +e
pixel_root_shell "$serial" "$(pixel_kgsl_holder_scan_command)" >"$kgsl_holder_scan_path" 2>"$kgsl_holder_scan_stderr_path"
kgsl_holder_scan_exit_code="$?"
set -e

python3 - "$status_path" "$serial" "$primary_control_serial" "$profile" "$scene" "$device_dir" "$run_status" "$summary_expected" "$summary_pulled" "$profile_pulled" "$profile_includes_ion" "$device_output_path" "$summary_path" "$profile_path" "$prepare_output_path" "$preload_build_output_path" "$baseline_nodes_csv" "$profile_nodes_csv" "$kgsl_holder_scan_path" "$kgsl_holder_scan_stderr_path" "$kgsl_holder_scan_exit_code" <<'PY'
import json
import re
import sys
from pathlib import Path

(
    status_path,
    serial,
    primary_control_serial,
    profile,
    scene,
    device_dir,
    run_status_raw,
    summary_expected_raw,
    summary_pulled_raw,
    profile_pulled_raw,
    profile_includes_ion_raw,
    device_output_path_raw,
    summary_path_raw,
    profile_path_raw,
    prepare_output_path_raw,
    preload_build_output_path_raw,
    baseline_nodes_csv,
    profile_nodes_csv,
    kgsl_holder_scan_path_raw,
    kgsl_holder_scan_stderr_path_raw,
    kgsl_holder_scan_exit_code_raw,
) = sys.argv[1:22]

run_status = int(run_status_raw)
summary_expected = summary_expected_raw == "true"
summary_pulled = summary_pulled_raw == "true"
profile_pulled = profile_pulled_raw == "true"
profile_includes_ion = profile_includes_ion_raw == "true"
device_output_path = Path(device_output_path_raw)
summary_path = Path(summary_path_raw)
profile_path = Path(profile_path_raw)
kgsl_holder_scan_path = Path(kgsl_holder_scan_path_raw)
kgsl_holder_scan_stderr_path = Path(kgsl_holder_scan_stderr_path_raw)
kgsl_holder_scan_exit_code = int(kgsl_holder_scan_exit_code_raw)

device_output = ""
if device_output_path.is_file():
    device_output = device_output_path.read_text(encoding="utf-8", errors="replace")
openlog_lines = [
    line for line in device_output.splitlines()
    if "[shadow-openlog]" in line
]

summary_payload = None
summary_error = None
if summary_path.is_file():
    try:
        summary_payload = json.loads(summary_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        summary_error = f"invalid summary json: {exc}"
elif summary_expected:
    summary_error = "missing pulled summary.json"

profile_entries = []
if profile_path.is_file():
    for raw_line in profile_path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split("|")
        entry = {
            "kind": parts[0],
            "path": parts[6] if len(parts) > 6 else None,
            "target": parts[7] if len(parts) > 7 else None,
            "mode": parts[1] if len(parts) > 1 else None,
            "uid": parts[2] if len(parts) > 2 else None,
            "gid": parts[3] if len(parts) > 3 else None,
            "major_hex": parts[4] if len(parts) > 4 else None,
            "minor_hex": parts[5] if len(parts) > 5 else None,
        }
        profile_entries.append(entry)

def csv_list(raw: str):
    return [item for item in raw.split(",") if item]

def parse_kgsl_holder_scan(path: Path):
    parsed = {
        "format": None,
        "device_path": None,
        "max_fd_checks": None,
        "max_holders": None,
        "pid_count": None,
        "fd_checks": None,
        "holder_count": 0,
        "has_holders": False,
        "truncated": None,
        "holders": [],
        "parse_error": None,
    }
    if not path.is_file():
        return parsed

    try:
        for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if not raw_line:
                continue
            parts = raw_line.split("\t")
            kind = parts[0]
            if kind == "format" and len(parts) >= 2:
                parsed["format"] = parts[1]
            elif kind == "device_path" and len(parts) >= 2:
                parsed["device_path"] = parts[1]
            elif kind == "limits" and len(parts) >= 3:
                parsed["max_fd_checks"] = int(parts[1])
                parsed["max_holders"] = int(parts[2])
            elif kind == "holder" and len(parts) >= 5:
                parsed["holders"].append(
                    {
                        "pid": int(parts[1]),
                        "fd": int(parts[2]),
                        "comm": parts[3],
                        "cmdline": parts[4],
                    }
                )
            elif kind == "summary" and len(parts) >= 5:
                parsed["pid_count"] = int(parts[1])
                parsed["fd_checks"] = int(parts[2])
                parsed["holder_count"] = int(parts[3])
                parsed["truncated"] = parts[4] == "true"
    except (OSError, ValueError) as exc:
        parsed["parse_error"] = str(exc)

    if parsed["holder_count"] == 0 and parsed["holders"]:
        parsed["holder_count"] = len(parsed["holders"])
    parsed["has_holders"] = parsed["holder_count"] > 0
    return parsed

baseline_nodes = csv_list(baseline_nodes_csv)
profile_nodes = csv_list(profile_nodes_csv)
profile_paths = {entry["path"] for entry in profile_entries if entry.get("path")}
kgsl_holder_scan = parse_kgsl_holder_scan(kgsl_holder_scan_path)

physical_device_count = None
match = re.search(r"count-query-ok count=(\d+)", device_output)
if match:
    physical_device_count = int(match.group(1))

is_primary_control_serial = serial == primary_control_serial
tmpfs_dev_control_succeeded = (
    is_primary_control_serial
    and run_status == 0
    and "vkEnumeratePhysicalDevices-count-query-ok" in device_output
    and physical_device_count is not None
)

if tmpfs_dev_control_succeeded:
    dev_blocker_interpretation = (
        "Primary rooted raw-ash control succeeded inside a tmpfs-backed /dev, so missing "
        "/dev nodes are probably not the active blocker for boot-owned physical-device enumeration "
        "on this control device."
    )
    dev_blocker_likely = False
else:
    dev_blocker_interpretation = (
        "No successful tmpfs-/dev control run on the primary rooted raw-ash device yet; do not "
        "draw a /dev-blocker conclusion from this run alone."
    )
    dev_blocker_likely = None

payload = {
    "serial": serial,
    "primary_control_serial": primary_control_serial,
    "is_primary_control_serial": is_primary_control_serial,
    "profile": profile,
    "scene": scene,
    "device_dir": device_dir,
    "run_status": run_status,
    "run_succeeded": run_status == 0 and (summary_pulled or not summary_expected),
    "summary_expected": summary_expected,
    "summary_pulled": summary_pulled,
    "summary_path": str(summary_path) if summary_path.is_file() else None,
    "summary_error": summary_error,
    "summary": summary_payload,
    "device_profile_pulled": profile_pulled,
    "device_profile_path": str(profile_path) if profile_path.is_file() else None,
    "device_profile_entry_count": len(profile_entries),
    "device_profile_paths": sorted(profile_paths),
    "requested_baseline_nodes": baseline_nodes,
    "requested_profile_nodes": profile_nodes,
    "requested_profile_includes_ion": profile_includes_ion,
    "requested_profile_nodes_present": all(path in profile_paths for path in profile_nodes),
    "namespace_entered": "[tmpfs-dev] namespace-entered=1" in device_output,
    "tmpfs_mounted": "[tmpfs-dev] tmpfs-mounted=1" in device_output,
    "loader_found": "[tmpfs-dev] missing-loader=1" not in device_output,
    "openlog_seen": bool(openlog_lines),
    "openlog_has_dri": any("/dev/dri" in line for line in openlog_lines),
    "openlog_has_kgsl": any("/dev/kgsl" in line for line in openlog_lines),
    "openlog_has_ion": any("/dev/ion" in line for line in openlog_lines),
    "openlog_has_ioctl": any(" ioctl " in line for line in openlog_lines),
    "vk_count_query_started": "vkEnumeratePhysicalDevices-count-query" in device_output,
    "vk_count_query_ok": "vkEnumeratePhysicalDevices-count-query-ok" in device_output,
    "physical_device_count": physical_device_count,
    "ion_omitted_but_probe_succeeded": (not profile_includes_ion) and run_status == 0 and physical_device_count is not None,
    "tmpfs_dev_control_succeeded": tmpfs_dev_control_succeeded,
    "dev_blocker_likely": dev_blocker_likely,
    "dev_blocker_interpretation": dev_blocker_interpretation,
    "device_output_path": str(device_output_path),
    "prepare_output_path": prepare_output_path_raw,
    "preload_build_output_path": preload_build_output_path_raw,
    "kgsl_holder_scan": {
        "requested_access_mode": "root",
        "actual_access_mode": "root" if kgsl_holder_scan_exit_code == 0 else "root-error",
        "exit_code": kgsl_holder_scan_exit_code,
        "output_path": str(kgsl_holder_scan_path) if kgsl_holder_scan_path.exists() else None,
        "stderr_path": (
            str(kgsl_holder_scan_stderr_path) if kgsl_holder_scan_stderr_path.exists() else None
        ),
        **kgsl_holder_scan,
    },
}

Path(status_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

if [[ "$run_status" -ne 0 ]]; then
  echo "pixel_tmpfs_dev_gpu_smoke: device run failed; see $device_output_path" >&2
  exit "$run_status"
fi

if [[ "$summary_expected" == true && "$summary_pulled" != true ]]; then
  echo "pixel_tmpfs_dev_gpu_smoke: expected a summary but did not pull one; see $status_path" >&2
  exit 1
fi

cat "$status_path"
