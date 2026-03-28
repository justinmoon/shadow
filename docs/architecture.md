---
summary: High-level architecture for the Shadow bring-up repo
read_when:
  - starting work on the project
  - need to understand the boot iteration loop
---

# Architecture

`shadow` is the narrow bring-up repo for early Android boot experimentation and the first reusable UI/compositor ladder.

The current workflow has four layers:

1. The flake defines the pinned toolchain used locally and on Hetzner.
2. `just` exposes the stable operator interface.
3. Shell scripts orchestrate artifact fetch, `init_boot` repacking, and Cuttlefish launch.
4. Hetzner runs the Cuttlefish guest used for stock and repacked boot verification.

Alongside the boot flow, `ui/` now carries the shell workspace:

1. `ui/crates/shadow-ui-core` defines shell state, app metadata, palette, and the scene graph.
2. `ui/crates/shadow-ui-desktop` is the fast desktop host for shell iteration.
3. `ui/crates/shadow-compositor` is the Linux-only Smithay host that starts the compositor bring-up path.
4. `scripts/ui_smoke.sh` is the headless Linux/Hetzner runtime proof for compositor plus app launch.

The current milestones are:

- boot stock Cuttlefish with stock and modified `init_boot.img` variants
- prove our Rust `/init` wrapper runs before handing off to stock Android
- keep the shell logic portable between a desktop host and a compositor host
- prove the compositor can auto-launch one Wayland client in a headless Linux smoke before moving that session logic into the guest
- prove a late-start Rust guest session can launch `drm_rect` after stock boot, take DRM master from the Android graphics stack, and report a successful modeset on Cuttlefish
- prove the guest can launch the Rust compositor and one guest Wayland client after stock boot, with matching compositor/client frame checksums and a pulled frame artifact

The current operator ladder reflects that split:

1. `just cf-init-wrapper` keeps the first-stage `init_boot` proof small and reliable.
2. `just cf-drm-rect` boots stock Android, uses `adb root`, stops the Android graphics services that hold DRM master, then runs `shadow-session` plus `drm-rect`.
3. `just cf-guest-ui-smoke` boots stock Android, uses `adb root`, starts `shadow-session` plus `shadow-compositor-guest`, auto-launches one guest Wayland client, and saves the captured frame artifact under `build/guest-ui/`.

This is intentionally not yet a full custom userland boot. The repo is using the smallest reliable transport at each layer: first-stage wrapper for `/init` proof, then post-boot guest session launch for display and compositor iteration.
