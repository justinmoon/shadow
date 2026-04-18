# Compositor Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Continue shrinking and decomposing `shadow-compositor-guest`.
- Keep host and guest compositor differences explicit instead of pretending they are one binary.
- Preserve the supported VM and rooted-Pixel shell lanes while making compositor startup, launch policy, control, input, and DRM/KMS code easier to reason about.

## Approach

- Split along real seams, not arbitrary file size.
- Keep the typed guest startup config as the boundary for env parsing.
- Share host/guest helpers only where the behavior is genuinely common.
- Validate each chunk with `just ui-check`; use `just smoke target=vm` when startup, launch, shell, or control behavior changes.

## Agent Handoff

- Do not collapse the host and guest compositors. They target different environments for real reasons.
- Goal: smaller guest modules, shared policy/helpers where true, and better tests. Not one binary.
- First deliverable should be a responsibility map for `ui/crates/shadow-compositor-guest/src/main.rs`.
- Pick one low-risk seam per change: launch/session policy, input/touch, DRM/KMS frame handling, control state, or env/config parsing.
- Avoid broad rewrites that change launch mode, app focus, shell/home behavior, or frame output without adding focused tests.
- Likely write areas: `ui/crates/shadow-compositor-guest/`, `ui/crates/shadow-compositor-common/`, `ui/crates/shadow-ui-core/`, and VM launch config only if startup behavior changes.
- Coordinate with app-metadata agents before changing app ids, Wayland app ids, or launch environment names.
- Validate refactors with `just ui-check`; run `just smoke target=vm` for startup/control/shell behavior; use a targeted Pixel shell suite only if DRM/KMS or rooted session behavior changes.
- Avoid concurrent VM smokes while testing. Local QEMU/MicroVM runs are resource-sensitive.

## Milestones

- [x] Extract shared compositor control and launch helpers into `shadow-compositor-common`.
- [x] Move guest startup env parsing into a typed config loader.
- [ ] Map the remaining `shadow-compositor-guest/src/main.rs` responsibilities.
- [ ] Split guest launch/session policy out of `main.rs`.
- [ ] Split touch/input handling out of `main.rs`.
- [ ] Split DRM/KMS frame capture and blit logic behind a narrow module boundary.
- [ ] Replace remaining stringly env blobs with structured config where practical.
- [ ] Add focused unit tests around each extracted seam.

## Near-Term Steps

- [ ] Create a short responsibility map for `shadow-compositor-guest/src/main.rs`.
- [ ] Extract the smallest module with the least behavior risk first.
- [ ] Avoid broad rewrites until VM smoke and Pixel shell startup behavior are covered by stable tests.

## Implementation Notes

- There are two compositors for a reason: the host compositor targets a host Wayland/winit-style environment, while the guest compositor drives DRM/KMS on VM/Pixel-like targets.
- The goal is shared policy and smaller files, not forcing one binary.
- The guest compositor is on the critical path for both VM smoke and rooted-Pixel shell runs. Prefer boring, testable extractions.
- Any change that touches launch mode, control socket state, app focus, or frame output needs VM smoke coverage before landing.
- Latest Pixel scroll measurements changed the performance picture: shell app
  compositing is no longer the main problem after the fast-path work. The
  supported shell lane still pays heavily for per-app render plus dmabuf CPU
  capture. That means the "move Blitz into the compositor" direction from
  `todos/vdom.md` is now a performance simplification, not just an architectural
  cleanup idea.
- The control case now matters: direct runtime on the same Pixel reached
  `app-scroll.input_to_present` p50 about `38ms` after the Pixel AA cut, while
  the supported shell lane remained around `91ms`. The gap is now mostly the
  shell-side frame hop, not generic input plumbing.
