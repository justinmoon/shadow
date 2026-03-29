---
summary: High-level architecture for the Shadow bring-up repo
read_when:
  - starting work on the project
  - need to understand the boot iteration loop
---

# Architecture

`shadow` is the narrow bring-up repo for early Android boot experimentation.

The current workflow has four layers:

1. The flake defines the pinned toolchain used locally and on Hetzner.
2. `just` exposes the stable operator interface.
3. Shell scripts orchestrate artifact fetch, `init_boot` repacking, and Cuttlefish launch.
4. Hetzner runs the Cuttlefish guest used for stock and repacked boot verification.

The current milestone is: boot stock Cuttlefish with a repacked but behaviorally unchanged `init_boot.img`.

The repo now also contains a UI workspace in `ui/` for the future mobile shell. The workspace is split into:

- `shadow-ui-core` for shell state, scene data, and app metadata.
- `shadow-ui-wgpu` for shared low-level rendering and text plumbing used by desktop-style apps.
- `shadow-ui-desktop` for the portable desktop host.
- `shadow-compositor` for the Linux/Wayland path built around Smithay.
- `shadow-counter` as the first real app, split into a desktop host and a Linux Wayland-native SCTK host.
- `shadow-blitz-demo` as the native-renderer prototype where Deno owns state and Rust/Blitz owns display.

The intended seam with device bring-up is:

- `shadow-ui-core` stays host-agnostic and owns scene, navigation, and app identity.
- Hosts own launch policy, process model, and platform wiring.
- The current desktop host is the fast iteration loop; the Smithay compositor is the Linux path that can eventually meet PID 1 bring-up in the middle.

The renderer experiments intentionally share the same shell/compositor process model:

- Blitz + Deno tests the “logic outside Rust, HTML/CSS as the UI DSL, native renderer applies it” path that is closer to the long-term app model.

The current Blitz demo is deliberately coarse: Deno owns state, polls a simple file mailbox for native click events, and emits full HTML/CSS updates back over stdout. The Rust host swaps that subtree into a Blitz document. That is enough to prove the process split, event bridge, and native rendering loop before we commit to a finer-grained mutation protocol.

For local compositor development on macOS, the repo now also has a Nix-defined graphical Linux VM path. It uses `microvm.nix` with the `qemu` hypervisor on Darwin so the guest appears as a native macOS window while still running the compositor and apps inside a real Linux environment. QEMU is the preferred local host path over vfkit here because it gives us a graphics window and 9p repo sharing at the same time, which keeps guest execution real without making the edit-run loop awkward.

The operator surface for that path lives in `just ui-vm-run`, `just ui-vm-stop`, `just ui-vm-ssh`, `just ui-vm-logs`, `just ui-vm-status`, and `just ui-vm-journal`. The guest autologins through `greetd`, starts a dedicated `weston` session directly from the shared repo environment, and runs `shadow-ui-desktop` as a Wayland client in that session. The shell and both prototype apps are just ordinary Wayland clients in the same `weston` compositor.

The current bridge step keeps `weston` as the stable outer guest compositor and runs `shadow-compositor` nested inside it. That nested path now has a working upright shell plus full-output native app mapping, which is enough to treat `shadow-counter` as the first real demo app on top of our own compositor while `weston` still owns the session, input stack, and device plumbing.

Its toolchain lives in `devShells.ui`; `devShells.default` intentionally remains the bootimg shell so the boot bring-up workflow keeps the same entrypoint.
