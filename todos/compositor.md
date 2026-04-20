# Compositor Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Continue shrinking and decomposing `shadow-compositor-guest`.
- Keep host and guest compositor differences explicit instead of pretending they are one binary.
- Preserve the supported VM and rooted-Pixel shell lanes while making compositor startup, launch policy, control, input, and DRM/KMS code easier to reason about.
- Move guest app lifetime toward an Android-like model: one foreground app, backgrounded/shelved apps preserved, explicit eviction only when policy or resource pressure requires it.

## Approach

- Split along real seams, not arbitrary file size.
- Keep the typed guest startup config as the boundary for env parsing.
- Share host/guest helpers only where the behavior is genuinely common.
- Validate each chunk with `just ui-check`; use `just smoke target=vm` when startup, launch, shell, or control behavior changes.

## Agent Handoff

- Do not collapse the host and guest compositors. They target different environments for real reasons.
- Goal: smaller guest modules, shared policy/helpers where true, and better tests. Not one binary.
- Collapse shared logic before considering any target-binary collapse. The likely end state is shared libraries plus thin target entrypoints, not one giant config-matrix binary.
- Treat the non-shell direct-DRM / direct-runtime path as a control lane for bring-up and perf comparison, not as a supported product surface.
- First deliverable should be a responsibility map for `ui/crates/shadow-compositor-guest/src/main.rs`.
- Pick one low-risk seam per change: launch/session policy, input/touch, DRM/KMS frame handling, control state, or env/config parsing.
- Prefer the launch/session policy seam first. It is the closest match to existing host compositor behavior and the best place to add focused tests.
- Avoid broad rewrites that change launch mode, app focus, shell/home behavior, or frame output without adding focused tests.
- Likely write areas: `ui/crates/shadow-compositor-guest/`, `ui/crates/shadow-compositor-common/`, `ui/crates/shadow-ui-core/`, and VM launch config only if startup behavior changes.
- Coordinate with app-metadata agents before changing app ids, Wayland app ids, or launch environment names.
- Validate refactors with `just ui-check`; run `just smoke target=vm` for startup/control/shell behavior; use a targeted Pixel shell suite only if DRM/KMS or rooted session behavior changes.
- Avoid concurrent VM smokes while testing. Local QEMU/MicroVM runs are resource-sensitive.

## Milestones

- [x] Extract shared compositor control and launch helpers into `shadow-compositor-common`.
- [x] Move guest startup env parsing into a typed config loader.
- [x] Map the remaining `shadow-compositor-guest/src/main.rs` responsibilities.
- [x] Split guest launch/session policy out of `main.rs`.
- [x] Replace unconditional guest "terminate other apps" behavior with bounded background-app residency closer to Android and current host compositor behavior.
- [x] Split touch/input handling out of `main.rs`.
- [x] Split DRM/KMS present and scanout handling behind a narrow module boundary.
- [ ] Replace remaining stringly env blobs with structured config where practical.
- [ ] Add focused unit tests around each extracted seam.
- [ ] Split `scripts/lib/pixel_common.sh` into smaller helper modules and move shared operator behavior up into `scripts/shadowctl` or typed helpers where it actually belongs.

## Near-Term Steps

- [x] Create a short responsibility map for `shadow-compositor-guest/src/main.rs`.
- [x] Extract guest launch/session policy first: focus, go-home, shelve/resume, lifecycle notifications, control-state reporting, and background-app eviction policy.
- [ ] Continue aligning guest session semantics with the host compositor while extracting only already-matched shared helpers.
- [x] Add focused tests for foreground/background/shelved transitions before touching input or DRM/KMS code.
- [ ] Avoid broad rewrites until VM smoke and Pixel shell startup behavior are covered by stable tests.
- [ ] Split Smithay handler glue out of guest `main.rs` once the render/present seam is stable.
- [ ] Treat `scripts/lib/pixel_common.sh` the same way: stop growing one giant sourced shell library, and carve out target/session/operator behavior that should live in `shadowctl`.

## Responsibility Map

- Startup and wiring:
  `main.rs` still owns typed config load, Smithay globals, transport setup,
  event-loop sources, and process lifetime.
- Session and control policy:
  app/window tracking, focus, home, shelve/resume, lifecycle notifications,
  media control, and control-state reporting belong together and should keep
  moving out of `main.rs`.
- Input routing:
  `touch.rs` owns raw evdev ingestion and normalization; the compositor still
  owns shell-vs-app-vs-hosted routing, gestures, and frame request policy.
- Frame and present path:
  `kms.rs` owns scanout primitives, while the compositor still owns the policy
  for hosted render, shell composition, dmabuf/shm capture, and present timing.
- Smithay handlers:
  Wayland commit, dmabuf import, and xdg-shell callbacks are still in
  `main.rs`; these can eventually move into guest-side handler modules once the
  session and frame paths are smaller.

## Implementation Notes

- There are two compositors for a reason: the host compositor targets a host Wayland/winit-style environment, while the guest compositor drives DRM/KMS on VM/Pixel-like targets.
- The goal is shared policy and smaller files, not forcing one binary.
- The naming is currently worse than the architecture. `shadow-compositor` and `shadow-compositor-guest` are too implicit. A later deployment-descriptive rename would help, but it should follow the structural cleanup instead of getting mixed into it.
- The guest compositor is on the critical path for both VM smoke and rooted-Pixel shell runs. Prefer boring, testable extractions.
- Any change that touches launch mode, control socket state, app focus, or frame output needs VM smoke coverage before landing.
- Current architecture is simpler than this file used to imply: on the rooted
  Pixel shell lane, hosted Blitz now runs inside the compositor and renders into
  compositor-owned GPU scanout buffers. The old steady-state CPU readback /
  software compose story is no longer the main constraint.
- The non-shell direct-runtime / direct-dmabuf-present path is still useful, but
  only as a control case. It is not a supported product lane. Keep it working
  enough for bring-up and measurement, but do not let it drive the guest
  compositor structure.
- Recent latency measurements moved the bottleneck from "hidden CPU in the loop"
  to "GPU render plus present cadence." That means this plan should stay focused
  on decomposition and ownership boundaries. If we revisit performance work, it
  should be a fresh, narrow task such as Vello/wgpu profiling on rooted Pixel,
  not a vague continuation of compositor cleanup.
- The one scheduling fix worth preserving is conceptual: input handlers should
  update state and request a frame, not paint inline. That belongs in the guest
  compositor design regardless of whether it changed the benchmark much.
- Current guest launch policy is too aggressive for the desired product shape.
  Going home already behaves like shelving/backgrounding; app switching should
  move in that direction too instead of unconditionally killing every other app.
  Eviction should be explicit policy, not the default switch path.
- The current guest eviction policy is an intentionally simple interim step:
  LRU-like background residency with a typed cap from
  `SHADOW_GUEST_COMPOSITOR_BACKGROUND_APP_LIMIT` and a default limit of `3`.
  That is a bridge toward Android-like behavior, not the final memory-pressure
  policy.
- One genuinely shared seam is now explicit: app-platform media dispatch and
  lifecycle notifications live in `shadow-compositor-common`. Keep continuing
  in that style: extract small concrete helpers, not generic "one compositor"
  abstractions.
- Another genuinely shared seam is now explicit: control-state rendering and
  sorted app-id reporting live in `shadow-compositor-common`. Keep the shared
  layer focused on deterministic policy/reporting helpers rather than backend
  plumbing.
- Guest touch/input routing is now split more cleanly: `touch.rs` keeps raw
  evdev ingestion and normalization, while `input.rs` owns synthetic control
  taps, touch-source wiring, shell-vs-app-vs-hosted routing, gesture
  thresholding, and hosted touch frame scheduling. That leaves `main.rs`
  responsible for startup, render/present, and Smithay handler glue instead of
  mixing in the full touch state machine.
- Input seam note: there is now at least one small focused unit-tested helper
  in the extracted guest input module for scroll-threshold detection. The larger
  touch routing behavior still needs deeper seam tests later, but it no longer
  has to stay trapped in `main.rs` to be testable.
- Render seam note: guest shell composition, frame publication, boot splash,
  dmabuf/shm surface capture, and frame-callback flushing now live in
  `render.rs`, while `kms.rs` remains the low-level scanout/capture primitive
  layer. `main.rs` is down to roughly `1.3k` lines, and the next obvious guest
  seam is Smithay handler glue rather than more frame-path churn.
- Test coverage note: the host compositor now has focused session tests for the
  same launch/home resident-process behavior we already covered on the guest
  side, and `flake.nix` now exposes a Linux `uiShadowCompositorTests` check so
  those tests can run on a real supported target instead of disappearing behind
  the macOS stub binary.
- Script-layer note: `scripts/lib/pixel_common.sh` is now over `2k` lines and is
  acting as both low-level helper library and operator orchestration layer. That
  is the same smell as `shadow-compositor-guest/src/main.rs`: too many
  responsibilities in one file. Shared target/operator behavior should migrate
  into `scripts/shadowctl` or smaller typed helper modules instead of continuing
  to accumulate in one sourced shell file.
- Shell polish note: home/chrome rendering and focused app interaction are now
  less architecturally distinct than before. The remaining useful split is
  product lane versus control lane, not "real shell path" versus "direct
  runtime" as competing product strategies.
