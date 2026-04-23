#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=./session_apps.sh
source "$SCRIPT_DIR/lib/session_apps.sh"
runtime_flake_ref=""
runtime_repo_root="$REPO_ROOT"
system_package_attr="shadow-system"
system_binary_path=""
enable_podcast_app="0"
bundle_rewrite_from=""
bundle_rewrite_to=""
artifact_root=""
artifact_guest_root=""
audio_backend=""
state_dir_override=""
session_config_out=""
startup_app_id=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --flake-ref)
        runtime_flake_ref="${2:-}"
        shift 2
        ;;
      --repo-root)
        runtime_repo_root="${2:-}"
        shift 2
        ;;
      --system-package)
        system_package_attr="${2:-}"
        shift 2
        ;;
      --system-binary-path)
        system_binary_path="${2:-}"
        shift 2
        ;;
      --include-podcast)
        enable_podcast_app="1"
        shift
        ;;
      --bundle-rewrite-from)
        bundle_rewrite_from="${2:-}"
        shift 2
        ;;
      --bundle-rewrite-to)
        bundle_rewrite_to="${2:-}"
        shift 2
        ;;
      --artifact-root)
        artifact_root="${2:-}"
        shift 2
        ;;
      --artifact-guest-root)
        artifact_guest_root="${2:-}"
        shift 2
        ;;
      --audio-backend)
        audio_backend="${2:-}"
        shift 2
        ;;
      --state-dir)
        state_dir_override="${2:-}"
        shift 2
        ;;
      --session-config-out)
        session_config_out="${2:-}"
        shift 2
        ;;
      --startup-app-id)
        startup_app_id="${2:-}"
        shift 2
        ;;
      *)
        echo "runtime_prepare_host_session_env.sh: unsupported argument $1" >&2
        exit 1
        ;;
    esac
  done
}

parse_args "$@"
runtime_repo_root="$(cd "$runtime_repo_root" && pwd)"

if [[ -n "$artifact_root" || -n "$artifact_guest_root" ]]; then
  if [[ -z "$artifact_root" || -z "$artifact_guest_root" ]]; then
    echo "runtime_prepare_host_session_env.sh: --artifact-root and --artifact-guest-root must be provided together" >&2
    exit 1
  fi
fi
if [[ -n "$bundle_rewrite_from" || -n "$bundle_rewrite_to" ]]; then
  if [[ -z "$bundle_rewrite_from" || -z "$bundle_rewrite_to" ]]; then
    echo "runtime_prepare_host_session_env.sh: --bundle-rewrite-from and --bundle-rewrite-to must be provided together" >&2
    exit 1
  fi
fi
if [[ -z "$session_config_out" ]]; then
  echo "runtime_prepare_host_session_env.sh: --session-config-out is required" >&2
  exit 1
fi

cd "$runtime_repo_root"
env_tmp="$(mktemp "${TMPDIR:-/tmp}/shadow-system-session-env.XXXXXX")"
cleanup() {
  rm -f "$env_tmp"
}
trap cleanup EXIT

builder_args=(
  --repo-root "$runtime_repo_root"
  --system-package "$system_package_attr"
  --profile vm-shell
  --write-env "$env_tmp"
)
if [[ -n "$runtime_flake_ref" ]]; then
  builder_args+=(--flake-ref "$runtime_flake_ref")
fi
if [[ -n "$system_binary_path" ]]; then
  builder_args+=(--system-binary-path "$system_binary_path")
fi
if [[ "$enable_podcast_app" == "1" ]]; then
  builder_args+=(--include-podcast)
fi
if [[ -n "$artifact_root" ]]; then
  builder_args+=(--artifact-root "$artifact_root" --artifact-guest-root "$artifact_guest_root")
fi
if [[ -n "$bundle_rewrite_from" ]]; then
  builder_args+=(--bundle-rewrite-from "$bundle_rewrite_from" --bundle-rewrite-to "$bundle_rewrite_to")
fi
if [[ -n "$audio_backend" ]]; then
  builder_args+=(--audio-backend "$audio_backend")
fi
if [[ -n "$state_dir_override" ]]; then
  builder_args+=(--state-dir "$state_dir_override")
fi
builder_args+=(--write-session-config "$session_config_out")
if [[ -n "$startup_app_id" ]]; then
  builder_args+=(--startup-app-id "$startup_app_id")
fi
"$SCRIPT_DIR/runtime_build_artifacts.sh" "${builder_args[@]}" >/dev/null

cat "$env_tmp"
