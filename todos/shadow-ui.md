Living plan. Revise it as we learn. Do not treat this as a fixed contract.

# Shadow UI Platform

## Scope

Build the first serious version of the long-term Shadow app platform:

- equal TypeScript and Rust app-model support at the platform layer
- one shared `shadow_sdk` surface for lifecycle, services, capabilities, and app environment
- a Shadow-owned Rust UI framework built on Masonry/Xilem foundations
- enough runner, lifecycle, input, and service plumbing to prove the model in VM first
- a path to rewriting shell/system chrome onto the same foundation

This plan is for the platform effort, not for the already-landed one-manifest app metadata cleanup by itself.

## Approach

Start from the constrained v1 spec in [docs/shadow-ui.md](../docs/shadow-ui.md), then execute in small seams with targeted risk spikes.

Do not try to design every widget and service upfront. Lock the important contracts early:

- app-model metadata shape
- one public SDK surface
- shared lifecycle model
- rendering ownership
- service and permission boundaries
- shell/system chrome migration strategy

Use the current manifest work in [runtime/apps.json](../runtime/apps.json) as the baseline for multi-model app registration instead of inventing a parallel manifest path.

## Milestones

- [x] Extend the current manifest and generated metadata to support `typescript` and `rust` app models.
- [x] Define the first public `shadow_sdk` surface for Rust apps and the matching `@shadow/sdk` binding for TypeScript apps.
- [~] Decide the smallest useful internal boundaries behind the one public SDK surface.
- [x] Prove a minimal Rust app runner for one process-isolated Shadow UI app.
- [x] Prove one shared capability end-to-end through both Rust and TypeScript app surfaces.
- [x] Prove shared lifecycle events through the Rust path first and define how they surface to TypeScript apps.
- [x] Prove one shell/system surface rendered directly by the compositor.
- [ ] Land the first serious Rust demo app that exercises navigation, list rendering, and persistence.

## Near-Term Steps

- [~] Expand the first `shadow_sdk` slice beyond app env and service bindings.
- [ ] Decide where the generated manifest types should live as the current manifest expands.
- [ ] Rename target-specific compositor crates and binaries to match their deployment lanes more clearly.
- [x] Sketch the minimal launch metadata required for both `typescript` and `rust` apps.
- [x] Choose the first Rust runner spike target and keep it deliberately small.
- [x] Choose the first shared capability to prove through both app models.
- [ ] Decide which text-input path to spike first: single-line editor or multiline editor.
- [x] Pick the first shell/system surface to target for embedded rendering.
- [ ] Decide whether broader TypeScript platform work should stay in [todos/vdom.md](../todos/vdom.md) or move to a broader `todos/typescript-apps.md`.

## Implementation Notes

- The one-manifest direction has landed in the repo. This platform effort should extend that work to cover both app models instead of bypassing it.
- The manifest now carries `model`, generated Rust metadata exposes a launch-spec view, and runtime artifact builders skip `rust` apps by default while still rejecting explicit `--include-app <rust-app>` requests.
- `generated_apps.rs` is acceptable as a short-term static bridge, but it is not the end state. Revisit whether generation should emit a smaller typed data layer or move behind a build/runtime boundary before this metadata surface grows much further.
- VM now supports a real mixed-model shell session: the session package contains `shadow-compositor` plus manifest-declared VM app binaries, the VM launch path no longer exports a global Blitz client override, and a minimal `shadow-rust-demo` binary can be launched through the normal control surface.
- The compositor crate and binary names should become deployment-descriptive. `shadow-compositor` and `shadow-compositor-guest` are too implicit once both VM and Pixel lanes matter.
- Pixel remains TypeScript-only for now. Mixed-model manifests are valid, but rooted-Pixel staging and shell surfaces still filter to TypeScript until the native packaging path exists there too.
- The current `runtime-<something>-host` naming pattern should collapse toward one shared SDK/service surface.
- The public app-authoring surface should feel like one SDK, not a pile of crates and one-off bindings.
- The first public SDK slice is now real: Rust apps have `shadow_sdk::app`, TypeScript apps import `@shadow/sdk`, and the old TypeScript runtime aliases remain as compatibility wrappers while in-repo apps migrate.
- Masonry/Xilem remains the leading foundation candidate for the Rust UI implementation layer because it supports both external event-loop integration and rendering into caller-provided textures.
- Shell/system chrome rewrite is in scope. The current homegrown shell UI should be treated as bring-up architecture, not the final product direction.
- The VM operator/status path now depends on truthful mixed-model probing in `scripts/shadowctl`; keep VM smoke and the operator CLI smoke in lockstep when touching that code.
- The next spike should move from runner proof to platform proof: one shared capability or lifecycle contract that both TypeScript and Rust apps can exercise through the same public SDK story.
- Camera is the first shared capability seam. It already has a relatively clean env-driven host implementation, explicit mock support for tests, and a small enough surface to expose natively through `shadow_sdk` without first solving the entire lifecycle/control-plane story.
- The first Rust camera slice now keeps `runtime-camera-host` as the single implementation while `shadow_sdk::services::camera` owns the app-facing types. The public Rust SDK no longer re-exports runtime host env knobs or transport request/receipt types.
- The Rust camera surface still intentionally stops at `list_cameras`, `capture_still`, and `decode_qr_code`. Preview remains TypeScript-only for now, so API parity and VM smoke coverage are the next camera follow-up instead of more wrapper churn.
- The VM proof path for the Rust camera slice is now manifest-driven: `launchEnv` metadata flows through generated app metadata into both compositor launchers, `rust-demo` logs a structured `camera_probe` marker, and `scripts/ci/ui_vm_smoke.sh` asserts that marker while failing fast on explicit probe errors.
- `launchEnv` is intentionally subordinate to compositor-owned wiring. The metadata generator now rejects reserved launcher-managed env keys, and both launchers apply manifest env before their own required Wayland/control/runtime settings.
- `scripts/ci/ui_vm_smoke.sh` now records cached success only after cleanup and no longer waits unbounded on the VM runner in the EXIT path. That tightened the “VM looked done but the command kept running” failure mode from this seam.
- Lifecycle now uses the existing per-app platform-control socket instead of a second transport. The first truthful contract is intentionally smaller than the long-term spec: apps start in `foreground` by default and receive `background` / `foreground` transitions as the shell shelves and resumes them.
- Rust apps now read lifecycle state from `shadow_sdk::app` and can spawn a lifecycle listener on the same app platform-control socket. TypeScript apps now use `getLifecycleState`, `setLifecycleHandler`, and `clearLifecycleHandler` from `@shadow/sdk`, backed by the same host/app transport.
- The shared app-environment seam now includes launch-time window metrics too: Rust app env exposes safe-area insets alongside surface size, the Deno runtime host seeds the same metrics snapshot into `@shadow/sdk`, standalone runtime-host sessions now wrap the host binary with the same launch env, and VM smoke proves those markers through both `counter` and `rust-demo`.
- VM smoke now proves the lifecycle seam through both app models: `counter` logs TypeScript lifecycle markers on home/reopen, and `rust-demo` logs Rust lifecycle markers on the same transitions.
- The first embedded shell/system surface is now the VM top chrome strip. `shadow-ui-core` exposes it as a reusable local overlay scene, the VM compositor renders it as a second compositor-owned shell surface, and guest/pixel keep the legacy full-shell scene for now.
- The VM proof for that seam now covers both the normal smoke lane and a direct tap on the compositor-owned strip: `just smoke target=vm` passes, and a host-space tap at `330,59` shelves `podcast` through the overlay path in the current 660x1240 nested VM window.
- The next shell chrome seam is now fully on the shared geometry path too: the shell model treats the bottom navigation pill as a second Home affordance, the VM compositor renders it as another compositor-owned shell surface, foreground capture reserves both top strip and bottom pill for shell input, and the shared app viewport now reserves the lower system-chrome inset instead of rendering under that pill.
- Home / launcher content is now on the compositor-owned VM path too: the shell model exposes a background-only base scene plus a transparent launcher overlay scene, the VM compositor composes that overlay below the top strip and bottom pill, and VM smoke now proves the path by opening `counter` from a real launcher-tile tap instead of a control-plane `open`.
- IME stays deferred for now. The compositor can render another system-owned surface, but it still cannot observe focused-app `textInput` state over the current app platform-control socket, so a real compositor-owned keyboard needs a protocol extension before it is worth implementing.
- The next seam should move to the next embedded shell surface or the first text/input contract, rather than more launch/env churn.

## Shell/System Chrome Migration

This is a real product track inside this plan, not a vague later cleanup. The current homegrown shell UI should be retired incrementally by moving existing OS chrome onto Shadow UI surfaces in small VM-first seams, then carrying those seams over to guest/pixel once they are proven.

- [~] Move the existing shell/system chrome onto Shadow UI surfaces.
- [x] Top chrome strip.
- [x] Bottom navigation / home affordance.
- [x] Home / launcher content.
- [ ] App switcher / recents surfaces.
- [ ] Notifications, quick settings, and other pull-down system surfaces.
- [ ] Lock, IME, and other always-on system-owned surfaces.

The top chrome strip and bottom navigation pill are now both live Home affordances in the shell model, the shared viewport contract now reserves the lower system-surface inset instead of letting app content render under the compositor-owned pill, and the VM home/launcher surface now rides the same compositor-owned overlay path.
