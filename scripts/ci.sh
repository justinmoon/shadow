#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cf_common.sh
source "$SCRIPT_DIR/cf_common.sh"
ensure_bootimg_shell "$@"

cd "$(repo_root)"

export CF_WAIT_TIMEOUT="${CF_WAIT_TIMEOUT:-300}"
export INIT_WRAPPER_TIMEOUT="${INIT_WRAPPER_TIMEOUT:-180}"
export SHADOW_GUEST_UI_TIMEOUT="${SHADOW_GUEST_UI_TIMEOUT:-180}"

CI_NAMESPACE="${SHADOW_CI_NAMESPACE:-ci-$(worktree_basename)-$$}"
export SHADOW_UI_SMOKE_NAMESPACE="${SHADOW_UI_SMOKE_NAMESPACE:-${CI_NAMESPACE}-ui-smoke}"
export SHADOW_GUEST_UI_NAMESPACE="${SHADOW_GUEST_UI_NAMESPACE:-${CI_NAMESPACE}-guest-ui}"
STOCK_INSTANCE="$(deterministic_instance_name "${CI_NAMESPACE}-stock")"
REPACKED_INSTANCE="$(deterministic_instance_name "${CI_NAMESPACE}-repacked-initboot")"
WRAPPER_INSTANCE="$(deterministic_instance_name "${CI_NAMESPACE}-init-wrapper")"
GUEST_UI_INSTANCE="$(deterministic_instance_name "${CI_NAMESPACE}-guest-ui")"
GUEST_UI_DRM_INSTANCE="$(deterministic_instance_name "${CI_NAMESPACE}-guest-ui-drm")"
DRM_RECT_INSTANCE="$(deterministic_instance_name "${CI_NAMESPACE}-drm-rect")"

cleanup() {
  CUTTLEFISH_INSTANCE_OVERRIDE="$STOCK_INSTANCE" just cf-kill >/dev/null 2>&1 || true
  CUTTLEFISH_INSTANCE_OVERRIDE="$REPACKED_INSTANCE" just cf-kill >/dev/null 2>&1 || true
  CUTTLEFISH_INSTANCE_OVERRIDE="$WRAPPER_INSTANCE" just cf-kill >/dev/null 2>&1 || true
  CUTTLEFISH_INSTANCE_OVERRIDE="$GUEST_UI_INSTANCE" just cf-kill >/dev/null 2>&1 || true
  CUTTLEFISH_INSTANCE_OVERRIDE="$GUEST_UI_DRM_INSTANCE" just cf-kill >/dev/null 2>&1 || true
  CUTTLEFISH_INSTANCE_OVERRIDE="$DRM_RECT_INSTANCE" just cf-kill >/dev/null 2>&1 || true
}

trap cleanup EXIT

cleanup

just artifacts-fetch
just pre-commit
just ui-smoke

CUTTLEFISH_INSTANCE_OVERRIDE="$STOCK_INSTANCE" just cf-stock
CUTTLEFISH_INSTANCE_OVERRIDE="$STOCK_INSTANCE" just cf-kill

CUTTLEFISH_INSTANCE_OVERRIDE="$REPACKED_INSTANCE" just cf-repacked-initboot
CUTTLEFISH_INSTANCE_OVERRIDE="$REPACKED_INSTANCE" just cf-kill

CUTTLEFISH_INSTANCE_OVERRIDE="$WRAPPER_INSTANCE" just cf-init-wrapper
CUTTLEFISH_INSTANCE_OVERRIDE="$WRAPPER_INSTANCE" just cf-kill

CUTTLEFISH_INSTANCE_OVERRIDE="$DRM_RECT_INSTANCE" just cf-drm-rect
CUTTLEFISH_INSTANCE_OVERRIDE="$DRM_RECT_INSTANCE" just cf-kill

CUTTLEFISH_INSTANCE_OVERRIDE="$GUEST_UI_INSTANCE" just cf-guest-ui-smoke
CUTTLEFISH_INSTANCE_OVERRIDE="$GUEST_UI_INSTANCE" just cf-kill

CUTTLEFISH_INSTANCE_OVERRIDE="$GUEST_UI_DRM_INSTANCE" just cf-guest-ui-drm-smoke
CUTTLEFISH_INSTANCE_OVERRIDE="$GUEST_UI_DRM_INSTANCE" just cf-kill
