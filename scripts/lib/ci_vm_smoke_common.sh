#!/usr/bin/env bash

ci_vm_smoke_repo_root() {
  if declare -F repo_root >/dev/null 2>&1; then
    repo_root
  else
    git rev-parse --show-toplevel 2>/dev/null || pwd
  fi
}

ci_vm_smoke_has_git() {
  local repo_path="${1:-$(ci_vm_smoke_repo_root)}"
  git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

ci_vm_smoke_git_common_dir() {
  local repo_path="${1:-$(ci_vm_smoke_repo_root)}"
  git -C "$repo_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true
}

vm_smoke_root_repo() {
  local repo_path="${1:-$(ci_vm_smoke_repo_root)}"
  local common_git_dir
  if ! ci_vm_smoke_has_git "$repo_path"; then
    printf '%s\n' "$repo_path"
    return 0
  fi
  common_git_dir="$(ci_vm_smoke_git_common_dir "$repo_path")"
  (cd "$common_git_dir/.." && pwd)
}

vm_smoke_inputs_flake_ref() {
  local repo_path="${1:-$(ci_vm_smoke_repo_root)}"
  printf '%s#vm-smoke-inputs\n' "$repo_path"
}

vm_smoke_inputs_drv_path() {
  local repo_path="${1:-$(ci_vm_smoke_repo_root)}"
  nix path-info --accept-flake-config --derivation \
    "$(vm_smoke_inputs_flake_ref "$repo_path")"
}

vm_smoke_inputs_path() {
  local repo_path="${1:-$(ci_vm_smoke_repo_root)}"
  nix build --accept-flake-config --no-link --print-out-paths \
    "$(vm_smoke_inputs_flake_ref "$repo_path")"
}

vm_smoke_metadata_value() {
  local prepared_inputs_path="$1"
  local field_name="$2"
  python3 - "$prepared_inputs_path/metadata.json" "$field_name" <<'PY'
import json
import sys

metadata_path, field_name = sys.argv[1:3]
with open(metadata_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)
value = payload[field_name]
if not isinstance(value, str):
    raise SystemExit(f"vm_smoke_metadata_value: {field_name} is not a string")
print(value)
PY
}

vm_smoke_results_dir() {
  local repo_path="${1:-$(ci_vm_smoke_repo_root)}"
  if [[ -n "${SHADOW_VM_SMOKE_RESULTS_DIR:-}" ]]; then
    printf '%s\n' "$SHADOW_VM_SMOKE_RESULTS_DIR"
    return 0
  fi
  if ci_vm_smoke_has_git "$repo_path"; then
    printf '%s/shadow-ci/vm-smoke-success\n' "$(ci_vm_smoke_git_common_dir "$repo_path")"
    return 0
  fi
  printf '%s/.shadow-ci/vm-smoke-success\n' "$repo_path"
}

vm_smoke_record_path() {
  local logical_inputs_id="$1"
  local repo_path="${2:-$(ci_vm_smoke_repo_root)}"
  local key
  key="$(python3 - "$logical_inputs_id" <<'PY'
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())
PY
)"
  printf '%s/%s.json\n' "$(vm_smoke_results_dir "$repo_path")" "$key"
}

vm_smoke_has_cached_success() {
  local logical_inputs_id="$1"
  local repo_path="${2:-$(ci_vm_smoke_repo_root)}"
  [[ -f "$(vm_smoke_record_path "$logical_inputs_id" "$repo_path")" ]]
}

vm_smoke_record_success() {
  local logical_inputs_id="$1"
  local prepared_inputs_path="$2"
  local repo_path="${3:-$(ci_vm_smoke_repo_root)}"
  local record_path tmp_path head_sha

  record_path="$(vm_smoke_record_path "$logical_inputs_id" "$repo_path")"
  mkdir -p "$(dirname "$record_path")"
  if ci_vm_smoke_has_git "$repo_path"; then
    head_sha="$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || echo "")"
  else
    head_sha=""
  fi
  tmp_path="$(mktemp "${record_path}.XXXXXX")"
  python3 - "$logical_inputs_id" "$prepared_inputs_path" "$head_sha" >"$tmp_path" <<'PY'
import datetime
import json
import sys

logical_inputs_id, prepared_inputs_path, head_sha = sys.argv[1:4]
payload = {
    "schemaVersion": 2,
    "logicalInputsId": logical_inputs_id,
    "preparedInputsPath": prepared_inputs_path,
    "headSha": head_sha or None,
    "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
print(json.dumps(payload, indent=2))
PY
  mv "$tmp_path" "$record_path"
}
