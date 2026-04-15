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
- Treat shell/home unification as a separate project from GPU closure.
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
- [x] The runtime app bundle push path now has a real device-side cache hit.
  - Repeated warm runs now skip re-pushing `runtime-app-bundle.js` when the device-side fingerprint matches.
  - Validated output:
    - `Runtime app bundle cacheHit -> /data/local/tmp/shadow-runtime-gnu/runtime-app-bundle.js`
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
- [x] Host font discovery is no longer leaking into the Pixel musl guest-client build.
  - Root cause of the regression on `just run <serial>`:
    - enabling `blitz-dom/system_fonts` globally pulled in `yeslogic-fontconfig-sys`
    - the static `aarch64-unknown-linux-musl` Pixel guest-client build has no declarative `fontconfig.pc`, so the build died before device launch
  - Fix:
    - add a local `host_system_fonts` feature on `shadow-blitz-demo`
    - only enable that feature on VM/desktop host launch paths
    - keep the Pixel musl guest-client path explicitly on `--no-default-features --features cpu`
  - Result:
    - VM/desktop keep readable text through the host/guest system-font path
    - Pixel musl builds stay on curated/bundled fonts and no longer depend on fontconfig
- [x] The outer guest-compositor shell/home substrate now boots fullscreen on the real Pixel.
  - validated rooted run:
    - `build/pixel/drm-guest/20260407T214327Z`
  - key markers:
    - `[shadow-guest-compositor] shell-home-frame ... size=1080x2340`
    - `[shadow-guest-compositor] frame-content-rect panel=1080x2340 frame=1080x2340 rect=1080x2340+0,0`
    - `[shadow-guest-compositor] presented-frame`
  - new operator hooks:
    - `just pixel-prepare-shell-runtime-artifacts`
    - `just pixel-shell-drm`
    - `just pixel-shell-drm-hold`
- [x] Shell app launch now reaches full-panel composed app frames on the rooted Pixel path.
  - validated rooted run:
    - `build/pixel/drm-guest/20260407T214825Z`
  - key markers after compositor control `launch timeline`:
    - `[shadow-guest-compositor] captured-frame ... size=1080x2340`
    - `[shadow-guest-compositor] frame-content-rect panel=1080x2340 frame=1080x2340 rect=1080x2340+0,0`
    - `[shadow-guest-compositor] presented-frame`
  - root causes fixed:
    - shell scene was still published at logical `540x1170`, so KMS centered it instead of filling the panel
    - shell app composition treated `Xrgb8888` child buffers like transparent-alpha content
- [x] Guest-compositor keyboard-seat startup is repaired on the rooted Pixel path.
  - regression:
    - adding a real keyboard seat caused `shadow-compositor-guest` to crash during xkbcommon init on device
  - root cause:
    - the rooted runtime bundle did not include `xkeyboard-config`, and the session still relied on a dead Nix-store default XKB path
  - fix:
    - stage `share/X11/xkb` into every rooted Linux runtime bundle
    - export `XKB_CONFIG_ROOT=/data/local/tmp/shadow-runtime-gnu/share/X11/xkb` for the rooted guest session
    - invalidate old cached bundles that only had the broken symlinked XKB tree
  - validated rooted run:
    - `build/pixel/drm-guest/20260407T231051Z`

### Not Done

- [~] First visible app frame is still slower than ideal.
  - This matters less than incremental latency for the current product bar.
  - Warmed / isolated click-lane runs already reached `first_visible_frame_ms=408`.
  - Startup polish is no longer the main blocking seam.
- [~] End-to-end GPU presentation is not proved.
  - The rooted Pixel client is hardware-backed.
  - The guest compositor still reports `observed_buffer_type=shm`.
  - So the current proof is:
    - GPU render in the client
    - SHM-oriented handoff/presentation in the compositor path
- [~] The GPU timeline recipe is much more reproducible now, but not completely polished.
  - The client GPU bundle now has a real local cache hit path.
  - The runtime host bundle/device push path now has a real repeated-run cache-hit path.
  - Explicit operator hooks:
    - `just pixel-gpu-warm`
    - `just pixel-runtime-app-nostr-timeline-gpu-smoke`
- [~] The direct runtime GPU probe/matrix seam now exists.
  - New operator hooks:
    - `just pixel-runtime-app-drm-gpu-probe`
    - `just pixel-runtime-app-drm-gpu-matrix`
  - The summary output now reports:
    - `startup_stage_last`
    - `startup_stage_count`
    - `failure_phase`
    - `failure_reason`
    - `adapter_ok`
    - `surface_ok`
    - `configure_ok`
    - `present_ok`
  - The probe wrapper now passes an explicit run dir into the rooted session.
    - This removed the old `latest before / latest after` race.
  - The rooted session status now preserves:
    - `failure_kind`
    - `failure_description`
  - Remaining work:
    - finish one fresh rooted-Pixel probe run after the current cold direct-`gpu` bundle build completes
- [ ] The true `gpu` client renderer path is not the proven operator lane yet.
  - The proven lane today is `gpu_softbuffer`.
  - Existing direct-`gpu` Pixel runs fail at `window.resume() -> wgpu_context.create_surface() -> NoCompatibleDevice`.
- [ ] The guest compositor does not yet import/present dmabuf-backed client buffers on the rooted Pixel path.
- [~] The Pixel GPU timeline smoke is now explicit, but cold runs can still spend time building.
  - Operator hooks:
    - `just pixel-gpu-warm`
    - `just pixel-runtime-app-nostr-timeline-gpu-smoke`
  - Remaining polish:
    - reduce cold-start build churn further
    - keep repeated warm runs boring
- [ ] The direct `gpu` lane does not yet have a clear go/no-go decision.
  - We still need to decide whether to promote it, keep `gpu_softbuffer`, or declare direct present not worth further effort on this Pixel.
- [~] Pixel shell/home operator unification is largely done, with one major interaction gap left.
  - `run <serial>` now uses the shell path.
  - Home/app launch/app switching are working on device.
  - The remaining technical cleanup is narrower:
    - [~] restore compose-field keyboard behavior on device
      - startup regression from the keyboard-seat change is fixed by staging `xkeyboard-config` into the rooted bundle and exporting `XKB_CONFIG_ROOT`
      - seat focus is fixed in the guest compositor
      - rooted Wayland still has no natural IME/input-method client, so the current closure path is a runtime-owned software keyboard rather than more compositor IME surgery
      - common runtime payload now carries active editable metadata (`textInput`)
      - `shadow-blitz-demo` runtime mode now renders a generic bottom keyboard overlay and synthesizes `keydown` + `input` + `blur` through the existing runtime session path
      - Pixel shell/runtime launchers now enable that path declaratively with `SHADOW_BLITZ_SOFTWARE_KEYBOARD=1`
      - real root cause of the latest failure was not stale device bundles:
        - `rust/shadow-runtime-host` had drifted to a `RuntimeDocumentPayload` with only `html` + `css`
        - the runtime JS was still producing `textInput`, but the host session contract silently dropped it before the client could render the keyboard
      - fix:
        - restore `textInput` to the host-side payload struct
        - add a host regression test for payload decode
        - tighten `runtime-app-keyboard-smoke` so it fails if focused responses lose `textInput`
        - route on-screen keyboard taps through normal DOM hit-testing first
          - old behavior gave the software keyboard a parallel synthetic hit map based on assumed surface dimensions
          - that duplicated geometry drifted from the real shell app surface on device
          - compose focus worked because it used normal DOM hit-testing; keyboard taps did not
          - new behavior prefers `shadow_target_at(...)` and only keeps the synthetic key-frame path as a fallback
        - add regression coverage on a non-default surface size so software-keyboard taps keep working when the shell/client surface is not exactly the nominal viewport size
      - architecture note:
        - the recurring footgun here is not just stale device bundles; it is runtime-session schema drift across three layers:
          - runtime JS payload
          - `rust/shadow-runtime-host`
          - `shadow-blitz-demo` runtime client
        - the immediate guardrails are the new host unit test plus the tighter keyboard smoke
        - the cleaner follow-up is to extract a shared runtime-session protocol type so host/client cannot silently diverge on fields like `textInput`
      - local proofs now green:
        - direct host-session probe for `runtime/app-keyboard-smoke/app.tsx` returns `textInput.targetId == "draft"`
        - `cargo test --manifest-path rust/shadow-runtime-host/Cargo.toml runtime_document_payload_preserves_text_input -- --nocapture`
      - local regression coverage exists for:
        - keyboard overlay rendering
        - keyboard tap dispatching `keydown` + `input`
        - bundled host runtime smoke:
          - `just runtime-app-keyboard-smoke`
      - still pending:
        - fresh live Pixel proof that tapping compose/input fields now yields usable text entry end to end
    - keep app identity/app-id overrides truthful on fresh rooted runs
    - keep the shell operator path boring and explicit
      - `run <serial>` now holds indefinitely by default
      - shell session lifetime defaults were removed
      - only startup/checkpoint waits remain, so failed boots still error out instead of hanging forever before first frame
      - rooted shell now defaults to a pointer-only seat again
      - `wl_keyboard` is opt-in for future IME experiments because the half-configured keyboard seat was wedging `winit-wayland` client startup on-device
    - keep shell scrolling generic instead of app-by-app
      - drag inside the app viewport now scrolls instead of text-selecting
      - runtime root scrolling is enabled by default via `#shadow-blitz-root`
      - explicit app shell viewport contracts were normalized for Podcast and Cashu
      - regression coverage now includes root-level finger-pan scrolling without an explicit inner scroll container
    - keep the shell-launched Timeline app on the proven GPU lane
      - restored worktrees can lose the cached Turnip / vendor Mesa tarballs under `build/pixel/vendor`
      - without those tarballs the shell path silently falls back to `WGPU_BACKEND=gl`, which crashes in `NoCompatibleDevice`
      - the shell GPU launcher now also carries the chroot-specific runtime host / XKB fixes needed for shell-launched runtime apps
      - the `gpu_softbuffer` shell path now uses the CPU image-render fallback (`VelloCpuImageRenderer`) so avatar/image rendering does not crash after `runtime-document-ready`
      - validated rooted run:
        - `build/pixel/drm-guest/20260408T001551Z`
      - key markers:
        - `runtime-session-ready`
        - `runtime-document-ready`
        - `captured-frame checksum=45a631d62bd2656d size=532x1074`
        - no `NoCompatibleDevice` panic
    - keep shell app switching alive across app relaunches
      - root cause of the `Timeline -> Home -> Counter` black-screen:
        - shell mode was still inheriting `EXIT_ON_CLIENT_DISCONNECT`
        - terminating Timeline to launch Counter caused the guest compositor to stop as soon as the old client disconnected
        - Counter then lost its Wayland server during `create_default_event_loop()`
      - fix:
        - shell sessions no longer request `EXIT_ON_CLIENT_DISCONNECT`
        - guest compositor ignores that knob in shell mode even if it is accidentally set
    - keep shell auto-open startup checks truthful
      - root cause of the apparent `run <serial>` "podcast crash":
        - the shell successfully auto-opened the requested app and mapped a window
        - the wrapper was still waiting for a direct client-process checkpoint that is not reliable on this chrooted shell path
        - that false timeout triggered Android restore and made the app look like it crashed
      - fix:
        - shell auto-open now validates shell-level markers instead:
          - `mapped-window`
          - `surface-app-tracked app=<id>`
        - `run` / `ui-run` default back to `app=shell`

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
- The remaining warm-path slop is now mostly cold rebuild invalidation, not operator ambiguity.
  - `shadow-runtime-host` is still packaged from `src = ./.`, so unrelated repo edits can invalidate the host derivation and force one cold rebuild.
  - repeated warm runs should now short-circuit before the old host-bundle restage/push path once the new bundle manifest is in place.
- The product bar for interaction is already met on the proven lane.
- Remaining GPU work is now about closure and confidence, not rescuing a broken UX.
- The VM/desktop font fallback and the Pixel runtime font path must stay split.
  - VM/desktop can use a declarative system-font environment.
  - Pixel runtime/shell bundles must keep shipping their own curated fonts instead of depending on host font discovery.
- The current compositor path still looks SHM-oriented from the outside.
- The direct `gpu` failure is now narrower than before:
  - the bundled Turnip library does contain Wayland WSI entrypoints
  - the direct path gets past adapter discovery and then dies in surface configure/present territory
  - the likely next seam is compositor protocol support and presentation compatibility, not basic Vulkan adapter discovery
- Historical direct-`gpu` runs now classify much better under the updated summary parser.
  - Reparsed run:
    - `build/pixel/drm-guest/20260407T163153Z`
  - Current classified result:
    - `adapter_ok=true`
    - `surface_ok=true`
    - `configure_ok=false`
    - `present_ok=false`
    - `failure_phase=surface-configure-entry`
    - `failure_reason=client-disconnect:ConnectionClosed`
- The Pixel shell problem is no longer blocked on nested EGL.
  - The outer guest compositor can already present the home scene directly on the phone.
  - Remaining shell work moved up-stack:
    - operator wiring
    - app-launch UX
    - deciding when to switch `run <serial>` over
- The first shell touch polish seam is now mostly closed.
  - Touch on the outer shell path should feel like one tap, not a press/release two-step.
  - The shell touch path now emits one shell tap action per touch gesture instead of double-activating on down/up.
  - Mouse / pointer semantics stay unchanged.
- The next shell polish seam is app-viewport gesture correctness.
  - Root cause:
    - the guest compositor still synthesized finger drags inside runtime apps as left-mouse drags
  - chosen fix:
    - track app touch gestures in the guest compositor
    - treat small gestures as taps
    - synthesize Smithay `AxisFrame` finger scroll events once drag crosses a threshold
- The current slow shell app-switch path is not mostly shell chrome; it is process policy.
  - Root cause:
    - the Pixel shell shelves the previous runtime app but leaves it alive
    - opening a different app then pays a second full GPU runtime app cold start
  - chosen fix:
    - keep the Pixel shell single-live-app for now
    - terminate non-target runtime apps before launching/focusing another app
- The shell keyboard regression had an immediate compositor-side bug.
  - Root cause:
    - `shadow-compositor-guest` created only a pointer seat and never set seat keyboard focus when app windows were focused
  - fix:
    - add a keyboard capability to the guest seat
    - set and clear Smithay keyboard focus alongside window activation
    - stage real XKB data into the rooted runtime bundle and export `XKB_CONFIG_ROOT` for the session
  - remaining question:
    - whether the rooted Pixel soft keyboard still needs explicit Wayland text-input/input-method support beyond correct seat focus
- The shell Timeline black-screen bug was a stack of smaller GPU/runtime issues, not one failure.
  - on the restored worktree the cached Turnip / Mesa tarballs were gone, so the shell path fell back to `WGPU_BACKEND=gl`
  - the chrooted GPU launcher then needed:
    - staged XKB data
    - root-relative runtime app bundle paths
    - stage-loader runtime-host spawn
    - `--preload` instead of leaking `LD_PRELOAD` onto Android `chroot`
  - after that the remaining crash was inside `anyrender_vello::VelloImageRenderer`, which tried to create a second GPU context for image rendering and died with `NoCompatibleDevice`
  - the practical fix is to keep the GPU window path but use `VelloCpuImageRenderer` for `gpu_softbuffer` image rendering

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
  - new warm/prebuild entrypoint exists for the Pixel GPU timeline lane
  - explicit warm/smoke recipes now force the proven `gpu_softbuffer` lane instead of silently inheriting a caller override
  - remaining slop is mostly cold `shadow-runtime-host` rebuild invalidation and the slower first-paint path on the full startup-sync timeline recipe
  - direct-GPU probe/matrix recipes now exist and emit richer startup/failure-phase summary fields

### 5. Eliminate SHM as the limiting compositor transport

- [ ] Not done.
- Notes:
  - this is the main remaining architectural gap if we want true end-to-end GPU presentation

### 6. Make an explicit direct-`gpu` decision

- [~] In progress.
- Notes:
  - direct `gpu` is no longer a vague future wish
  - it now has a narrow failing seam
  - the decision tooling now preserves the real failure kind and explicit run ownership
  - the remaining work is to decide whether it is salvageable enough to ship on this Pixel

## Near-Term Steps

1. Finish the direct-`gpu` investigation.
   - Focus:
     - `Surface::configure()` / direct present failure on the rooted Pixel
   - Goal:
     - either a stable direct `gpu` lane
     - or hard evidence that `gpu_softbuffer` should remain the supported path on this device

2. Finish the compositor transport seam.
   - Add or finish linux-dmabuf import/presentation in `shadow-compositor-guest`.
   - Re-run buffer classification and stop only when:
     - result is no longer `type=shm`
     - or we can defend that SHM is not the remaining product bottleneck

3. Keep the known-good GPU lane boring and reproducible.
   - Goal:
     - repeated GPU runs avoid rebuild churn and giant repushes
   - Current status:
     - client GPU bundle caching: good
     - runtime helper device-side caching: good
      - `just pixel-gpu-warm` now prebuilds the current Pixel GPU timeline lane without launching it
      - `just pixel-runtime-app-nostr-timeline-gpu-smoke` runs the proven lane explicitly

4. Keep Pixel shell work on the right substrate.
   - Current status:
     - validated on device
     - shell touch semantics tightened so tap activates on touch-down
   - Do not spend more time trying to make nested `shadow-compositor` the shipping Pixel shell path unless a narrow diagnostic proves it is suddenly tractable.
   - Prefer:
     - shell/home logic on the outer guest compositor path
     - compositor-owned shell composition over nested `shadow-compositor`
   - Current substrate status:
     - `shadow-compositor-guest` now has app launch/focus/shelving/control
     - shell mode now software-composes the existing home scene plus the current app viewport on the outer guest compositor path
   - Next shell seam:
     - widen the operator path from dedicated `pixel-shell-drm*` commands into `run <serial>`
     - keep app launch/home UX truthful on top of the new shell mode

5. Keep measuring incremental latency, not just startup.
   - Need:
     - tap-to-updated-frame
     - text-render correctness
     - cache-hit stability
   - Current best proof:
     - timeline quick action updates in `~62ms`

6. Defer startup polish unless it blocks product work.
   - Current note:
     - warmed click lane already reached `408ms`
     - first paint is no longer the main blocker
     - prioritize direct `gpu` and compositor closure first

## Plan To Finish This Project

### Phase A. Make the proven Pixel GPU lane reproducible

- Goal:
  - same hardware-backed Turnip/KGSL path every run
- Work:
  - avoid unnecessary remote rebuilds when known-good GPU artifacts already exist
  - add a dedicated Pixel GPU timeline smoke that writes the same compact summary as the counter demo
  - make the default operator commands use the cached/proven GPU artifacts whenever possible
  - keep shell/runtime font assets host-built and reproducible, not copied from one live device
  - keep `pixel-gpu-warm` as the obvious prebuild hook for the Pixel GPU lane
- Exit:
  - we can run the timeline app repeatedly on the GPU lane without rebuild roulette

### Phase B. Decide direct `gpu`

- Goal:
  - know whether direct `gpu` is a real shipping path on this Pixel
- Work:
  - keep pushing the narrowed surface configure/present seam
  - validate compositor globals/protocol needs
  - compare `gpu` against `gpu_softbuffer` with the same measurement tooling
- Exit:
  - either:
    - direct `gpu` is stable enough to promote
  - or:
    - we explicitly standardize on `gpu_softbuffer` for this Pixel

### Phase C. Finish end-to-end GPU presentation

- Goal:
  - real GPU client plus GPU-friendly compositor transport
- Work:
  - finish dmabuf import/presentation support in `shadow-compositor-guest`
  - finish the direct-`gpu` Wayland surface investigation with the new local diagnostics:
    - adapter-vs-surface compatibility logging in the vendored renderer stack
    - `wp_presentation` exposed from the guest compositor
    - runtime direct-`gpu` profile selection (`gl`, `vulkan_drm`, `vulkan_kgsl`, `vulkan_kgsl_first`)
  - determine whether the remaining blocker is:
    - missing compositor globals/protocols
    - unsupported explicit sync on the Pixel DRM node
    - or a deeper Turnip/KGSL Wayland presentation limitation
  - re-run buffer classification on Pixel
  - compare `gpu` vs `gpu_softbuffer`
- Exit:
  - either:
    - compositor-observed buffer type is no longer SHM
  - or:
    - we have hard evidence that SHM is not the remaining bottleneck and the current proven path already meets the product bar

### Phase D. Startup and operator polish

- Goal:
  - remove remaining friction without reopening solved seams
- Work:
  - warm/prebuild command for Pixel GPU artifacts
  - cache-hit visibility in operator scripts
  - only then chase first visible frame if it still matters
- Exit:
  - the default GPU operator lane is boring, predictable, and fast enough to use casually

### Phase E. Decide whether Pixel remains viable

- Keep the Pixel if:
  - hardware-backed GPU remains stable
  - interaction remains instant
  - the proven lane stays reproducible
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
- `685b6a1`:
  - `just pixel-gpu-warm` landed as the obvious prebuild hook for the current proven lane
- `Phase A operator follow-up`:
  - fixed the prepare-only env mismatch so the warm path actually exercises the existing Pixel runtime prep flow
  - added explicit `gpu_softbuffer` operator recipes for warm/smoke on the proven lane
  - added a runtime-host bundle manifest so repeated warm runs can reuse the local staged host bundle before the old restage path
  - fixed the device-side runtime app bundle cache check so repeated warm runs now reach `Runtime app bundle cacheHit`
- `2026-04-07 direct-gpu probe cleanup`:
  - the static direct-`gpu` probe infrastructure had two real bugs:
    - it was not auto-picking the cached Turnip tarball the way the runtime Pixel path does
    - its bundle cache fingerprint did not include `ui/third_party/anyrender_vello` or `ui/third_party/wgpu_context`, so renderer/probe changes could be silently ignored
  - both are now fixed in the local worktree
  - the guest compositor now logs client disconnect reasons and reaps exited children during Wayland dispatch
  - the vendored renderer stack now logs:
    - successful surface/adaptor selection
    - the exact `SurfaceRenderer::configure()` step
    - whether Vello renderer init is reached
- latest rooted-Pixel direct-`gpu` finding:
  - with the corrected Turnip bundle, direct Vulkan no longer fails at adapter discovery
  - it now reaches:
    - real hardware adapter selection
    - surface capabilities query
    - `SurfaceRenderer::configure()`
  - and then the client dies during `Surface::configure()` before first frame
  - this reproduces across:
    - `vulkan_kgsl_first`
    - `vulkan_kgsl`
    - `vulkan_drm`
  - the explicit-capability fallback (`Mailbox`, `Opaque`, matching `Bgra8Unorm`) did not fix it
  - current inference:
    - the remaining direct Vulkan blocker is below our app logic and below adapter selection
    - it is in the Turnip + Wayland surface configure/present path on this Pixel GNU userspace stack
- `2026-04-07 shell substrate follow-up`:
  - nested `shadow-compositor` is no longer the default Pixel shell plan
  - the better plan is:
    - keep the proven outer `shadow-compositor-guest`
    - run the shell/home frontend as a regular Pixel client or port the shell scene/lifecycle into the outer guest compositor
- `2026-04-08 shell timeline font follow-up`:
  - the shell-launched Timeline app did render, but text looked wrong because the chrooted GNU bundle had no curated Android fonts at `/system/fonts/...`
  - the fix should stay declarative:
    - stage a tiny curated font set from Nix store packages into the runtime bundles
    - do not copy fonts from whichever handset happened to be connected
  - this should make a fresh device behave the same as the current one
- `2026-04-07 guest compositor shell substrate`:
  - next seam is not the full home UI yet
  - it is:
    - control socket on `shadow-compositor-guest`
    - managed app launch/focus/shelving for counter/timeline
    - app-id tracking from Wayland toplevel metadata
  - this gives the eventual Pixel shell frontend a truthful substrate to target on the existing rooted compositor path
- `2026-04-07 guest compositor shell composition`:
  - the better immediate Pixel shell path is now clearer:
    - keep the outer guest compositor
    - render the existing `shadow_ui_core::ShellModel` scene directly there
    - composite the focused app frame into the app viewport
  - this avoids the nested EGL failure mode entirely
  - real rooted-device proof now exists:
    - `build/pixel/drm-guest/20260407T211034Z`
    - the home scene reached `shell-home-frame` and `presented-frame`
  - current remaining shell work is operator/live-validation work, not another compositor-in-compositor experiment
- current best proven path remains:
  - `gpu_softbuffer`
  - hardware-backed client GPU on Turnip/KGSL
  - fast incremental updates on the rooted Pixel
- Current truth:
  - GPU requirement is not satisfied by `cpu`
  - GPU requirement is partially satisfied today:
    - real hardware-backed client GPU is proved
    - true end-to-end GPU presentation is not yet proved
- Current recommendation:
  - treat shell/home unification as a separate integration project
  - keep the GPU closure lane narrowly focused on:
    - direct `gpu`
    - compositor transport
    - reproducibility

## Further Improvements

- Build infrastructure:
  - a real native `aarch64-linux` build server would materially improve operator UX
  - current first-run delays are often build-time, not render-time:
    - Nix + cross-target Rust + GPU bundle assembly
    - remote Linux builder churn
    - occasional heavy dependency rebuilds
  - the most useful improvement would be:
    - stable native ARM Linux builder
    - persistent binary cache for the Pixel GPU artifacts
    - prebuilt vendor GPU bundle artifacts keyed by fingerprint

- Operator ergonomics:
  - add an explicit `warm-gpu-artifacts` command that only prepares:
    - runtime host bundle
    - GPU client bundle
    - vendor Mesa / Turnip overlay bundle
  - make the hold-mode commands print whether they are:
    - cache hit
    - rebuilding
    - pushing
    - already on device

- Performance:
  - treat first visible frame and incremental latency separately
  - keep incremental updates as the primary product metric
  - only chase startup below `500ms` after the default GPU lane is reproducible and boring

- Architecture cleanup:
  - once the current GPU lane is merged and in use, remove stale CPU-only assumptions from:
    - Pixel runtime launch scripts
    - old probe branches
    - redundant fallback env handling
  - keep one proven operator lane and one experimental direct-present lane, not many half-maintained variants
