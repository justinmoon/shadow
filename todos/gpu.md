# GPU Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Rooted Pixel 4a runtime apps must use hardware-backed GPU rendering by default.
- Interaction must feel instant to a human.
- Text must render correctly on real device builds.
- CPU is allowed as a diagnostic fallback, not as the end state.

## Approach

- Keep the current Solid + Deno + Blitz app model.
- Keep the rooted Pixel as the primary truth environment.
- Prefer the narrowest path that is measurably fast on device.
- Separate two questions:
  - Is the client using real hardware-backed GPU rendering?
  - Is the compositor path still forcing a slower SHM handoff?

## Current State

### Done

- [x] Host GPU renderer path proved.
- [x] Linux compositor control-plane GPU smoke proved.
- [x] Rooted Pixel hardware-backed client GPU path proved.
  - Proven lane: `gpu_softbuffer` + Vulkan + Turnip + KGSL.
  - Validated adapter:
    - `Turnip Adreno (TM) 618`
    - `turnip Mesa driver`
    - `hardware_backed=true`
- [x] Rooted Pixel runtime operator path defaults to the proven Turnip/KGSL lane when the cached vendor Turnip tarball is present.
- [x] Rooted Pixel runtime interaction is now fast enough for taps.
  - Best validated runtime numbers:
    - `first_visible_frame_ms=943`
    - `click_to_updated_frame_ms=38`
  - Source run:
    - `build/pixel/drm-guest/20260407T114828Z`
- [x] Rooted Pixel timeline text regression is fixed.
  - Root cause:
    - `SHADOW_BLITZ_ANDROID_FONTS=0` disabled all Android fonts in the runtime path.
  - Fix:
    - curated Android font mode in `ui/apps/shadow-blitz-demo/src/frame.rs`
    - runtime path defaults to `SHADOW_BLITZ_ANDROID_FONTS=curated`
  - Validated frame:
    - `build/pixel/drm-guest/20260407T125643Z/shadow-frame.png`
- [x] The Nostr timeline app is revalidated on the real hardware-backed GPU lane.
  - Validated run:
    - `build/pixel/drm-guest/20260407T140202Z`
  - Result:
    - `renderer=gpu_softbuffer`
    - `wgpu_backend=Vulkan`
    - `adapter_name=Turnip Adreno (TM) 618`
    - `hardware_backed=true`
    - text is visible again on the GPU path
- [x] The GPU bundle path no longer depends on the flaky x86_64 Linux builder.
  - GPU bundle prep now targets `aarch64-linux` by default.
  - The local GPU bundle is now fingerprinted and reused on cache hits.
- [x] The runtime helper push path now has a real device-side cache hit.
  - Repeated Pixel runs skip the old `~1.19GB` runtime helper tar push when the helper bundle fingerprint matches.
  - Validated output:
    - `Runtime helper dir cacheHit -> /data/local/tmp/shadow-runtime-gnu`
- [x] Timeline incremental rendering on the hardware-backed GPU lane is now measured directly.
  - Dedicated recipe:
    - `just pixel-runtime-app-nostr-timeline-click-drm`
  - Validated repeated real-device runs:
    - `click_to_updated_frame_ms=63`
    - `click_to_updated_frame_ms=62`
  - Source runs:
    - `build/pixel/drm-guest/20260407T142739Z`
    - `build/pixel/drm-guest/20260407T142843Z`
- [x] Fast local gate is green after the font fix.
  - `just ui-check`
  - `just pre-commit`

### Not Done

- [~] First visible app frame is still too slow.
  - The default timeline path with startup sync is still slower than we want.
  - Warmed / isolated click-lane runs now reached `first_visible_frame_ms=408`.
  - Initial first paint matters less than incremental update speed for this feature.
- [~] End-to-end GPU presentation is not proved.
  - The rooted Pixel client is hardware-backed.
  - The guest compositor still reports `observed_buffer_type=shm`.
  - So the current proof is:
    - GPU render in the client
    - SHM-oriented handoff/presentation in the compositor path
- [~] The GPU timeline recipe is much more reproducible now, but not completely polished.
  - The client GPU bundle now has a real local cache hit path.
  - The runtime host bundle/device push path is still heavy.
- [ ] The true `gpu` client renderer path is not the proven operator lane yet.
  - The proven lane today is `gpu_softbuffer`.
- [ ] The guest compositor does not yet import/present dmabuf-backed client buffers on the rooted Pixel path.
- [ ] There is not yet a one-command Pixel GPU timeline smoke that is both fast and independent of flaky remote rebuilds.

## What Is Proven vs. What Is Not

### Proven

- The Pixel can run the runtime client on real Adreno hardware through Turnip/KGSL.
- The runtime app model is not the performance blocker.
- The renderer can react fast once the first frame is on screen.
- The timeline app can now prove fast incremental updates on the real GPU path.
- The timeline app can render correct text on device after the curated-font fix.

### Not Proven

- That the compositor path is truly end-to-end GPU.
- That the `gpu` lane beats `gpu_softbuffer` enough to justify switching.
- That we can consistently hold first visible frame below `500ms`.
- That the timeline GPU recipe is fully robust against rebuild/builder churn.

## Important Findings

- The big early latency problem was not Deno. It was rendering/presentation.
- The earlier missing-text timeline screenshots were not a Nostr data bug. They were a font-loading configuration bug.
- The current rooted Pixel GPU story is real, but narrow:
  - vendor Turnip ICD
  - Vulkan backend
  - KGSL-preferred setup
  - `gpu_softbuffer`
- The current compositor path still looks SHM-oriented from the outside.

## Best Known Numbers

- Rooted Pixel runtime GPU path:
  - `first_visible_frame_ms=943`
  - `click_to_updated_frame_ms=38`
  - `hardware_backed=true`
  - run: `build/pixel/drm-guest/20260407T114828Z`
- Rooted Pixel timeline incremental click on the hardware-backed GPU lane:
  - `click_to_updated_frame_ms=62`
  - `hardware_backed=true`
  - run: `build/pixel/drm-guest/20260407T142843Z`
- Rooted Pixel static GPU probe:
  - `first_visible_frame_ms=1422`
  - `hardware_backed=true`
  - run: `build/pixel/drm-guest/20260407T112741Z`
- Rooted Pixel timeline text fix validation:
  - curated font registration: `count=4 elapsed_ms=1`
  - first visible frame under CPU validation: `2582ms`
  - frame: `build/pixel/drm-guest/20260407T125643Z`
- Rooted Pixel timeline on the hardware-backed GPU lane:
  - `first_visible_frame_ms=1861`
  - `hardware_backed=true`
  - `renderer=gpu_softbuffer`
  - `wgpu_backend=Vulkan`
  - run: `build/pixel/drm-guest/20260407T140202Z`

## Milestones

### 1. Prove hardware-backed client GPU on Pixel

- [x] Done.
- Notes:
  - commit `3d92b70`
  - Turnip/KGSL Vulkan path is real

### 2. Make runtime interaction fast enough to feel instant

- [~] Mostly done.
- Notes:
  - tap-to-visible update is good
  - timeline quick-gm update is now about `62ms` on the real GPU lane
  - startup still has work depending on which operator path we optimize for

### 3. Restore correct runtime text on Pixel

- [x] Done.
- Notes:
  - commit `9cc5e21`
  - curated Android fonts replaced the previous all-off setting

### 4. Make GPU timeline path reproducible and operator-safe

- [~] In progress.
- Notes:
  - hardware-backed GPU timeline path is revalidated
  - x86_64-builder dependency is removed from the GPU bundle path
  - local GPU bundle cache hits now work
  - runtime helper device-side cache hits now work too
  - remaining slop is the slower first-paint path on the full startup-sync timeline recipe

### 5. Eliminate SHM as the limiting compositor transport

- [ ] Not done.
- Notes:
  - this is the main remaining architectural gap if we want true end-to-end GPU presentation

## Near-Term Steps

1. Revalidate the Nostr timeline app on the proven hardware-backed GPU lane.
   - Command target:
     - `pixel-runtime-app-nostr-timeline-drm`
   - Requirement:
     - do not rely on `cpu`
     - confirm text, first frame, and interaction on the actual Turnip/KGSL lane

2. Keep the fast operator path warm and stable.
   - Goal:
     - repeated GPU runs should avoid rebuild churn and giant repushes
   - Status:
      - done for the client GPU bundle
      - done for the runtime helper push path
      - now focus on keeping the warm click lane stable

3. Keep measuring incremental latency on the GPU timeline path.
   - Need:
     - tap-to-updated-frame
     - text-render correctness
     - cache-hit stability
   - Current best proof:
     - `quick-gm` auto click updates in `~62ms`

4. Decide how much first-paint optimization is actually required.
   - Candidate seams:
     - startup bundle warm path
     - pipeline/shader warm path
     - reduce work before first present
     - avoid unnecessary runtime-side initial sync blocking visible first paint
   - Current note:
     - the warmed click lane already reached `408ms`
     - the full startup-sync timeline path is still slower
     - this is secondary to fast incremental updates

5. Start the compositor transport seam.
   - Add or finish linux-dmabuf import/presentation in `shadow-compositor-guest`.
   - Re-run buffer classification and stop only when the result is no longer `type=shm`, or when we can prove that staying SHM does not materially hurt the real device path.

## Plan To Finish This Project

### Phase A. Make the proven Pixel GPU lane reproducible

- Goal:
  - same hardware-backed Turnip/KGSL path every run
- Work:
  - avoid unnecessary remote rebuilds when known-good GPU artifacts already exist
  - add a dedicated Pixel GPU timeline smoke that writes the same compact summary as the counter demo
  - make the default operator commands use the cached/proven GPU artifacts whenever possible
- Exit:
  - we can run the timeline app repeatedly on the GPU lane without rebuild roulette

### Phase B. Make startup fast enough

- Goal:
  - first visible frame under `500ms`
- Work:
  - profile startup on the GPU timeline lane
  - remove pre-first-paint work that does not need to block the first frame
  - warm or cache the pieces that actually move the first-paint needle
- Exit:
  - repeated real-device runs land well below `500ms`

### Phase C. Finish end-to-end GPU presentation

- Goal:
  - real GPU client plus GPU-friendly compositor transport
- Work:
  - finish dmabuf import/presentation support in `shadow-compositor-guest`
  - re-run buffer classification on Pixel
  - compare `gpu` vs `gpu_softbuffer`
- Exit:
  - either:
    - compositor-observed buffer type is no longer SHM
  - or:
    - we have hard evidence that SHM is not the remaining bottleneck and the current proven path already meets the product bar

### Phase D. Decide whether Pixel remains viable

- Keep the Pixel if:
  - hardware-backed GPU remains stable
  - first visible frame gets under `500ms`
  - interaction remains instant
  - the remaining compositor transport story is acceptable or fixable

- Escalate to a different device only if:
  - the Pixel GPU lane stops being reproducible
  - Turnip/KGSL cannot be kept stable enough for operator use
  - or the compositor transport gap cannot be closed and is still visibly harming the device UX after the narrower fixes above

## Implementation Notes

- `3d92b70`:
  - hardware-backed Turnip/KGSL runtime path landed
- `9cc5e21`:
  - curated Android font mode restored runtime text on Pixel
- Current truth:
  - GPU requirement is not satisfied by `cpu`
  - GPU requirement is partially satisfied today:
    - real hardware-backed client GPU is proved
    - true end-to-end GPU presentation is not yet proved
