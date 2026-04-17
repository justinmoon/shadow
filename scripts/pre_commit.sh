#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./shadow_common.sh
source "$SCRIPT_DIR/lib/shadow_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

scripts/ci/check_script_inventory.py
scripts/runtime/generate_app_metadata.py --check
scripts/ci/app_metadata_manifest_smoke.sh
shell_scripts=()
while IFS= read -r -d '' script_path; do
  if [[ "$script_path" == *.sh ]]; then
    shell_scripts+=("$script_path")
    continue
  fi
  first_line=""
  IFS= read -r first_line <"$script_path" || true
  case "$first_line" in
    "#!"*bash*|"#!"*sh*) shell_scripts+=("$script_path") ;;
  esac
done < <(find scripts -type f ! -path '*/__pycache__/*' -print0 | sort -z)
if ((${#shell_scripts[@]})); then
  bash -n "${shell_scripts[@]}"
fi
scripts/ci/operator_cli_smoke.sh
scripts/ci/timeline_sync_defaults_smoke.sh
scripts/lib/agent_tools.py check-docs
scripts/lib/agent_tools.py check-justfile
nix flake check --no-build
just ui-check
