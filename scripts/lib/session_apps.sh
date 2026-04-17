#!/usr/bin/env bash

SESSION_APPS_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_APPS_MANIFEST="${SHADOW_APP_METADATA_MANIFEST:-$SESSION_APPS_HELPER_DIR/../../runtime/apps.json}"
shadow_session_apps=()

shadow_session_shell_app_id() {
  python3 - "$SESSION_APPS_MANIFEST" <<'PY'
import json
import sys

manifest_path = sys.argv[1]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)

print(manifest.get("shell", {}).get("id", "shell"))
PY
}

shadow_load_session_apps() {
  local profile="${1:-${SHADOW_SESSION_APP_PROFILE:-}}"

  mapfile -t shadow_session_apps < <(python3 - "$SESSION_APPS_MANIFEST" "$profile" <<'PY'
import json
import sys

manifest_path, profile = sys.argv[1:3]
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)

shell_id = manifest.get("shell", {}).get("id", "shell")
print(shell_id)
for app in manifest.get("apps", []):
    profiles = set(app.get("profiles", []))
    if profile:
        if profile not in profiles:
            continue
    elif not profiles & {"vm-shell", "pixel-shell"}:
        continue
    if app["id"] != shell_id:
        print(app["id"])
PY
)
}

shadow_session_app_is_shell() {
  local shell_app_id
  shell_app_id="$(shadow_session_shell_app_id)"
  [[ "$1" == "$shell_app_id" ]]
}

shadow_session_app_is_supported() {
  local app_id="$1"
  local profile="${2:-}"
  local supported_app_id

  shadow_load_session_apps "$profile"
  for supported_app_id in "${shadow_session_apps[@]}"; do
    if [[ "$supported_app_id" == "$app_id" ]]; then
      return 0
    fi
  done

  return 1
}

shadow_session_app_supports_auto_open() {
  local app_id="$1"
  local profile="${2:-}"

  shadow_session_app_is_supported "$app_id" "$profile" && ! shadow_session_app_is_shell "$app_id"
}

shadow_session_apps_usage() {
  local profile="${1:-}"
  local usage=()
  local app_id

  shadow_load_session_apps "$profile"
  for app_id in "${shadow_session_apps[@]}"; do
    usage+=("app=$app_id")
  done

  local IFS=', '
  printf '%s\n' "${usage[*]}"
}
