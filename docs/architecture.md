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
7. `just runtime-app-host-smokes` is the current bundled host-runtime proof surface: it runs the keyboard, GM, and timeline smokes that exercise the live app contract end to end.
8. `just pixel-doctor` / `pixel-build` / `pixel-push` are the current real-device operator ladder for post-boot iteration on a plugged-in Pixel.
9. `just pixel-drm-rect` is the first rooted visible-screen proof on the Pixel: stop the Android display services, take DRM master, modeset the panel, then hand control back.
10. `just pixel-guest-ui-drm-selftest` is the first compositor-owned rooted visible-screen rung on the Pixel: same display takeover seam, same guest compositor KMS code, but no Wayland client yet.
11. `just pixel-guest-ui-drm` reuses that rooted display-takeover seam for the real compositor path and proves the guest compositor plus counter client can render to the phone panel, not just to an offscreen artifact.
12. `just pixel-*-hold` plus `just pixel-restore-android` split takeover from restore so the panel can stay under our control long enough for human-visible QA instead of immediately jumping back to Android.
13. `just pixel-runtime-deno-core-smoke` is the first runtime-on-device rung that does not touch the display stack: it proves a minimal `deno_core` binary plus file-backed JS modules can execute on the rooted phone through a Linux/glibc envelope.
14. `just pixel-runtime-deno-runtime-smoke` builds on that same rooted GNU envelope and proves the first minimal `deno_runtime` seam on the phone: runtime snapshot, file-backed ES modules, `Deno.readTextFile`, timers, and event-loop drain.
15. `just pixel-linux-audio-spike` is the first Linux-direct audio probe on the rooted phone: it stages a small ALSA tone player plus copied ALSA userspace into the GNU envelope, runs that probe under the same rooted display-takeover seam, and reports whether direct Linux playback can reach the device speaker without any Android bridge.
16. `just runtime-app-keyboard-smoke` is the narrow bundled-host rung: it proves focus, keydown, text input, selection metadata, and blur semantics through the live runtime session.
17. `just runtime-app-nostr-gm-smoke` is the async host rung: it proves a click can drive the current Nostr publish seam and surface a completion state back into the app.
18. `just runtime-app-nostr-timeline-smoke` is the main host proving ground: it proves relay sync, keyboard-driven compose, and cold-restart cache reload through the same bundled runtime contract.
19. `just pixel-shell-drm` is now the primary rooted Pixel shell rung: stage the counter and timeline runtime bundles plus the GNU-wrapped helper, boot the guest compositor into the home scene, and present the real shell/home path on the phone panel. `just run app=timeline target=pixel` now uses that same shell rung and asks the shell to open `timeline`.
20. `just pixel-shellctl ...` is the rooted Pixel shell control seam: it talks to the guest compositor's `shadow-control.sock` over `adb shell` plus `nc -U`, so operators can query state, go home, or launch an app without falling back to touch-only QA.
21. `just pixel-shell-timeline-smoke` is the first rooted lifecycle proof on that shell lane: start `timeline`, go home, and reopen it through the live shell control path.
22. `just pixel-runtime-app-drm` remains as a narrower fallback/probe rung for direct runtime-app work on the rooted phone: fit the shell app viewport contract into the real panel, pass the same fitted size to both the guest compositor and the runtime client, and prove the runtime-mode Blitz demo reaches the real panel.
23. `just pixel-runtime-app-click-drm` proves the rooted panel path survives one runtime click dispatch and rerender before Android display services are restored.
24. `just pixel-touch-input-smoke` is the first rooted input seam for the app-runtime lane: auto-detect the direct-touch evdev node, capture one raw touch sequence, and prove the phone panel can feed usable contact data back into our stack.
25. `just runtime-app-sound-smoke` plus `just pixel-runtime-app-sound-drm` are the first runtime-audio seam: a runtime app now calls `Shadow.os.audio`, the host proves the handle API against an in-memory backend, and the rooted Pixel sound lane swaps to the Linux-direct helper without adding a JVM bridge.
26. That sound lane is no longer tone-only. The sound demo now stages one generated audio file into the runtime bundle, passes a bundle-relative `source.kind="file"` path through the same OS API seam, and rooted Pixel auto-click runs prove the runtime host spawns the file-backed Linux helper on the phone panel path.

This is intentionally not yet a full custom userland boot. The repo is using the smallest reliable transport at each layer: first-stage wrapper for `/init` proof, then post-boot guest session launch for display and compositor iteration.

For the current stock-Pixel path, one implementation detail matters:

1. Stock Android SELinux allows the `shell` user to execute our static Rust binaries from `/data/local/tmp`, but denies creation of pathname Unix sockets there.
2. The guest compositor therefore has a second Wayland transport mode that skips `XDG_RUNTIME_DIR` sockets and hands the child client an inherited `WAYLAND_SOCKET` file descriptor instead.
3. That direct-FD transport is the current non-root path on real hardware; the old pathname socket path remains valid for Linux host and VM workflows.

This also sets the current boundary for the Blitz + Deno demo on device:

1. The sibling Blitz prototype launches `deno` as a subprocess and reads its TypeScript entrypoint from the source tree at runtime.
2. Official Deno Linux arm64 releases are dynamically linked against GNU libc (`/lib/ld-linux-aarch64.so.1`) and do not execute in the stock Android shell environment on the Pixel 4a.
3. The first proven device-side runtime seam in this repo is now a rooted GNU envelope: push a Linux ARM64 binary, its ELF loader, the small glibc closure it needs, and its JS modules into `/data/local/tmp`, then invoke the loader directly.
4. The live host app-model seam now starts with `scripts/runtime_prepare_host_session.sh`: compile the TSX entrypoint, bundle it, and resolve the current `shadow-runtime-host` binary used by the host smokes.
5. `just runtime-app-keyboard-smoke` is the narrow bundled-host proof: focus, keyboard metadata, text input, selection bookkeeping, and blur all round-trip through the live runtime session.
6. `just runtime-app-nostr-gm-smoke` reuses that same session contract to prove click-driven async state and the current small Nostr publish seam.
7. `just runtime-app-nostr-timeline-smoke` is the broader proving ground: relay sync, keyboard-driven compose, and cold-restart cache reload all happen through the same bundled host lane.
8. The older split `document` / `click` / `input` / `focus` / `toggle` / `selection` host recipes are no longer part of the live operator surface; the public proofs are the app-level host smokes above.
9. `shadow-compositor-guest` now also advertises a small linux-dmabuf global and logs the type of each committed client buffer. The first guest-compositor GPU smoke proved the compositor can classify that path, but on the current headless Linux host the static GPU Blitz demo still lands as `type=shm`, not `type=dma`.
10. The rooted Pixel now has a working static `wgpu` smoke too: `scripts/pixel_blitz_demo_static_drm_gpu_softbuffer.sh` pushes a GNU-wrapped Blitz demo, launches it under `shadow-compositor-guest`, and proves the guest compositor can capture and present `384x720` frames on the phone panel.
11. The rooted Pixel GPU story is now split cleanly into a bad lane and a good lane. The bad lane is `WGPU_BACKEND=gl` through the softbuffer client: it opens `/dev/dri/renderD128` and `/dev/dri/card0`, never opens `/dev/kgsl-3d0`, logs `libEGL ... failed to create dri2 screen`, lands on compositor-observed `type=shm`, and takes about `11.6s` to first visible frame. That lane is software fallback, not usable acceleration.
12. The good lane is vendor Turnip + Vulkan + KGSL + `gpu_softbuffer`. After fixing the bundle closure, rewriting the ICD JSON after the Turnip overlay, and scrubbing the GPU loader env before spawning the GNU runtime host, the rooted static probe now reports `adapter_name="Turnip Adreno (TM) 618"`, `driver="turnip Mesa driver"`, `hardware_backed=true`, and `openlog_kgsl_seen=true` on the real Pixel 4a.
13. The rooted runtime app lane now works on that same GPU path too. The current default `scripts/pixel_runtime_app_drm.sh` path switches to `gpu_softbuffer` automatically when the cached Turnip tarball is present, prefers `WGPU_BACKEND=vulkan`, forces the KGSL-preferred setup, and now reaches first visible app frame in about `943ms` with auto-click-to-visible-update around `38ms` on the real panel.
14. `just pixel-drm-probe` still explains why the original DRM-oriented Turnip path was brittle: on the rooted Pixel 4a, both `/dev/dri/card0` and `/dev/dri/renderD128` report `name=msm_drm` with `DRM_CAP_SYNCOBJ=0`, and `DRM_CAP_SYNCOBJ_TIMELINE` returns `EINVAL`. That matches Turnip's DRM syncobj requirement and explains why the successful path is the KGSL-preferred Vulkan lane, not the default DRM render-node lane.
15. The first GPU-finish observability rung is now landed too: the Blitz client emits compact `gpu-summary-start` / `gpu-summary-client` markers, rooted runs write `gpu-summary.json`, and both static and runtime GPU runs now record enough evidence to classify the backend, adapter, software-vs-hardware state, `/dev/dri` vs `/dev/kgsl` activity, first-visible-frame latency, and click-to-updated-frame latency without hand-parsing raw logs.
16. The compositor still observes client buffers as `type=shm` on the successful GPU path, so the next renderer-quality seam is transport/import quality rather than “can the rooted Pixel do hardware-backed rendering at all?”
17. Full-root HTML snapshots still win the MVP tradeoff after the device proof. Host and rooted-Pixel click rerenders both complete fast enough that a Rust-side patch bridge would be premature; the next pressure point is likely text input, focus, or more animated apps rather than simple card flows.
18. Touch now works end-to-end on the rooted Pixel path: the guest compositor creates a real Smithay seat plus pointer, detects the direct-touch panel, starts a rooted helper that tails the touchscreen evdev node, applies the same centered/cropped panel-to-client mapping that KMS presentation uses, and the runtime demo visibly flips state from a real finger tap.
19. The rooted Pixel now also has a real shell/home rung. `scripts/pixel_shell_drm.sh` stages the counter + timeline bundles plus the runtime host helper, sets `SHADOW_GUEST_START_APP_ID=shell`, and boots the guest compositor into the home scene instead of the older direct-runtime timeline path. When `PIXEL_SHELL_START_APP_ID=timeline` is present, the guest compositor stays in shell mode and then launches `timeline` through that same shell path.
20. The rooted Pixel shell lane now has a matching control seam too. `scripts/pixel_shellctl.sh` resolves the rooted runtime dir, connects to `shadow-control.sock` with Toybox `nc -U`, and can return raw or JSON control state for live launch/home/reopen proofs.
21. Host scroll already rides the native Blitz path: `WindowEvent::MouseWheel` becomes `UiEvent::Wheel`, overflow containers scroll without a runtime JSON event, and the runtime wrapper now cancels synthetic click dispatch after a drag / pan gesture crosses a small movement threshold.
22. Runtime audio now has its first vertical seam too. `runtime/app-runtime/shadow_runtime_os.js` exports `Shadow.os.audio`, `rust/runtime-audio-host` injects that API into the embedded runtime host, host smokes use a small in-memory backend, and the rooted Pixel sound app flips to the Linux-direct helper path without adding a JVM bridge.
23. The first staged file-backed proof is now landed on top of that seam. `scripts/prepare_sound_demo_assets.sh` generates `audio/demo-tone.wav`, the runtime sound app receives that as a bundle-relative `file` source through `SHADOW_RUNTIME_APP_CONFIG_JSON`, `runtime-audio-host` resolves it via `SHADOW_RUNTIME_BUNDLE_DIR`, and the Linux helper decodes the file in-process before writing PCM to ALSA.

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
