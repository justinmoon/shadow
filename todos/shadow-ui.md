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
- [ ] Define the public `shadow_sdk` surface for Rust apps and the matching single binding surface for TypeScript apps.
- [ ] Decide the smallest useful internal boundaries behind the one public SDK surface.
- [ ] Prove a minimal Rust app runner for one process-isolated Shadow UI app.
- [ ] Prove one shared capability end-to-end through both Rust and TypeScript app surfaces.
- [ ] Prove shared lifecycle events through the Rust path first and define how they surface to TypeScript apps.
- [ ] Prove one shell/system surface rendered directly by the compositor.
- [ ] Land the first serious Rust demo app that exercises navigation, list rendering, and persistence.

## Near-Term Steps

- [ ] Tighten the spec one more pass around `shadow_sdk` naming, modules, and binding language for TypeScript.
- [ ] Decide where the generated manifest types should live as the current manifest expands.
- [x] Sketch the minimal launch metadata required for both `typescript` and `rust` apps.
- [ ] Choose the first Rust runner spike target and keep it deliberately small.
- [ ] Choose the first shared capability to prove through both app models.
- [ ] Decide which text-input path to spike first: single-line editor or multiline editor.
- [ ] Pick the first shell/system surface to target for embedded rendering.
- [ ] Decide whether broader TypeScript platform work should stay in [todos/vdom.md](../todos/vdom.md) or move to a broader `todos/typescript-apps.md`.

## Implementation Notes

- The one-manifest direction has landed in the repo. This platform effort should extend that work to cover both app models instead of bypassing it.
- The manifest now carries `model`, generated Rust metadata exposes a launch-spec view, and runtime artifact builders skip `rust` apps by default while still rejecting explicit `--include-app <rust-app>` requests.
- The current VM and Pixel shell lanes now surface only launchable TypeScript apps. That is intentional until the Rust runner/client packaging seam exists; mixed-model manifests are valid, but `rust` shell apps are still hidden/rejected in the current operator surface.
- The current `runtime-<something>-host` naming pattern should collapse toward one shared SDK/service surface.
- The public app-authoring surface should feel like one SDK, not a pile of crates and one-off bindings.
- Masonry/Xilem remains the leading foundation candidate for the Rust UI implementation layer because it supports both external event-loop integration and rendering into caller-provided textures.
- Shell/system chrome rewrite is in scope. The current homegrown shell UI should be treated as bring-up architecture, not the final product direction.
- The next spike should prove the smallest Rust runner path end to end: one packaged Rust client binary, one manifest entry, one VM launch path, and no global Blitz-only client override in that path.
- After the runner spike, revisit the session-visible app filters so `rust` apps can participate in VM/Pixel shell profiles on equal footing.
