---
summary: High-level architecture for the Shadow bring-up repo
read_when:
  - starting work on the project
  - need to understand the boot iteration loop
---

# Architecture

`shadow` is the narrow bring-up repo for early Android boot experimentation and the first reusable UI/compositor ladder.

The current workflow has four layers:

1. The flake defines the pinned toolchain used locally and on Hetzner.
2. `just` exposes the stable operator interface.
3. Shell scripts orchestrate artifact fetch, `init_boot` repacking, and Cuttlefish launch.
4. Hetzner runs the Cuttlefish guest used for stock and repacked boot verification.

Alongside the boot flow, `ui/` now carries the shell workspace:

1. `ui/crates/shadow-ui-core` defines shell state, app metadata, palette, and the scene graph.
2. `ui/crates/shadow-ui-core/src/control.rs` defines the lightweight compositor control protocol used to launch apps by identity.
3. `ui/crates/shadow-ui-desktop` is the fast desktop host for shell iteration.
4. `ui/crates/shadow-compositor` is the Linux-only Smithay host that starts the compositor bring-up path.
5. `scripts/ui_smoke.sh` is the headless Linux/Hetzner runtime proof for compositor plus app launch.
6. `vm/shadow-ui-vm.nix` plus `scripts/ui_vm_*.sh` define a local macOS QEMU loop for UX work when Cuttlefish is too slow.

The current milestones are:

- boot stock Cuttlefish with stock and modified `init_boot.img` variants
- prove our Rust `/init` wrapper runs before handing off to stock Android
- keep the shell logic portable between a desktop host and a compositor host
- prove the compositor can auto-launch one Wayland client in a headless Linux smoke before moving that session logic into the guest
- prove a late-start Rust guest session can launch `drm_rect` after stock boot, take DRM master from the Android graphics stack, and report a successful modeset on Cuttlefish
- prove the guest can launch the Rust compositor and one guest Wayland client after stock boot, with matching compositor/client frame checksums and a pulled frame artifact
- prove the same late-start compositor plus guest-client loop on a stock, bootloader-locked Pixel 4a over plain `adb shell`, without root or `adb root`

The current operator ladder reflects that split:

1. `just cf-init-wrapper` keeps the first-stage `init_boot` proof small and reliable.
2. `just cf-drm-rect` boots stock Android, uses `adb root`, stops the Android graphics services that hold DRM master, then runs `shadow-session` plus `drm-rect`.
3. `just cf-guest-ui-smoke` boots stock Android, uses `adb root`, starts `shadow-session` plus `shadow-compositor-guest`, auto-launches one guest Wayland client, and saves the captured frame artifact under `build/guest-ui/`.
4. `just cf-guest-ui-drm-smoke` proves the same guest compositor path can also present to DRM/KMS.
5. `just ui-vm-run` is the fast local macOS loop for compositor and shell UX work; it is intentionally outside CI.
6. `scripts/shadowctl` plus `just ui-vm-doctor` / `ui-vm-state` / `ui-vm-wait-ready` / `ui-vm-screenshot` provide the current CLI observability layer for the local VM.
7. `just runtime-app-compositor-smoke-gpu` is the current Linux GPU renderer proof for the app-runtime lane: run the runtime Blitz demo as a GPU Wayland client under the headless Smithay compositor and assert launch, map, and runtime click dispatch.
8. `just pixel-doctor` / `pixel-build` / `pixel-push` / `pixel-run` / `pixel-loop` are the current real-device operator ladder for post-boot iteration on a plugged-in Pixel.
9. `just pixel-drm-rect` is the first rooted visible-screen proof on the Pixel: stop the Android display services, take DRM master, modeset the panel, then hand control back.
10. `just pixel-guest-ui-drm-selftest` is the first compositor-owned rooted visible-screen rung on the Pixel: same display takeover seam, same guest compositor KMS code, but no Wayland client yet.
11. `just pixel-guest-ui-drm` reuses that rooted display-takeover seam for the real compositor path and proves the guest compositor plus counter client can render to the phone panel, not just to an offscreen artifact.
12. `just pixel-*-hold` plus `just pixel-restore-android` split takeover from restore so the panel can stay under our control long enough for human-visible QA instead of immediately jumping back to Android.
13. `just pixel-runtime-deno-core-smoke` is the first runtime-on-device rung that does not touch the display stack: it proves a minimal `deno_core` binary plus file-backed JS modules can execute on the rooted phone through a Linux/glibc envelope.
14. `just pixel-runtime-deno-runtime-smoke` builds on that same rooted GNU envelope and proves the first minimal `deno_runtime` seam on the phone: runtime snapshot, file-backed ES modules, `Deno.readTextFile`, timers, and event-loop drain.
15. `just runtime-app-compile-smoke` is the first host-side app-runtime rung: it proves a Solid-style TSX module can compile under Deno into a custom-renderer contract without assuming a browser runtime.
16. `just runtime-app-document-smoke` is the next host-side rung: it proves the compiled app bundle can execute through the embedded `deno_core` runtime and return the first `{ html, css }` document payload before Blitz is involved.
17. `just runtime-app-blitz-document-smoke` is the first Rust-side Blitz bridge rung: it proves a fixed-frame `HtmlDocument` can swap runtime CSS and app HTML into persistent frame slots before a visible host window is involved.
18. `just runtime-app-host-run` and `just runtime-app-host-smoke` are the first visible host proof: prepare the bundled app plus the tiny `deno_core` helper, launch a runtime-mode Blitz window backed by the new frame seam, and keep the same JS session alive behind the visible host app.
19. `just runtime-app-click-smoke` is the first reactive host proof: keep the bundled app alive inside one `deno_core` session, dispatch a host click into the JS handler table, and verify the rerendered HTML snapshot changes.
20. `just runtime-app-input-smoke` is the first text-input host proof: dispatch a host `change` event with a string value into the same bundled runtime seam and verify both the form control state and rendered preview update.
21. `just pixel-runtime-app-drm` stages that same bundled app plus a GNU-wrapped `deno_core` helper for the rooted phone, pushes both through the existing device artifact lane, and proves the runtime-mode Blitz demo reaches the real panel.
22. `just pixel-runtime-app-click-drm` proves the rooted panel path survives one runtime click dispatch and rerender before Android display services are restored.
23. `just pixel-touch-input-smoke` is the first rooted input seam for the app-runtime lane: auto-detect the direct-touch evdev node, capture one raw touch sequence, and prove the phone panel can feed usable contact data back into our stack.

This is intentionally not yet a full custom userland boot. The repo is using the smallest reliable transport at each layer: first-stage wrapper for `/init` proof, then post-boot guest session launch for display and compositor iteration.

For the current stock-Pixel path, one implementation detail matters:

1. Stock Android SELinux allows the `shell` user to execute our static Rust binaries from `/data/local/tmp`, but denies creation of pathname Unix sockets there.
2. The guest compositor therefore has a second Wayland transport mode that skips `XDG_RUNTIME_DIR` sockets and hands the child client an inherited `WAYLAND_SOCKET` file descriptor instead.
3. That direct-FD transport is the current non-root path on real hardware; the old pathname socket path remains valid for Linux host and VM workflows.

This also sets the current boundary for the Blitz + Deno demo on device:

1. The sibling Blitz prototype launches `deno` as a subprocess and reads its TypeScript entrypoint from the source tree at runtime.
2. Official Deno Linux arm64 releases are dynamically linked against GNU libc (`/lib/ld-linux-aarch64.so.1`) and do not execute in the stock Android shell environment on the Pixel 4a.
3. The first proven device-side runtime seam in this repo is now a rooted GNU envelope: push a Linux ARM64 binary, its ELF loader, the small glibc closure it needs, and its JS modules into `/data/local/tmp`, then invoke the loader directly.
4. The first proven app-model seam on the host is now the compile step: Deno runs Babel with `babel-preset-solid` in universal mode and emits imports for a custom renderer module instead of a browser DOM target.
5. The next proven host seam is the first document payload: compile the app, rewrite runtime alias imports, bundle the app plus the renderer shim into one local JS file, run that through the embedded `deno_core` runtime, and read `{ html, css }` back out without a browser.
6. The first proven Rust-side Blitz seam on the host is now a fixed frame with stable style/root slots: mutate those slots with `set_inner_html`, keep the outer document persistent, and leave visible host integration for the next rung.
7. The first visible host proof now composes that seam into a real window with the real runtime attached: a helper `deno_core` process keeps the bundled app alive, Rust owns the persistent Blitz frame, and the host swaps in each returned HTML snapshot.
8. The first reactive host proof now uses that same helper session end-to-end: host-dispatched click events target `data-shadow-id` nodes, JS handlers mutate Solid state, and the app emits a fresh HTML snapshot back into the Blitz document.
9. The first form/input proof keeps that same contract intentionally small: host `change` events may carry a string `value`, the runtime updates the target element state before invoking the JS handler, and the app emits the next HTML snapshot.
10. The helper backend is now swappable on the host: the same `render` / `dispatch` stdio session contract works with either `deno_core` or `deno_runtime`, so runtime capability experiments no longer need a separate Blitz bridge.
11. The first renderer swap spike now exists on host and on Linux compositor smoke: `just runtime-app-host-smoke renderer=gpu` and `just runtime-app-compositor-smoke-gpu` keep the same runtime session contract and Blitz document seam but swap the window renderer from `anyrender_vello_cpu` to `anyrender_vello`.
12. `shadow-compositor-guest` now also advertises a small linux-dmabuf global and logs the type of each committed client buffer. The first guest-compositor GPU smoke proved the compositor can classify that path, but on the current headless Linux host the static GPU Blitz demo still lands as `type=shm`, not `type=dma`.
13. The rooted Pixel now has a working static `wgpu` smoke too: `scripts/pixel_blitz_demo_static_drm_gpu_softbuffer.sh` pushes a GNU-wrapped Blitz demo, launches it under `shadow-compositor-guest`, and proves the guest compositor can capture and present `384x720` frames on the phone panel.
14. That rooted Pixel GPU smoke is still not true hardware acceleration, but the exact failure modes are now much sharper. The current `gl` softbuffer path opens `/dev/dri/renderD128` and `/dev/dri/card0`, never opens `/dev/kgsl-3d0`, logs `libEGL ... failed to create dri2 screen`, lands on compositor-observed `type=shm`, and still takes about `11.6s` to first visible frame. So that lane is now honestly classified as a slow software fallback, not a maybe-accelerated path.
15. The attempted rooted GNU `vulkan` path is now sharper too. The plain `vulkan_drm` probe reaches the client and fails with `NoCompatibleDevice`. The targeted `vulkan_kgsl_first` probe now proves the GNU client can open `/dev/kgsl-3d0`, but `wgpu` / Vello still ends in the same `NoCompatibleDevice` failure. So the blocker is no longer "maybe KGSL is invisible"; the blocker is that this rooted GNU userspace still cannot turn that visibility into a usable hardware adapter.
16. `just pixel-drm-probe` still gives the hard device-side clue for the DRM path: on the rooted Pixel 4a, both `/dev/dri/card0` and `/dev/dri/renderD128` report `name=msm_drm` with `DRM_CAP_SYNCOBJ=0`, and `DRM_CAP_SYNCOBJ_TIMELINE` returns `EINVAL`. That lines up with Turnip's DRM syncobj requirement and explains why the current GNU Mesa bundle does not discover a usable Vulkan device through the DRM render-node path.
17. The rooted Pixel runtime app lane still has a working `gpu_softbuffer` mode, but under the current GNU userspace it remains a software-backed probe lane, not the fastest operator loop. The current best real-device UX path is the plain CPU renderer. On the rooted Pixel 4a, disabling the old startup-only hitmap scan, skipping Android font-directory loading for the runtime demo, and removing the duplicate 40ms poll/touch timers brought the first visible app frame down from multi-second startup stalls to about `0.68s` from launch, with click-to-visible-update around `0.35s` on the real panel.
18. The first GPU-finish observability rung is now landed too: the Blitz client emits compact `gpu-summary-start` / `gpu-summary-client` markers, the rooted Pixel session writes a `gpu-summary.json` artifact, and the static GPU probe can now also record openlog evidence for `/dev/dri` vs `/dev/kgsl`, EGL fallback warnings, and compositor buffer type. That is enough to classify the current `gl` lane as software fallback and the current `vulkan` lanes as adapter-discovery failures without hand-parsing long raw logs.
19. Full-root HTML snapshots still win the MVP tradeoff after the device proof. Host and rooted-Pixel click rerenders both complete fast enough that a Rust-side patch bridge would be premature; the next pressure point is likely text input, focus, or more animated apps rather than simple card flows.
20. Touch now works end-to-end on the rooted Pixel path: the guest compositor creates a real Smithay seat plus pointer, detects the direct-touch panel, starts a rooted helper that tails the touchscreen evdev node, applies the same centered/cropped panel-to-client mapping that KMS presentation uses, and the runtime demo visibly flips state from a real finger tap.

For the newly unlocked-and-rooted Pixel track, the intended operator ladder is now:

1. `just pixel-root-prep` downloads the exact full OTA, extracts the matching `boot.img`, and caches the current Magisk APK.
2. `just pixel-ota-sideload` is still the only step that needs direct interaction on the phone, because recovery has to be put into `Apply from ADB`.
3. `just pixel-root-patch` unpacks Magisk's own patch assets from the APK, pushes them to `/data/local/tmp`, runs `boot_patch.sh` under `adb shell`, and pulls the resulting `new-boot.img` back to the host.
4. `just pixel-root-flash` flashes the patched image to the explicit active-slot `boot_a` or `boot_b` partition, reboots Android, installs the Magisk app, and verifies `su`.

This removes the old requirement to manually patch `boot.img` inside the Magisk app, while keeping `just pixel-root-stage` as a fallback if the non-interactive patch path ever breaks.

One device-specific detail emerged on the real Pixel 4a:

1. Stopping only `surfaceflinger` is not enough to free the panel for DRM/KMS takeover.
2. The working rooted handoff currently stops `surfaceflinger`, `bootanim`, `vendor.hwcomposer-2-4`, and `vendor.qti.hardware.display.allocator`.
3. On this Qualcomm display stack, a connector can also report an encoder without a current CRTC even though the panel is usable; the KMS path now falls back to the first CRTC allowed by `possible_crtcs`.
4. For rooted QA, leaving Android stopped is sometimes the right behavior. The new hold-mode loop is `just pixel-...-hold` to seize the panel, inspect the result, then `just pixel-restore-android` to hand control back.

For the local VM specifically, the first visible frame can lag behind boot because the guest may still be compiling `shadow-ui-desktop` or app binaries from the mounted source tree. The current operator contract is:

1. `just ui-vm-run` launches the VM window.
2. `just ui-vm-doctor` explains whether the compositor is still compiling or already live.
3. `just ui-vm-wait-ready` blocks until the compositor control socket and the nested Wayland session are usable.
4. `just ui-vm-screenshot` captures the current QEMU window via QMP for outside-in inspection.
