#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/pixel_common.sh
source "$SCRIPT_DIR/lib/pixel_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs

profile="${1:-${PIXEL_RUNTIME_APP_GPU_PROFILE:-vulkan_kgsl_first}}"
renderer="${PIXEL_RUNTIME_GPU_RENDERER:-gpu}"
probe_root="$(pixel_dir)/runtime-gpu-probe"
probe_dir="${PIXEL_RUNTIME_GPU_PROBE_DIR-}"
profile="${profile#profile=}"
profile_slug="$(printf '%s' "$profile" | tr -c 'A-Za-z0-9._-' '_')"

if [[ -z "$probe_dir" ]]; then
  probe_dir="$(pixel_prepare_named_run_dir "$probe_root")"
else
  mkdir -p "$probe_dir"
fi

case_log="$probe_dir/${profile}.log"
case_json="$probe_dir/${profile}.json"
run_dir="$probe_dir/run-$profile_slug"
rm -rf "$run_dir"
mkdir -p "$run_dir"

printf 'pixel runtime direct gpu probe: renderer=%s profile=%s\n' "$renderer" "$profile" | tee "$case_log"

set +e
env \
  PIXEL_RUNTIME_APP_RENDERER="$renderer" \
  PIXEL_RUNTIME_APP_GPU_PROFILE="$profile" \
  PIXEL_GUEST_RUN_DIR="$run_dir" \
  PIXEL_GUEST_SESSION_TIMEOUT_SECS="${PIXEL_GUEST_SESSION_TIMEOUT_SECS:-45}" \
  "$SCRIPT_DIR/pixel/pixel_runtime_app_drm.sh" >>"$case_log" 2>&1
case_status="$?"
set -e

python3 - "$profile" "$renderer" "$case_status" "$run_dir" "$case_log" "$case_json" <<'PY'
import json
import sys
from pathlib import Path

profile, renderer, exit_status_raw, run_dir_raw, log_path_raw, output_path = sys.argv[1:7]
exit_status = int(exit_status_raw)
run_dir = Path(run_dir_raw) if run_dir_raw else None
log_path = Path(log_path_raw)

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
    "renderer": renderer,
    "exit_status": exit_status,
    "log_path": str(log_path),
    "run_dir": str(run_dir) if run_dir is not None else None,
    "status": status,
    "summary": summary,
    "success": exit_status == 0 and bool((status or {}).get("success")),
    "startup_stage_last": (summary or {}).get("startup_stage_last"),
    "startup_stage_count": (summary or {}).get("startup_stage_count"),
    "failure_phase": (summary or {}).get("failure_phase"),
    "failure_reason": (summary or {}).get("failure_reason") or (status or {}).get("failure_message"),
    "failure_kind": (status or {}).get("failure_kind"),
    "failure_description": (status or {}).get("failure_description"),
    "adapter_ok": (summary or {}).get("adapter_ok"),
    "surface_ok": (summary or {}).get("surface_ok"),
    "configure_ok": (summary or {}).get("configure_ok"),
    "present_ok": (summary or {}).get("present_ok"),
}

Path(output_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(payload, indent=2, sort_keys=True))
PY
