---
summary: High-level architecture for the supported Shadow demo surface
read_when:
  - starting work on the project
  - need to understand the supported demo/operator loop
---

# Architecture

`shadow` is now intentionally narrowed to one app model shown through two demo surfaces:

1. `just ui-vm-run`: the macOS QEMU loop for the shell, home screen, and app launch flow.
2. `just pixel-runtime-app-drm`: the rooted Pixel 4a loop for the same Blitz runtime app through the guest compositor DRM path.

Everything else is secondary or setup.

## Core Pieces

1. `ui/crates/shadow-ui-core` defines the shell state, scene graph, and app registry.
2. `ui/crates/shadow-compositor` is the Linux Smithay compositor used by the QEMU VM shell.
3. `ui/crates/shadow-compositor-guest` is the direct DRM/KMS guest compositor used on the Pixel.
4. `ui/apps/shadow-blitz-demo` is the only app client we care about. In runtime mode it loads the bundled Solid/Blitz app through the Deno-backed runtime seam.
5. `rust/shadow-session` is the late-start guest launcher used on the Pixel path.

## Supported Operator Loop

1. `just ui-vm-run` boots the QEMU VM.
2. `just ui-vm-wait-ready`, `just ui-vm-state`, `just ui-vm-open counter`, and `just ui-vm-screenshot` are the VM QA tools.
3. `just pixel-doctor` checks whether the rooted Pixel path can run.
4. `just pixel-build` and `just pixel-push` stage the current guest compositor, guest session, and Blitz runtime client.
5. `just pixel-prepare-runtime-app-artifacts` prepares the bundled runtime JS plus GNU-wrapped runtime helper.
6. `just pixel-runtime-app-drm` proves the rooted panel path.
7. `just pixel-runtime-app-drm-hold` keeps Android stopped for manual inspection, and `just pixel-restore-android` restores the display stack.

## Verification

1. `just ui-check` is the main compile/test gate for the `ui/` workspace.
2. `just ui-smoke` is the Linux compositor smoke for the Blitz runtime app launch path.
3. `just pre-commit` runs shell syntax checks, flake evaluation, and `just ui-check`.
4. `just ci` runs `just pre-commit` and `just ui-smoke`.
