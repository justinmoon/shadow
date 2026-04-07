#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs

probe_root="$(pixel_dir)/gpu-probe"
probe_dir="$(pixel_prepare_named_run_dir "$probe_root")"
profiles_raw="${PIXEL_STATIC_GPU_PROFILES-}"

if [[ -z "$profiles_raw" ]]; then
  if [[ -n "${PIXEL_STATIC_GPU_PROFILE-}" ]]; then
    profiles_raw="${PIXEL_STATIC_GPU_PROFILE}"
  else
    profiles_raw=$'gl\nvulkan_drm\nvulkan_kgsl_first'
  fi
fi

mapfile -t profiles < <(printf '%s\n' "$profiles_raw" | tr ' ' '\n' | sed '/^[[:space:]]*$/d')
if [[ "${#profiles[@]}" -eq 0 ]]; then
  echo "pixel_blitz_demo_static_drm_gpu_probe: no profiles selected" >&2
  exit 1
fi

"$SCRIPT_DIR/pixel_prepare_blitz_demo_gpu_softbuffer_bundle.sh"

case_guest_env() {
  local profile="$1"
  local base_profile="$profile"

  if [[ "$profile" == *_early_probe ]]; then
    base_profile="${profile%_early_probe}"
    printf '%s\n' \
      'SHADOW_BLITZ_GPU_SUMMARY=1' \
      'SHADOW_BLITZ_GPU_PROBE=1'
  fi

  case "$base_profile" in
    gl)
      printf '%s\n' \
        'WGPU_BACKEND=gl' \
        "SHADOW_LINUX_LD_PRELOAD=$(pixel_runtime_linux_dir)/lib/shadow-openlog-preload.so"
      ;;
    vulkan_drm)
      printf '%s\n' \
        'WGPU_BACKEND=vulkan' \
        "SHADOW_LINUX_LD_PRELOAD=$(pixel_runtime_linux_dir)/lib/shadow-openlog-preload.so"
      ;;
    vulkan_kgsl_first)
      printf '%s\n' \
        'WGPU_BACKEND=vulkan' \
        'MESA_LOADER_DRIVER_OVERRIDE=kgsl' \
        'TU_DEBUG=noconform' \
        "SHADOW_LINUX_LD_PRELOAD=$(pixel_runtime_linux_dir)/lib/shadow-openlog-preload.so" \
        'SHADOW_OPENLOG_DENY_DRI=1'
      ;;
    *)
      echo "pixel_blitz_demo_static_drm_gpu_probe: unsupported profile: $profile" >&2
      return 1
      ;;
  esac
}

run_case() {
  local profile="$1"
  local case_log="$probe_dir/${profile}.log"
  local case_json="$probe_dir/${profile}.json"
  local latest_before latest_after run_dir case_status required_markers=""
  local -a guest_env_lines=()
  local -a env_vars=(
    "PIXEL_RUNTIME_SUMMARY_RENDERER=gpu_softbuffer"
    "PIXEL_GUEST_EXPECT_COMPOSITOR_PROCESS="
    "PIXEL_GUEST_EXPECT_CLIENT_PROCESS="
  )

  while IFS= read -r env_line; do
    [[ -n "$env_line" ]] || continue
    guest_env_lines+=("$env_line")
  done < <(case_guest_env "$profile")

  if [[ "$profile" == *_early_probe ]]; then
    required_markers='gpu-summary-start'
    env_vars+=("PIXEL_GUEST_REQUIRED_MARKERS=$required_markers")
  fi

  if [[ -n "${PIXEL_STATIC_GPU_EXTRA_ENV-}" ]]; then
    guest_env_lines+=("${PIXEL_STATIC_GPU_EXTRA_ENV}")
  fi

  if [[ "${#guest_env_lines[@]}" -gt 0 ]]; then
    env_vars+=("PIXEL_GUEST_CLIENT_ENV=${guest_env_lines[*]}")
  fi

  latest_before="$(ls -1dt "$(pixel_drm_guest_runs_dir)"/* 2>/dev/null | head -n 1 || true)"

  printf 'pixel static gpu probe: profile=%s\n' "$profile" | tee "$case_log"
  if [[ "${#guest_env_lines[@]}" -gt 0 ]]; then
    printf 'guest env: %s\n' "${guest_env_lines[*]}" | tee -a "$case_log"
  else
    printf 'guest env: <none>\n' | tee -a "$case_log"
  fi

  set +e
  env "${env_vars[@]}" \
    "$SCRIPT_DIR/pixel_blitz_demo_static_drm_gpu_softbuffer.sh" >>"$case_log" 2>&1
  case_status="$?"
  set -e

  latest_after="$(ls -1dt "$(pixel_drm_guest_runs_dir)"/* 2>/dev/null | head -n 1 || true)"
  run_dir="$latest_after"
  if [[ -n "$latest_before" && "$latest_after" == "$latest_before" ]]; then
    run_dir=""
  fi

  python3 - "$profile" "$case_status" "$run_dir" "$case_json" <<'PY'
import json
import sys
from pathlib import Path

profile, exit_status_raw, run_dir_raw, output_path = sys.argv[1:5]
exit_status = int(exit_status_raw)
run_dir = Path(run_dir_raw) if run_dir_raw else None

status = None
summary = None
if run_dir is not None:
    status_path = run_dir / "status.json"
    summary_path = run_dir / "gpu-summary.json"
    if status_path.is_file():
        status = json.loads(status_path.read_text(encoding="utf-8"))
    if summary_path.is_file():
        summary = json.loads(summary_path.read_text(encoding="utf-8"))

payload = {
    "profile": profile,
    "exit_status": exit_status,
    "run_dir": str(run_dir) if run_dir is not None else None,
    "status": status,
    "summary": summary,
    "classified": bool((summary or {}).get("summary_source")),
    "measured": (summary or {}).get("first_visible_frame_ms") is not None,
    "success": exit_status == 0 and bool((status or {}).get("success")),
}

Path(output_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(payload, indent=2, sort_keys=True))
PY
}

for profile in "${profiles[@]}"; do
  run_case "$profile"
done

python3 - "$probe_dir" <<'PY'
import json
import sys
from pathlib import Path

probe_dir = Path(sys.argv[1])
cases = []
for case_path in sorted(probe_dir.glob("*.json")):
    if case_path.name == "matrix-summary.json":
        continue
    cases.append(json.loads(case_path.read_text(encoding="utf-8")))

payload = {
    "probe_dir": str(probe_dir),
    "case_count": len(cases),
    "success_count": sum(1 for case in cases if case.get("success")),
    "cases": cases,
}

summary_path = probe_dir / "matrix-summary.json"
summary_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(payload, indent=2, sort_keys=True))
PY
