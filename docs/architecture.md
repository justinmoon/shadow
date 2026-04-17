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

- Primary loop:
  - `just run target=vm app=<id>`
  - `just stop target=vm`
  - `sc -t vm doctor`
  - `sc -t vm status`
  - `sc -t vm logs`
  - `sc -t vm journal`
  - `sc -t vm wait-ready`
  - `sc -t vm open <id>`
  - `sc -t vm home`
  - `sc -t vm screenshot`
  - `sc -t vm frame`
  - `sc -t vm ssh`
  - `just smoke target=vm`
- The old `ui-vm-*`, `vm-*`, `ui-run`, and `ui-stop` compatibility recipes were removed. `just smoke target=vm` is the single VM CI subset recipe.

### Rooted Pixel

- Primary loop:
  - `sc -t pixel stage shell`
  - `just run target=pixel app=<id>`
  - `just stop target=pixel`
  - `sc -t pixel doctor`
  - `sc -t pixel state`
  - `sc -t pixel open <id>`
  - `sc -t pixel home`
  - `sc -t pixel switcher`
  - `sc -t pixel frame`
  - `sc -t pixel ci <subset>`
  - `sc -t pixel stage <subset>`
  - `just pixel-ci <subset>`
- `just pixel-ci`, `just pixel-stage`, and `just pixel-run` are thin convenience wrappers around `shadowctl` Pixel CI commands.
- Setup and recovery still matter for the real-device lane:
  - [Pixel prep](pixel-prep.md)
  - `sc root-prep`
  - `sc -t pixel root-check`
  - `sc -t pixel root-patch`
  - `sc -t pixel root-flash`
  - `sc -t pixel ota-sideload`
  - `just stop target=pixel`
- The supported rooted-Pixel product surface is shell/home plus app launch, not every historical direct-runtime, GPU probe, or one-off device-debug path.

### Shared CLI

- `scripts/shadowctl` is the target-aware operator CLI for VM and Pixel.
- `sc` is the devshell alias for `scripts/shadowctl`; `just shadowctl ...` is the fallback when `sc` is not on `PATH`.
- `just run target=...` / `just stop target=...` now route through `shadowctl run` / `shadowctl stop`.
- VM inspection/control hangs off `shadowctl`; `just` should not grow one wrapper per VM subcommand again.
- Pixel shell control and setup/recovery now hang off `shadowctl`; remaining cleanup is private helper consolidation.

## Repo Shape

1. `flake.nix` pins the toolchain, dev shells, and packaged binaries.
   The VM lane now consumes packaged Linux `shadow-compositor` / `shadow-blitz-demo` artifacts built through Nix; `.#ui-vm-ci` is the canonical artifact-consumer runner package.
   The guest should stay runtime-only.
   The guest no longer mounts the repo. It mounts `/nix/store` plus a narrow `.shadow-vm/runtime-artifacts` share staged on the host.
   Runtime app bundles are built by the shared host-side artifact builder (`scripts/runtime_build_artifacts.sh`) and staged under that artifact share.
   The VM podcast sample defaults to a checked-in local fixture so the branch gate does not need a live RSS/media fetch just to open that app.
2. `justfile` is the human entrypoint and should stay curated around orchestration shortcuts. `just` should show the small public API, not every historical probe script.
3. `scripts/shadowctl` owns shared target/session/control behavior.
4. `scripts/*.sh` stage artifacts and launch sessions. Reused operator behavior belongs in `shadowctl`, not duplicated shell wrappers.
5. `ui/crates/shadow-ui-core` holds shell state, app metadata, palette, and the control protocol.
6. `ui/crates/shadow-compositor` is the nested Linux compositor used inside the VM and by Linux desktop bring-up.
7. `ui/crates/shadow-compositor-guest` is the direct-display compositor used by rooted Pixel sessions.
8. `rust/` contains helper binaries for session launch, runtime hosting, device integration, and narrow probes.

## Current Architecture Direction

- Treat VM/QEMU shell/home plus app launch and rooted Pixel shell/home plus app launch as the only supported surfaces.
- Keep `just` thin. If a capability is reused across targets, it belongs in `shadowctl`.
- Delete or hide historical probe lanes instead of continuing to advertise them as normal operator commands.
- Keep runtime app bundling as an explicit host-side artifact-builder seam. Nix owns stable deps and Linux binaries; Deno/npm app bundling remains dynamic because the same machinery is useful for runtime-created apps.
- Replace ad hoc launch-time env assembly with a small typed config loaded once at startup.
- Make app/runtime metadata single-source so staging, shell launch, and runtime host code stop carrying parallel tables.
- Decompose `shadow-compositor-guest` only after shared helpers and typed startup config seams are in place.

## Important Constraints

- The rooted Pixel path assumes a rooted device and uses the guest compositor control socket on-device for shell actions like `state`, `open`, `home`, and `switcher`.
- VM and Pixel are the validation targets that matter for cleanup work. Linux desktop host smokes and other historical bring-up paths are secondary.
- The local macOS VM gate is allowed to use the local `linux-builder`; removing guest-side Cargo/Rust is part of keeping build-time and runtime responsibilities separate.
- The remaining VM impurity is intentional: host-prepared runtime app artifacts. The branch gate should keep that seam clean, manifest-driven, offline-safe for fixtures, and never built inside the guest.
- This repo is still a bring-up repo, not a polished product repo. The cleanup goal is to make the supported system explicit and to stop advertising accidental operator surface.

## Not Front-Door Material

These topics may still matter internally, but they should not dominate the top-level architecture doc:

- full early-boot and Cuttlefish history
- every GPU, runtime, audio, or input probe rung
- old transport experiments and one-off proof ladders

If that material remains useful, keep it in narrower tutorials or implementation notes instead of the main architecture overview.
