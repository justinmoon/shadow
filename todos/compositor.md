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
- Any change that touches launch mode, control socket state, app focus, or frame output needs VM smoke coverage before landing.

