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
