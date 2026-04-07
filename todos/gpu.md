# GPU Integration Notes

Living note. This is not a polished design doc. It exists to capture what was tried, what was proved, what failed, and what should happen next.

## Goal

- Get the app-runtime lane rendering fast enough on the rooted Pixel 4a that interaction feels instant to a human.
- Prefer a simple fast path over a fancy architecture.
- Use real GPU acceleration if it is available and materially better.

## Current Conclusion

- True hardware GPU acceleration on the rooted Pixel is still not working under the current GNU/glibc userspace bundle.
- The best current real-device UX path is the plain CPU renderer.
- The rooted Pixel runtime demo now reaches first visible app frame in about `0.68s` and auto-click-to-visible-update in about `0.35s` on the real panel.
- `gpu_softbuffer` remains useful as a probe lane, not as the default operator path.
- Phase 1 of the finish plan is now in place:
  - the Blitz client emits compact `gpu-summary-start` / `gpu-summary-client` markers
  - the rooted Pixel session writes a compact `gpu-summary.json` with renderer, backend, adapter, software-vs-hardware classification, first-visible-frame latency, and click-to-updated-frame latency

## What We Tried

## 1. Host GPU renderer spike

- Swapped the host-visible runtime demo from `anyrender_vello_cpu` to `anyrender_vello`.
- Proved the same Solid + Deno + Blitz runtime session contract works with the GPU renderer on host.
- Result: host GPU path works. This proved the app model was not the problem.

## 2. Linux compositor GPU client spike

- Ran the GPU Blitz client under the Linux Smithay compositor smoke.
- Added smoke coverage for:
  - host GPU renderer
  - compositor GPU runtime demo
  - static GPU guest compositor smoke
- Result: the GPU client launches and maps under Linux, but the smoke host was not a trustworthy hardware GPU environment.

## 3. Guest compositor dmabuf-awareness spike

- Added linux-dmabuf awareness and buffer classification to `shadow-compositor-guest`.
- Added logging so the compositor could say whether a committed client buffer was SHM or DMA-backed.
- Result: on the Linux smoke host, the so-called GPU client still landed as `type=shm`, not `type=dma`.
- Interpretation: Smithay is not the blocker here; the current client/driver/backend path is.

## 4. Rooted Pixel static `wgpu` smoke

- Built a GNU-wrapped static Blitz demo for the rooted Pixel.
- Launched it under `shadow-compositor-guest`.
- Proved the phone panel could present captured `384x720` frames from that lane.
- Result: useful visible-screen proof, but not proof of real hardware acceleration.

## 5. Tried Vulkan / Turnip on the rooted Pixel

- Bundled the Vulkan loader, Turnip / Freedreno pieces, and related driver manifests.
- Forced `WGPU_BACKEND=vulkan`.
- Added instrumentation and root-side probes to see what the device nodes and driver stack actually looked like.
- Result:
  - `libvulkan_freedreno.so` loaded
  - `vkEnumeratePhysicalDevices` still failed
  - Turnip did not produce a usable Vulkan device in this environment

## 6. Probed the rooted Pixel DRM/KMS capabilities directly

- Added `just pixel-drm-probe`.
- Inspected `/dev/dri/card0`, `/dev/dri/renderD128`, and `/dev/kgsl-3d0`.
- Result:
  - `/dev/dri/card0` and `/dev/dri/renderD128` reported `name=msm_drm`
  - `DRM_CAP_SYNCOBJ=0`
  - timeline syncobj returned `EINVAL`
  - `/dev/kgsl-3d0` opened fine
- Interpretation: this matches the suspicion that the rooted Pixel's Linux DRM path is too weak for the Turnip path we wanted.

## 7. Tried GL through the GNU runtime bundle

- Built a GNU-wrapped Blitz path that set:
  - `WGPU_BACKEND=gl`
  - `LIBGL_DRIVERS_PATH`
  - EGL vendor manifests
  - Vulkan / GL runtime bundle plumbing
- Added the softbuffer image-renderer path for the rooted device:
  - `gpu_softbuffer`
- Result:
  - this path worked functionally
  - but Mesa fell back to surfaceless `swrast`
  - so it was still software-backed, not real hardware acceleration

## 8. Improved the GNU runtime bundle itself

- Switched from the older Deno-host bundling helper to the shared runtime-host Linux bundle helper.
- Added:
  - `HOME`
  - `XDG_CACHE_HOME`
  - `XDG_CONFIG_HOME`
  - `MESA_SHADER_CACHE_DIR`
- Precreated those directories on-device.
- Flattened bundle symlinks and filled runtime deps more aggressively.
- Result:
  - Mesa shader cache is now actually populated on-device
  - but this did not solve the giant first-frame stall in the `gpu_softbuffer` path

## 9. Added boot splash / compositor-visible startup feedback

- Added a compositor-side DRM boot splash frame.
- Published it before the client was ready.
- Result:
  - this improved perceived startup because the panel no longer sat blank
  - but it did not solve the real first interactive frame latency

## 10. Measured the real performance bottleneck

- Added targeted timing logs around:
  - runtime session startup
  - document creation
  - render-to-vec
  - present
  - dispatch and rerender
- Main finding on rooted Pixel `gpu_softbuffer`:
  - runtime session was fast
  - touch / dispatch were fast
  - the first visible render was awful, around `8.3s`
  - subsequent renders were much faster
- Conclusion: the app model was fine; the rooted Pixel `gpu_softbuffer` startup path was the real problem.

## 11. Benchmarked the plain CPU renderer on the rooted Pixel

- Fixed the Pixel runtime launcher so it could target `cpu` as well as `gpu_softbuffer`.
- Ran apples-to-apples rooted device smokes with the CPU renderer.
- Result:
  - first `render_to_vec` dropped from roughly `8.3s` to roughly `0.33s`
  - this immediately proved that `gpu_softbuffer` under current rooted Pixel conditions was the wrong default

## 12. Removed self-inflicted startup slop from the Pixel runtime demo

- Removed the unconditional startup-only target hitmap scan.
- Disabled Android system-font loading for the Pixel runtime demo.
- Disabled the old default 40ms app-side runtime poll thread.
- Disabled the duplicate document-side touch-signal timer unless explicitly enabled.
- Result on rooted Pixel:
  - runtime session ready: about `86ms`
  - document ready: about `120ms`
  - first visible app frame: about `0.68s`
  - auto-click dispatch to visible updated frame: about `0.35s`

## What Worked

- Host GPU renderer path.
- Linux compositor GPU client smoke as a control-plane proof.
- Rooted Pixel static `wgpu` visible-screen proof.
- Rooted Pixel `gpu_softbuffer` as a diagnostic lane.
- Rooted Pixel CPU renderer as the actually fast default path.

## What Did Not Work

- Real Turnip/Freedreno Vulkan device creation under the current rooted GNU userspace.
- Using the rooted Pixel `gpu_softbuffer` path as the default fast path.
- Relying on Mesa shader cache alone to make `gpu_softbuffer` cold-start acceptable.

## Why The Current Fast Path Is CPU

- The rooted Pixel GPU story is still blocked by low-level driver/backend reality, not by Solid, Deno, or Blitz.
- Under the current GNU userspace:
  - `gpu_softbuffer` is functional but software-backed
  - Vulkan / Turnip is not usable
- So the simplest fast solution is:
  - keep the runtime/app model
  - keep the rooted compositor path
  - use the CPU renderer by default on device

## Current Operator Guidance

- Rooted Pixel runtime demo default: `cpu`
- Keep `gpu_softbuffer` as an explicit experiment / probe path
- Treat the real device-performance target as:
  - first visible frame under 1s
  - rerender around a few hundred ms or better

## Remaining GPU Questions

- Can the rooted Pixel use a different Vulkan path that prefers KGSL successfully?
- Is an Android-native / bionic GPU client path required for real Adreno acceleration?
- Can the guest compositor ever import a truly GPU-backed client buffer on the rooted Pixel path?
- If true hardware acceleration becomes available, does it materially beat the current CPU path enough to justify the extra complexity?

## Recommended Next Steps

- Keep the Pixel runtime demo on the CPU renderer by default.
- Keep the GPU probe tools and notes in-tree.
- Do not block app-runtime progress on true GPU acceleration.
- Only revisit the GPU lane when there is a credible way to get:
  - a real Vulkan device on the rooted Pixel
  - or a real Android-native GPU client path

## Files Touched During This Investigation

- `scripts/pixel_runtime_app_drm.sh`
- `scripts/pixel_prepare_blitz_demo_gpu_softbuffer_bundle.sh`
- `scripts/pixel_runtime_linux_bundle_common.sh`
- `scripts/pixel_drm_probe.sh`
- `scripts/pixel_openlog_preload.c`
- `ui/apps/shadow-blitz-demo/src/app.rs`
- `ui/apps/shadow-blitz-demo/src/frame.rs`
- `ui/apps/shadow-blitz-demo/src/runtime_document.rs`
- `ui/crates/shadow-compositor-guest/src/kms.rs`
- `ui/crates/shadow-compositor-guest/src/main.rs`

## Best Known Numbers

- Rooted Pixel runtime session ready: `~86ms`
- Rooted Pixel runtime document ready: `~120ms`
- Rooted Pixel first visible app frame: `~0.68s`
- Rooted Pixel auto-click to visible updated frame: `~0.35s`
- Old rooted Pixel `gpu_softbuffer` first frame: roughly `8.3s`

## Plan To Finish This Feature

Hard requirement:

- GPU rendering is still the target end state.
- The current CPU path is a pragmatic stopgap so the runtime demo is usable while the real GPU work continues.
- We should only accept the current state as "finished" if the Pixel is actually using hardware-backed rendering and interaction feels instant.

Success bar:

- First visible app frame comfortably under `500ms`.
- Tap / click to visible update under `100ms`, ideally closer to one frame budget.
- No Mesa `swrast` fallback in the production device path.
- A reproducible operator command that uses the fast hardware-backed path by default.

### Phase 1. Tighten observability around the real backend

- Add one compact Pixel smoke summary that prints:
  - selected renderer
  - `wgpu` backend
  - adapter name / driver
  - whether the client path is software or hardware-backed
  - first visible frame latency
  - click-to-updated-frame latency
- Log this directly from the Blitz client and the rooted session so we do not need to infer it from long raw logs.
- Keep the current CPU default until the GPU lane can beat it reliably.

Status:

- Done.
- `scripts/pixel_runtime_summary.py` now emits `gpu-summary.json` for rooted runs.
- The summary includes backend, adapter, software-vs-hardware classification, first-visible-frame latency, click latency, and now openlog visibility for `/dev/dri` vs `/dev/kgsl`.

### Phase 2. Build an honest static rooted-Pixel GPU probe harness

- Add a script-only probe lane for the static GNU `wgpu` client.
- Keep the base bundle fixed and vary only the backend profile / env, so we can compare runs without changing too many variables at once.
- First profiles:
  - `gl`
  - `vulkan_drm`
  - `vulkan_kgsl_first`
  - optional `_early_probe` variants when we explicitly want the crashy early adapter-init diagnostics
- For each profile, record:
  - run dir
  - session status
  - parsed `gpu-summary.json`
  - whether `/dev/dri` or `/dev/kgsl` was opened or denied
    - note: current openlog visibility is session-wide, not yet perfectly client-scoped
- Write one matrix summary artifact per probe batch so the next seam is driven by facts, not hand-reading raw logs.

Status:

- In progress, but the real backend picture is much sharper now.
- `scripts/pixel_blitz_demo_static_drm_gpu_probe.sh` now runs the static Pixel GPU probe profiles and writes a per-batch `matrix-summary.json`.
- `just pixel-blitz-demo-static-drm-gpu-probe` runs a selected profile.
- `just pixel-blitz-demo-static-drm-gpu-matrix` runs the default profile set.
- The default probe profiles are now intended to stay non-invasive so they measure the real static client path. The `_early_probe` variants keep the old adapter-summary experiment available, but no longer poison the default matrix.
- The matrix payload now distinguishes `success` from `classified` and `measured` so a successful static run is not misread as a completed backend classification.
- The probe wrapper no longer hangs forever after a good run. `pixel_guest_ui_drm.sh` now bounds the post-success session wait and forces cleanup / host-side Android restore if the rooted shell never returns on its own.
- The runtime bundle transport is now fixed too:
  - `pixel_push.sh` no longer recursively `adb push`es the giant GNU bundle tree
  - it stages one tar archive, extracts it on-device under root, and then normalizes permissions
  - this removed the false-negative bundle/push failures that were masking the real GPU behavior
- The rooted-Pixel static `gl` probe is now honestly classified:
  - run success: yes
  - backend: `gl`
  - `/dev/kgsl-3d0`: not opened
  - `/dev/dri/renderD128` and `/dev/dri/card0`: opened
  - `libEGL`: `failed to create dri2 screen`
  - compositor buffer type: `shm`
  - first visible frame: about `11.6s`
  - conclusion: this path is software-backed fallback, not usable hardware acceleration
- The rooted-Pixel static `vulkan_drm` probe is now honestly classified:
  - run success: no
  - backend: `vulkan`
  - failure: `NoCompatibleDevice`
  - no visible frame
- The rooted-Pixel static `vulkan_kgsl_first` probe is now honestly classified:
  - run success: no
  - backend: `vulkan`
  - `/dev/kgsl-3d0`: opened
  - failure: `NoCompatibleDevice`
  - no visible frame
- The KGSL-first probe needed one launcher fix:
  - raw `LD_PRELOAD` hit `/system/bin/sh` first and failed because the preload library is glibc-linked
  - the launcher now accepts `SHADOW_LINUX_LD_PRELOAD` and applies it only inside the GNU payload
  - this removed the bionic/glibc preload collision and let the KGSL probe reach the actual adapter-discovery seam

### Phase 2. Exhaust the rooted Pixel GPU paths in order

- Prove or disprove a usable rooted Vulkan path under the current Linux/GNU environment.
- Try the smallest possible static client first, not the full runtime app:
  - `wgpu` + Vello window renderer
  - `wgpu` + image renderer
  - minimal clear-color / rect-only test before text
- Explicitly test these backend configurations:
  - Vulkan through the DRM render node path
  - Vulkan through any KGSL-usable path we can coerce
  - GL path with current GNU bundle
- Record for each:
  - adapter selected
  - whether it is `swrast`
  - first-frame latency
  - whether presentation is stable

### Phase 3. If hardware-backed Vulkan becomes real, wire the fast app path

- Once a static hardware-backed client works on the Pixel, switch the runtime demo from the CPU renderer to the true GPU renderer on device.
- Re-measure the real metrics on the rooted Pixel with the runtime demo:
  - launch to first visible frame
  - tap to updated frame
  - repeated rerenders
- Only then remove the CPU default.

### Phase 4. If the GNU/Linux path cannot reach real hardware, try the narrower escape hatch

- Build a very small Android-native / bionic GPU proof instead of pushing harder on the current GNU userspace bundle.
- Goal:
  - vendor Adreno Vulkan stack
  - hardware adapter selection
  - simple visible frame on the panel
- If that works, evaluate whether the app client can live behind a thin Android-native launcher while keeping the current app-runtime model above it.

### Phase 5. Decide whether the Pixel is a dead end

- Stop if all of these remain true after the KGSL / Android-native spikes:
  - Vulkan still cannot produce a real hardware adapter
  - GL still falls back to `swrast`
  - every "GPU" path is slower or more fragile than the CPU path
- If that happens, the honest conclusion is:
  - the app model is fine
  - this Pixel 4a bring-up path is the blocker
  - we should move to a different device rather than keep burning time here

### What A Replacement Device Must Have

- Unlockable / rootable without heroic effort.
- A GPU stack that exposes a usable hardware-backed path from our target environment.
- Preferably a Linux-visible render node with modern syncobj support.
- If not, then an Android-native Vulkan path we can realistically target without rewriting the whole app model.

### Immediate Next Steps

- Keep the compact Pixel GPU summary output and use it as the default measurement lane.
- Do not spend more time pretending the current GNU `gl` path might become fast; it is now clearly DRI-only software fallback on this phone.
- Treat the current rooted GNU `vulkan` result as: KGSL is reachable, but still not sufficient for `wgpu` / Vello adapter creation.
- Next real seam:
  - small Android-native / bionic Vulkan proof on the Pixel
  - prove whether the vendor Adreno stack can produce a real hardware adapter there
- If that works, evaluate a thin Android-native launcher beneath the current app-runtime model.
- If that still fails, stop burning time on this Pixel GPU path and move to the replacement-device criteria above.
