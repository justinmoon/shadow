#!/usr/bin/env bash

ci_vm_smoke_repo_root() {
  if declare -F repo_root >/dev/null 2>&1; then
    repo_root
  else
    git rev-parse --show-toplevel 2>/dev/null || pwd
  fi
}

ci_vm_smoke_git_common_dir() {
  local repo_path="${1:-$(ci_vm_smoke_repo_root)}"
  git -C "$repo_path" rev-parse --path-format=absolute --git-common-dir
}

vm_smoke_root_repo() {
  local repo_path="${1:-$(ci_vm_smoke_repo_root)}"
  local common_git_dir
  common_git_dir="$(ci_vm_smoke_git_common_dir "$repo_path")"
  (cd "$common_git_dir/.." && pwd)
}

vm_smoke_inputs_flake_ref() {
  local repo_path="${1:-$(ci_vm_smoke_repo_root)}"
  printf '%s#vm-smoke-inputs\n' "$repo_path"
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
  printf '%s/shadow-ci/vm-smoke-success\n' "$(ci_vm_smoke_git_common_dir "$repo_path")"
}

vm_smoke_record_path() {
  local prepared_inputs_path="$1"
  local repo_path="${2:-$(ci_vm_smoke_repo_root)}"
  local key
  key="$(python3 - "$prepared_inputs_path" <<'PY'
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())
PY
)"
  printf '%s/%s.json\n' "$(vm_smoke_results_dir "$repo_path")" "$key"
}

vm_smoke_has_cached_success() {
  local prepared_inputs_path="$1"
  local repo_path="${2:-$(ci_vm_smoke_repo_root)}"
  [[ -f "$(vm_smoke_record_path "$prepared_inputs_path" "$repo_path")" ]]
}

vm_smoke_record_success() {
  local prepared_inputs_path="$1"
  local repo_path="${2:-$(ci_vm_smoke_repo_root)}"
  local record_path tmp_path head_sha

  record_path="$(vm_smoke_record_path "$prepared_inputs_path" "$repo_path")"
  mkdir -p "$(dirname "$record_path")"
  head_sha="$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || echo "")"
  tmp_path="$(mktemp "${record_path}.XXXXXX")"
  python3 - "$prepared_inputs_path" "$head_sha" >"$tmp_path" <<'PY'
import datetime
import json
import sys

prepared_inputs_path, head_sha = sys.argv[1:3]
payload = {
    "schemaVersion": 1,
    "preparedInputsPath": prepared_inputs_path,
    "headSha": head_sha or None,
    "recordedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
print(json.dumps(payload, indent=2))
PY
  mv "$tmp_path" "$record_path"
}
