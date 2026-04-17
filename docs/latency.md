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
- `softbuffer_latency.render_to_vec`: app-side CPU raster time before softbuffer present.
- `compositor_frame_latency.capture_to_artifact`: compositor capture to PPM artifact write when continuous artifacts are explicitly enabled.
- `compositor_frame_latency.capture_to_present`: compositor frame capture to DRM present.
- `runtime_session_latency`: host session request cost by operation.

Current gpu-softbuffer Pixel 4a result from `build/latency/probe-timeline-4`:

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

Interpretation:

- Fast event dispatch plus slow present means input plumbing is usable, but the
  visible frame pipeline is not.
- For scroll, prioritize getting off CPU softbuffer. Per-frame PPM artifacts are
  now opt-in; use `sc -t pixel frame` or `sc -t <serial> frame` for snapshots.
- For shell/runtime async updates, avoid 100ms fixed polling. The Pixel shell
  default is now 16ms; touch-signal detection is event-driven on Linux/Pixel.
