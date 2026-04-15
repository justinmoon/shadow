#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pixel_common.sh
source "$SCRIPT_DIR/pixel_common.sh"
ensure_bootimg_shell "$@"

pixel_prepare_dirs

probe_root="$(pixel_dir)/runtime-gpu-probe"
probe_dir="$(pixel_prepare_named_run_dir "$probe_root")"
profiles_raw="${PIXEL_RUNTIME_GPU_PROFILES-}"

if [[ -z "$profiles_raw" ]]; then
  profiles_raw=$'gl\ngl_kgsl\nvulkan_drm\nvulkan_kgsl\nvulkan_kgsl_first'
fi

profiles=()
while IFS= read -r profile; do
  [[ -n "$profile" ]] || continue
  profiles+=("$profile")
done < <(printf '%s\n' "$profiles_raw" | tr ' ' '\n' | sed '/^[[:space:]]*$/d')
if [[ "${#profiles[@]}" -eq 0 ]]; then
  echo "pixel_runtime_app_drm_gpu_matrix: no profiles selected" >&2
  exit 1
fi

for profile in "${profiles[@]}"; do
  PIXEL_RUNTIME_GPU_PROBE_DIR="$probe_dir" \
    PIXEL_RUNTIME_APP_GPU_PROFILE="$profile" \
    "$SCRIPT_DIR/pixel_runtime_app_drm_gpu_probe.sh" "$profile"
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
