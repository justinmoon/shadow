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
- [ ] Split `scripts/lib/pixel_common.sh` into smaller helper modules and move shared operator behavior up into `scripts/shadowctl` or typed helpers where it actually belongs.

## Near-Term Steps

- [ ] Create a short responsibility map for `shadow-compositor-guest/src/main.rs`.
- [ ] Extract the smallest module with the least behavior risk first.
- [ ] Avoid broad rewrites until VM smoke and Pixel shell startup behavior are covered by stable tests.
- [ ] Treat `scripts/lib/pixel_common.sh` the same way: stop growing one giant sourced shell library, and carve out target/session/operator behavior that should live in `shadowctl`.

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
- The first compositor-hosted Blitz prototype proved another constraint: do not
  move app rendering into the compositor and then block the compositor thread on
  a CPU renderer. The current hosted CPU slice improved from unusable
  multi-second scroll stalls to about `121ms` p50 scroll latency after
  coalescing and stale-frame fixes, but it still regresses the current landed
  shell lane. Any further phase-2 work should preserve compositor
  responsiveness first.
- The follow-up hosted GPU slices narrowed the remaining bottleneck:
  worker-backed hosted GPU Blitz plus a Pixel-specific shell copy fast path got
  to about `93ms` p50 scroll latency, and the later logical-shell `2x` slice
  got that down to about `88ms` p50. That is directionally better, but it is
  still far from the `~38ms` direct-runtime control case. The subsequent copy
  micro-tune regressed, and the "BGRA plus no CPU swizzle" idea failed because
  the current Vello/wgpu image-renderer path still binds the storage texture as
  `Rgba8Unorm`. So the next meaningful compositor work is still replacing the
  shell's software compose + dumb-buffer present path with compositor-native GPU
  composition if we want a real scroll win from phase 2.
- Script-layer note: `scripts/lib/pixel_common.sh` is now over `2k` lines and is
  acting as both low-level helper library and operator orchestration layer. That
  is the same smell as `shadow-compositor-guest/src/main.rs`: too many
  responsibilities in one file. Shared target/operator behavior should migrate
  into `scripts/shadowctl` or smaller typed helper modules instead of continuing
  to accumulate in one sourced shell file.
- Shell polish note: replacing the guest shell rasterizer with a GPU-backed
  Vello image renderer plus a prewarm step moved the first expensive home render
  behind the DRM boot splash, which is worthwhile for perceived startup quality.
  But the warm home path is still about `150ms`, and focused app interaction is
  still governed by the direct dmabuf present path. So this GPU-shell slice is
  a home/chrome improvement, not the main scroll-performance answer.
