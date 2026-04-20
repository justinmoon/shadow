# GPU Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Rooted Pixel TS apps have exactly one production rendering model: Deno app runtime plus Blitz document/layout hosted inside the guest compositor.
- The compositor owns the only production GPU pass for TS apps: shell chrome and app content land in one compositor-owned GPU scene/output before KMS present.
- Steady-state TS app rendering must not do GPU-to-CPU readback, CPU pixel compositing, or per-frame app blits through host-visible buffers.
- CPU pixel paths remain allowed only for debug snapshots, tests, bring-up, and temporary instrumentation while we replace them.
- `direct_app_present` was not the target architecture. The shell-mode comparison path is gone; work now focuses on finishing the compositor-owned GPU path end to end.
- VM and desktop paths are useful for compile/smoke, but rooted Pixel behavior is the source of truth for this work.

## Problem Statement

We drifted into optimizing a path where the focused app can own the panel and bypass compositor composition. That can reduce latency, but it is not the system we actually want for TS apps. The wanted system is simpler:

- Blitz lives in the compositor.
- The compositor renders shell and app together.
- KMS presents that result.

The hosted Blitz path we started from crossed back to CPU:

- Blitz renders through `render_to_vec`.
- Vello copies GPU output into a mapped CPU buffer.
- The shell composites app pixels on CPU.
- KMS copies CPU pixels into a dumb buffer.

That is why the path felt wrong and slow. We have now removed those crossings on the rooted-Pixel hosted path; the next work is to optimize the remaining GPU render/present cadence rather than add alternate present modes.

## Architecture Target

1. App runtime sends document/state updates to the guest compositor.
2. Blitz document/layout stays hosted in the guest compositor process.
3. The compositor renders shell plus hosted app content into compositor-owned GPU resources.
4. KMS presents compositor output without app-frame CPU staging in steady state.
5. Readback exists only behind explicit debug or test controls.

## Non-Goals

- We are not designing a permanent split where some TS apps use direct present and others use compositor composition.
- We are not keeping multiple production TS rendering paths around once the compositor path works.
- We are not spending time polishing CPU composition except where needed to keep the system running while we replace it.

## Principles

- One production TS app rendering path.
- One compositor-owned GPU composition step.
- No hidden CPU fallback in steady-state Pixel mode.
- Delete old paths quickly once the replacement is proven.
- Optimize real bottlenecks, including dependency code, instead of routing around them with more modes.

## Current State

- [x] Hosted Blitz exists inside the compositor process.
- [x] Pixel shell can render through GPU-backed code paths.
- [x] CPU crossings on the hosted Pixel shell path are explicitly logged and fail closed under strict mode.
- [x] Pixel shell launches now go straight to hosted compositor mode; there is no shell-mode `direct_app_present` branch left to opt into.
- [x] On the GPU shell path, hosted Blitz is painted directly into the compositor render scene instead of crossing through `HostedFrame { pixels }`.
- [x] Hosted TS apps no longer keep a CPU `HostedFrame` fallback path; the compositor-owned hosted path is the only TS app handoff now.
- [x] Hosted TS apps no longer need `direct_app_present` exceptions; hosted geometry and input stay on the shell viewport path.
- [x] Hosted TS apps on the Pixel shell path no longer read back at shell render before KMS present; the compositor exports dmabufs and KMS scans them out directly.
- [x] Shell/app composition no longer needs CPU pixel compositing for hosted TS apps.
- [x] Rooted Pixel TS apps now have one production rendering path: hosted compositor rendering plus dmabuf/KMS present.
- [~] The remaining work is performance and cleanup, not architectural fallback plumbing.

## Milestones

- [ ] Make the target impossible to misunderstand in code and docs.
  - Rewrite plans/docs around one TS app rendering mode.
  - Mark the remaining CPU app-frame composition as temporary only.

- [~] Expose every CPU crossing in the hosted path.
  - Implemented: hosted Blitz readback, GPU shell readback, CPU app composition, and KMS dumb-buffer present now log their use and fail under the rooted-Pixel shell lane.
  - Remaining: extend coverage to any other steady-state TS app crossings we uncover.

- [~] Add the first no-readback renderer primitive.
  - Implemented: `VelloImageRenderer::render_to_texture_view`.
  - Remaining: thread/device ownership and compositor consumption.

- [x] Add a compositor-owned GPU app surface primitive.
  - Implemented by keeping hosted Blitz content on the compositor-owned scene/render path instead of producing `Vec<u8>` app frames.

- [x] Render hosted Blitz through that primitive.
  - Implemented for the GPU shell path by painting hosted Blitz directly in compositor render.
  - Implemented: removed the hosted software-fallback frame handoff entirely.
  - Remaining: keep shell and app on one renderer/device boundary everywhere.

- [~] Compose shell plus hosted app entirely on GPU.
  - Implemented for hosted TS apps on the GPU shell path.
  - Remaining: remove CPU `composite_app_frame` style blending from the remaining production paths and leave it only behind explicit debug/test gates.

- [x] Present compositor output without app-frame CPU staging.
  - Implemented for hosted TS apps by exporting compositor-owned dmabufs and presenting them through KMS.
  - Implemented: KMS primary-plane scaling preserves the old logical shell render size while scanout fills the panel.

- [~] Make hosted compositor mode the default Pixel TS path.
  - Implemented in the launcher by stopping the hardcoded `direct_app_present` default.
  - Implemented: removed the shell-mode `direct_app_present` branch from the compositor.
  - Remaining: validate on rooted Pixel and keep deleting leftover alternate production paths.

- [ ] Delete alternate production TS rendering paths.
  - Implemented: removed shell-mode `direct_app_present`.
  - Implemented: rooted-Pixel shell launches now hard-code strict compositor mode with no runtime opt-out.
  - Remaining: remove standalone/gpu-softbuffer style TS app present modes that bypass the compositor for production use.

- [~] Optimize the remaining path ruthlessly.
  - Implemented: removed the final hosted steady-state CPU crossings, then restored logical render size by using KMS primary-plane scaling instead of rendering full-panel.
  - Measured on rooted Pixel after the hard cut:
    - Full-panel dmabuf render regressed app-scroll `input_to_present` to about `447ms` p50 because the compositor was rasterizing `1080x2340`.
    - Logical-size dmabuf render plus KMS scaling improved app-scroll `input_to_present` to about `101ms` p50, with shell frame render usually around `25-31ms`.
  - Remaining: profile render/present cadence until this path is competitive with the older `~88ms` hosted worker path and materially closer to direct runtime.

## Near-Term Steps

1. Add explicit instrumentation and strict guards around the current CPU crossings so we stop lying to ourselves about what is on the hot path.
2. Add a no-readback GPU output primitive in the Vello/renderer stack that hosted Blitz can target.
3. Rework hosted Blitz handoff so the compositor consumes GPU output instead of pixel vectors.
4. Move shell plus app composition onto one compositor-owned GPU renderer path.
5. Flip Pixel TS launches to that path, measure, then start deleting the others.
6. Profile and remove the remaining render/present cadence bottlenecks now that CPU crossings are gone.

## Implementation Notes

- The current hot-path bottlenecks are in the hosted Blitz and shell compositor stack, not in the abstract idea of "Blitz in compositor".
- The CPU crossings we removed or hardened were centered around:
  - `ui/apps/shadow-blitz-demo/src/hosted_runtime.rs`
  - `ui/crates/shadow-compositor-guest/src/shell_gpu.rs`
  - `ui/crates/shadow-compositor-guest/src/shell.rs`
  - `ui/crates/shadow-compositor-guest/src/kms.rs`
  - `ui/third_party/anyrender_vello`
  - `ui/third_party/wgpu_context`
- We should prefer a design where Blitz and shell composition share one renderer/device boundary. Cross-device texture ownership will create more friction than it removes.
- The hard-cut dmabuf path now works end to end on rooted Pixel. The next bottleneck is not a hidden CPU bridge; it is GPU render/present cadence.
- When in doubt, delete optionality and move work toward the single compositor-owned path.
