---
summary: Supported operator model for Shadow VM/QEMU and rooted-Pixel work
read_when:
  - starting work on the project
  - need to understand the current operator surface
---

# Architecture

`shadow` is now primarily a shell/compositor repo with one supported operator contract:

- local QEMU VM shell/home plus app launch
- rooted Pixel shell/home plus app launch

Anything outside that surface is bring-up history, probe infrastructure, or an internal debugging lane. Those paths can still exist temporarily, but they should not define the repo's front door.

## Supported Operator Surface

### VM / QEMU

- The repo currently carries both `just vm-*` and `just ui-vm-*` names for the same VM surface.
- Prefer `just run target=vm` / `just stop target=vm` at the front door.
- Keep `vm-*` and `ui-vm-*` working as convenience and compatibility wrappers until the cleanup finishes.
- Primary loop:
  - `just run target=vm app=<id>`
  - `just stop target=vm`
  - `just vm-doctor`
  - `just vm-status`
  - `just vm-logs`
  - `just vm-journal`
  - `just vm-wait-ready`
  - `just vm-open app=<id>`
  - `just vm-home`
  - `just vm-screenshot`
  - `just vm-smoke`

### Rooted Pixel

- Primary loop:
  - `just pixel-doctor`
  - `just pixel-build`
  - `just pixel-stage shell`
  - `just run target=pixel app=<id>`
  - `just pixel-restore-android`
  - `just pixel-shell-drm-hold`
  - `just stop target=pixel`
  - `just shadowctl state|open <id>|home|switcher -t pixel`
  - `just pixel-ci <subset>`
- Setup and recovery still matter for the real-device lane:
  - `just pixel-root-prep`
  - `just pixel-root-patch`
  - `just pixel-root-flash`
  - `just pixel-root-check`
  - `just pixel-restore-android`
- The supported rooted-Pixel product surface is shell/home plus app launch, not every historical direct-runtime, GPU probe, or one-off device-debug path.

### Shared CLI

- `scripts/shadowctl` is the target-aware operator CLI for VM and Pixel.
- `just shadowctl ...` passes through to that shared CLI.
- `just run target=...` / `just stop target=...` now route through `shadowctl start` / `shadowctl stop`.
- Most VM convenience wrappers now hang off `shadowctl`, while older compatibility wrappers still exist around the same target model.
- Pixel shell control should move toward the same shared CLI shape instead of accumulating more one-off shell wrappers.

## Repo Shape

1. `flake.nix` pins the toolchain, dev shells, and packaged binaries.
2. `justfile` is the human entrypoint and should stay curated around the supported operator surface. `just` should show that curated view by default, and `just help-all` should expose the full recipe list.
3. `scripts/shadowctl` owns shared target/session/control behavior.
4. `scripts/*.sh` stage artifacts and launch sessions. Reused operator behavior belongs in `shadowctl`, not duplicated shell wrappers.
5. `ui/crates/shadow-ui-core` holds shell state, app metadata, palette, and the control protocol.
6. `ui/crates/shadow-compositor` is the Linux desktop compositor bring-up host.
7. `ui/crates/shadow-compositor-guest` is the guest compositor used by VM and Pixel sessions.
8. `rust/` contains helper binaries for session launch, runtime hosting, device integration, and narrow probes.

## Current Architecture Direction

- Treat VM/QEMU shell/home plus app launch and rooted Pixel shell/home plus app launch as the only supported surfaces.
- Keep `just` thin. If a capability is reused across targets, it belongs in `shadowctl`.
- Delete or hide historical probe lanes instead of continuing to advertise them as normal operator commands.
- Replace ad hoc launch-time env assembly with a small typed config loaded once at startup.
- Make app/runtime metadata single-source so staging, shell launch, and runtime host code stop carrying parallel tables.
- Decompose `shadow-compositor-guest` only after shared helpers and typed startup config seams are in place.

## Important Constraints

- The rooted Pixel path assumes a rooted device and uses the guest compositor control socket on-device for shell actions like `state`, `open`, `home`, and `switcher`.
- VM and Pixel are the validation targets that matter for cleanup work. Linux desktop host smokes and other historical bring-up paths are secondary.
- This repo is still a bring-up repo, not a polished product repo. The cleanup goal is to make the supported system explicit and to stop advertising accidental operator surface.

## Not Front-Door Material

These topics may still matter internally, but they should not dominate the top-level architecture doc:

- full early-boot and Cuttlefish history
- every GPU, runtime, audio, or input probe rung
- old transport experiments and one-off proof ladders

If that material remains useful, keep it in narrower tutorials or implementation notes instead of the main architecture overview.
