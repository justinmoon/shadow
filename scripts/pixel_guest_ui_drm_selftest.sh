#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PIXEL_GUEST_COMPOSITOR_SELFTEST_DRM=1 \
PIXEL_GUEST_EXPECT_COMPOSITOR_PROCESS= \
PIXEL_GUEST_EXPECT_CLIENT_PROCESS= \
PIXEL_GUEST_EXPECT_CLIENT_MARKER= \
PIXEL_VERIFY_REQUIRE_CLIENT_MARKER= \
PIXEL_COMPOSITOR_MARKER='[shadow-guest-compositor] selftest-frame-generated' \
  "$SCRIPT_DIR/pixel_guest_ui_drm.sh"
