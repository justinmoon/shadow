---
summary: Measuring rooted-Pixel touch, scroll, runtime, and frame latency
read_when:
  - measuring touch or scroll latency
  - debugging sluggish rooted-Pixel app interaction
  - comparing renderer or runtime poll changes
---

# Latency Measurement

Use the rooted-Pixel touch latency probe for direct-runtime app latency:

```sh
sc -t <serial> debug latency
```

Use the rooted-Pixel shell scroll benchmark for the supported hosted shell lane:

```sh
sc -t <serial> debug scroll-latency
```

For a deterministic run directory:

```sh
PIXEL_TOUCH_LATENCY_PANEL_SIZE=1080x2340 \
PIXEL_TOUCH_LATENCY_RUN_DIR=build/latency/probe-timeline \
  sc -t <serial> debug latency
```

The probe launches the timeline runtime app, enables compositor touch tracing,
injects one tap and three swipes with low-level `sendevent`, then writes
`latency-summary.json`.

Normal long-running Pixel sessions do not write a PPM artifact on every
published frame. Request one explicitly when a test or debugging session needs
the compositor's latest frame:

```sh
sc -t <serial> frame build/pixel/latest-shadow-frame.ppm
```

That calls the compositor control socket, writes one target-side PPM, and pulls
it back to the requested host path.

Important summary fields:

- `touch_latency.handle_queue`: evdev reader to compositor event handling.
- `touch_latency.dispatch_to_flush`: compositor handle to Wayland/client dispatch.
- `touch_latency.routes.app-scroll.input_to_present`: finger move to presented scroll frame.
- `scroll_frame_latency.input_age_at_render_start`: age of the newest scroll move
  sample actually consumed when the rendered frame began.
- `scroll_frame_latency.input_age_at_present`: age of that same consumed scroll
  move sample when the frame presented.
- `scroll_frame_latency.coalesced_move_count`: number of intermediate scroll
  move samples skipped between presented scroll frames.
- `touch_signal_latency`: compositor touch-signal file write to runtime fallback detection. On Linux/Pixel this is event-driven with an inotify watcher and falls back to polling if watching is unavailable.
- `softbuffer_latency.render_to_vec`: app-side CPU raster time before softbuffer present. Historical only for retired Pixel CPU/softbuffer runs.
- `compositor_frame_latency.capture_to_artifact`: compositor capture to PPM artifact write when continuous artifacts are explicitly enabled.
- `compositor_frame_latency.capture_to_present`: compositor frame capture to DRM present.
- `runtime_session_latency`: host session request cost by operation.

Historical pre-hard-cut `gpu_softbuffer` Pixel 4a result from `build/latency/probe-timeline-4`:

- Raw compositor dispatch is not the main problem: `dispatch_to_flush` p50 was
  `0.035ms`.
- Scroll frames are far too slow: `app-scroll.input_to_present` p50 was
  `88.226ms`, p95 was `166.615ms`.
- CPU softbuffer rendering dominates: `render_to_vec` p50 was `205.5ms`, p95
  was `366.65ms`.
- Frame artifact writing is also visible: `capture_to_artifact` p50 was `17ms`,
  p95 was `45.65ms`.
- The touch-signal fallback is polling and render-loop bound: p50 detection was
  `263.5ms` in this run.

After the event-driven touch-signal watcher, `build/latency/probe-inotify-090`
measured `touch_signal_latency` p50 `0ms`, p95 `0ms` across 4 samples on Pixel
`09051JEC202061`.

Pure-GPU direct-runtime result from
`build/pixel/touch/20260418T214921Z` on Pixel `0B191JEC203253`:

- Compositor dispatch is still cheap: `dispatch_to_flush` p50 was `0.055ms`,
  p95 was `0.111ms`.
- Scroll is still far too slow on the visible path: `app-scroll.input_to_present`
  p50 was `205.264ms`, p95 was `222.971ms`.
- Scroll-stop frames are worse: `app-scroll-stop.input_to_present` p50 was
  `306.940ms`.
- Runtime dispatch was not on the move path. The probe saw 5 runtime dispatches,
  all `click target=refresh` events on touch-down, while scroll move events were
  compositor `app-scroll` dispatches with no matching runtime dispatch.
- The runtime side was not saturated: `runtime_session_latency.dispatch` p50 was
  `4ms`, and `render_if_dirty` p50 was `0ms`.
- After lowering Pixel antialiasing to `Area`, the direct-runtime probe in
  `build/pixel/touch/runtime-area-aa` improved sharply:
  - `app-scroll.input_to_present` p50 `38.336ms`, p95 `60.109ms`
  - overall `input_to_present` p50 `53.209ms` (worse because scroll-stop frames
    are still expensive)
  - compositor dispatch stayed cheap: `dispatch_to_flush` p50 `0.088ms`

Shell-lane follow-up after cutting accidental CPU capture from direct-present
runtime and optimizing shell app compositing:

- Panel-sized shell surface in `build/pixel/touch/shell-post-cut-runonly2`
  still spent most time outside shell compositing:
  - `app-scroll.input_to_present` average `155.7ms`
  - app `render_ms` p50 `204ms`
  - compositor `capture_ms` p50 `102ms`
  - shell `app_composite_ms` p50 `4ms`
- Logical shell surface (`540x1106`) in
  `build/pixel/touch/shell-small-surface` materially improved the supported
  shell lane:
  - `app-scroll.input_to_present` p50 `96.2ms`
  - app `render_ms` p50 `81ms`
  - compositor `capture_ms` p50 `27ms`
  - shell `app_composite_ms` p50 `17ms`
- Adding cheaper Vello antialiasing for Pixel shell/runtime in
  `build/pixel/touch/shell-area-aa` improved the same logical shell lane again:
  - `app-scroll.input_to_present` p50 `91.0ms`
  - app `render_ms` p50 `53ms`
  - compositor `capture_ms` p50 `26ms`
  - shell `app_composite_ms` p50 `17ms`

Current direction:

- Pixel operator paths are now GPU-only.
- The next latency problem is scrolling on the supported GPU shell lane, not
  deciding whether to leave CPU softbuffer behind.

Phase-2 hosted-Blitz experiment on Pixel shell:

- The first compositor-hosted CPU Blitz slice in
  `build/pixel/touch/phase2-shell-hosted-20260419T011433Z` was a real failure:
  - `app-scroll.input_to_present` p50 `3208.377ms`, p95 `10760.546ms`
  - the hosted app was doing full CPU renders inline on the compositor thread
    during touch move handling
  - per-move hosted render logs climbed into the `500ms` to `1000ms` range
- After moving hosted renders off the touch handler and onto the existing hosted
  poll loop in `build/pixel/touch/phase2-shell-hosted-coalesced-20260419T011731Z`:
  - `app-scroll.input_to_present` p50 `223.745ms`, p95 `269.119ms`
  - hosted render p50 was down to about `68ms`
  - but the trace was still one event behind because touch move handling was
    publishing a stale shell frame immediately and the next present got
    attributed to the previous move
- After removing that stale immediate publish in
  `build/pixel/touch/phase2-shell-hosted-aligned-20260419T012612Z`:
  - `app-scroll.input_to_present` p50 `120.745ms`, p95 `186.055ms`
  - `dispatch_to_flush` p50 `0.222ms`
  - `dispatch_to_present` p50 `113.905ms`
  - hosted render p50 was about `55ms` (`29` renders, min `18ms`, max `201ms`)
  - shell composite stayed cheap at about `8ms`
- Switching hosted Blitz to the GPU image renderer without fixing the wakeup
  model was only a small win in
  `build/pixel/touch/phase2-shell-hosted-gpu-gnu2-runonly-20260419T020333Z`:
  - `app-scroll.input_to_present` p50 `105.053ms`, p95 `140.996ms`
  - `dispatch_to_present` p50 `80.182ms`
  - `handle_queue` p50 `33.776ms`
- Moving the hosted app onto a dedicated worker and waking the compositor only
  when frames are ready helped more in
  `build/pixel/touch/phase2-shell-hosted-gpu-worker-20260419T021247Z`:
  - `app-scroll.input_to_present` p50 `95.616ms`, p95 `129.110ms`
  - `dispatch_to_present` p50 `79.757ms`
  - hosted render stayed about `27ms` to `31ms` on move frames
- Special-casing the Pixel shell's 2x app-frame scale in
  `build/pixel/touch/phase2-shell-hosted-gpu-worker-fastcopy-20260419T021530Z`
  brought compositor-hosted GPU Blitz to near-parity with the shipped shell
  lane:
  - `app-scroll.input_to_present` p50 `93.344ms`, p95 `131.121ms`
  - `dispatch_to_present` p50 `80.133ms`
  - `handle_queue` p50 `32.965ms`
  - hosted render stayed about `27ms`, shell composite was usually about
    `18ms` to `21ms`, and KMS present remained about `11ms` to `21ms`
- Rendering the shell at the logical `540x1170` viewport and doing the exact
  `2x` expansion at KMS present improved that a bit more in
  `build/pixel/touch/phase2-shell-hosted-gpu-worker-fastcopy-logical2x-20260419T043116Z`:
  - `app-scroll.input_to_present` p50 `87.873ms`, p95 `114.19ms`
  - `dispatch_to_present` p50 `79.738ms`
  - `handle_queue` p50 `27.587ms`
  - hosted render stayed about `27ms` to `31ms`, shell composite stayed about
    `18ms` to `21ms`, and KMS present dropped slightly to about `9ms` to `18ms`
- Two follow-up attempts did not move the branch forward:
  - a "full contiguous viewport copy" fast path regressed to about `106ms` p50
    in `build/pixel/touch/phase2-shell-hosted-gpu-worker-fastcopy-logical2x-fullcopy-20260419T043553Z`
  - a hosted BGRA/no-swizzle path failed at startup in
    `build/pixel/touch/phase2-shell-hosted-gpu-worker-fastcopy-logical2x-bgra-feature-runonly-20260419T045903Z`
    because Vello/wgpu still binds the storage texture as `Rgba8Unorm`

Hard-cut dmabuf/KMS follow-up on the single compositor-owned TS path:

- The first strict no-CPU hard-cut run in
  `build/pixel/touch/hard-cut-dmabuf-scale-20260419T220144Z` landed at:
  - `app-scroll.input_to_present` p50 `100.903ms`, p95 `117.457ms`
  - `dispatch_to_present` p50 `99.915ms`
  - shell `scene_render_ms` p50 about `27ms`
- Two obvious cleanup attempts were worth keeping for architecture, but they
  did not materially improve latency:
  - caching imported KMS framebuffers for the reused shell dmabufs in
    `build/pixel/touch/lowhang-kms-cache-20260419T223814Z`
    kept scroll roughly flat at `103.709ms` p50 and `dispatch_to_present`
    `100.531ms` p50
  - replacing the compositor scanout path's blocking
    `device.poll(wait_indefinitely())` with a nonblocking poll in
    `build/pixel/touch/lowhang-no-wait-20260419T224724Z`
    also stayed roughly flat at `104.55ms` p50 and `dispatch_to_present`
    `101.397ms` p50
- Those runs kept shell `scene_render_ms` around `27ms` p50, so the active
  bottleneck after the hard cut is not an obvious leftover CPU bridge or
  import churn. It is the remaining render/present cadence of the GPU path.
- The dedicated shell scroll benchmark in
  `build/pixel/touch/scroll-benchmark-baseline-0B191JEC203253-r2` gives a more
  truthful hosted-lane number than the older touch bucket because it links each
  presented frame to the newest move sample that frame actually rendered:
  - `scroll_frame_latency.routes.app-scroll.input_age_at_render_start` p50
    `1.156ms`, p95 `11.815ms`
  - `scroll_frame_latency.routes.app-scroll.input_age_at_present` p50
    `48.311ms`, p95 `72.212ms`
  - `scroll_frame_latency.routes.app-scroll.render_to_present` p50 `45.919ms`,
    p95 `62.639ms`
  - `scroll_frame_latency.routes.app-scroll.coalesced_move_count` stayed `0`
    across 176 presented scroll frames
  - the older `touch_latency.routes.app-scroll.input_to_present` bucket still
    read `115.526ms` p50 on that run, which confirms it overstates hosted scroll
    latency because the touch trace is one frame late on this path
- Moving hosted touch-move redraw off the input handler and onto a one-shot
  compositor frame source in
  `build/pixel/touch/scroll-benchmark-coalesce-0B191JEC203253-r2-20260420T012344Z`
  fixed the input-thread stall without materially improving displayed scroll
  age:
  - `scroll_frame_latency.routes.app-scroll.input_age_at_present` p50 improved
    only slightly from `48.311ms` to `47.291ms`; `render_to_present` moved from
    `45.919ms` to `45.072ms`
  - `touch_latency.routes.app-scroll.dispatch_to_flush` collapsed from
    `46.537ms` p50 to `0.516ms` p50, and the old touch bucket dropped from
    `115.526ms` p50 to `47.171ms`
  - `coalesced_move_count` still stayed `0`, so this benchmark did not actually
    hit a latest-wins coalescing regime; it mostly proved that the compositor is
    no longer spending move-handler time rendering inline
  - the remaining visible latency is still dominated by GPU render plus KMS
    present, not by input dispatch bookkeeping

Interpretation of the phase-2 experiment:

- Moving the TS app into the compositor does remove the old Wayland/dmabuf
  surface hop.
- CPU-hosted Blitz was the wrong implementation shape because it blocked the
  compositor thread.
- GPU-hosted Blitz plus a worker-backed render loop is much better, but it is
  only enough to get modestly ahead of the shipped shell lane, not the
  `~38ms` direct-runtime control case.
- That means phase 2 by itself is not the finish line. Rendering Blitz inside
  the compositor and then copying CPU pixels into the software shell still pays
  too much shell compose + dumb-buffer present cost.
- The logical-shell `2x` layout is worth keeping. The follow-up copy-micro-tune
  was not.
- The obvious "render BGRA and drop the CPU swizzle" idea is blocked deeper in
  the Vello/wgpu image-renderer pipeline than this branch should absorb.
- The next real performance step is compositor-native GPU scene composition, not
  more small CPU scheduling tweaks around hosted image rendering.
- There is one shell-only improvement worth keeping separate from scroll work:
  the guest compositor can now GPU-rasterize the shell scene and prewarm that
  render while the DRM boot splash is still on screen. In the home-only run
  `build/pixel/drm-guest/20260419T171226Z`, the expensive shell render moved to
  `shell-prewarm-stats` at about `355ms`, and the first visible `shell-home-frame`
  no longer paid that cost. In the follow-up shell smoke
  `build/pixel/drm-guest/20260419T171524Z`, the same prewarm path cost about
  `314ms` behind boot splash and the return-home shell render was about `153ms`.
  That helps home-screen cold start polish, but it does not change the main
  scroll diagnosis: focused apps are already on direct dmabuf present, and the
  remaining scroll work is not in the old shell software rasterizer.

Interpretation:

- Fast event dispatch plus slow present means input plumbing is usable, but the
  visible frame pipeline is not.
- The pure-GPU runtime probe suggests full-document TS rerender is not the
  first-order cause of slow scroll. The next suspects are app render cost during
  scroll and compositor/present cadence after dispatch.
- The updated direct-runtime probe with cheaper AA shows the app can scroll much
  better without the shell path. That shifts the supported-lane diagnosis even
  harder toward the per-app surface hop: render app frame, CPU-capture dmabuf,
  composite into shell, then present.
- Shell compositing is no longer the dominant cost after the fast-path work.
  The remaining supported-lane problem is: rerendering a large app surface every
  scroll frame, then CPU-capturing that surface for shell composition.
- Reducing the shell app surface to the logical viewport is a practical near-term
  mitigation and is now the default Pixel shell mode.
- Lowering Pixel Vello antialiasing from the previous default `Msaa16` to
  `Area` is another practical near-term mitigation. It materially cut app render
  time, but the supported shell lane is still too slow for truly smooth scroll.
- For scroll, measure the supported GPU shell lane directly. Per-frame PPM
  artifacts are now opt-in; use `sc -t pixel frame` or `sc -t <serial> frame`
  for snapshots.
- For shell/runtime async updates, avoid 100ms fixed polling. The Pixel shell
  default is now 16ms; touch-signal detection is event-driven on Linux/Pixel.
