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
- prove the guest can launch the Rust compositor and one guest Wayland client directly from `init_boot`, with both guest markers and normal Android boot markers visible in Cuttlefish logs
