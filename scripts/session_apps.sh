#!/usr/bin/env bash

SESSION_APPS_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_APPS_FILE="$SESSION_APPS_HELPER_DIR/session_apps.txt"
shadow_session_apps=()

shadow_load_session_apps() {
  if (( ${#shadow_session_apps[@]} > 0 )); then
    return 0
  fi

  mapfile -t shadow_session_apps < <(grep -Ev '^[[:space:]]*(#|$)' "$SESSION_APPS_FILE")
}

shadow_session_app_is_shell() {
  [[ "$1" == "shell" ]]
}

shadow_session_app_is_supported() {
  local app_id="$1"
  local supported_app_id

  shadow_load_session_apps
  for supported_app_id in "${shadow_session_apps[@]}"; do
    if [[ "$supported_app_id" == "$app_id" ]]; then
      return 0
    fi
  done

  return 1
}

shadow_session_app_supports_auto_open() {
  local app_id="$1"

  shadow_session_app_is_supported "$app_id" && ! shadow_session_app_is_shell "$app_id"
}

shadow_session_apps_usage() {
  local usage=()
  local app_id

  shadow_load_session_apps
  for app_id in "${shadow_session_apps[@]}"; do
    usage+=("app=$app_id")
  done

  local IFS=', '
  printf '%s\n' "${usage[*]}"
}
