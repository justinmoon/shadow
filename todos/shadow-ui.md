Living plan. Revise it as we learn. Do not treat this as a fixed contract.

# Shadow UI Platform

## Scope

Build the first serious version of the long-term Shadow app platform:

- equal `typescript` and `rust` app models at the metadata, launcher, and SDK
  layers
- one shared `shadow_sdk` / `@shadow/sdk` surface for app env, lifecycle,
  services, and capabilities
- a Shadow-owned Rust UI framework on top of Masonry/Xilem
- a VM-first path to rewriting shell/system chrome onto the same foundation
- an app-authoring experience that trends toward SwiftUI / Jetpack Compose,
  not app-local glue code and framework leakage

This plan is for the platform effort, not just the already-landed app metadata
cleanup.

## Approach

Lock the important platform contracts early:

- manifest/app-model shape
- one public SDK story
- shared lifecycle and service boundaries
- compositor ownership of system chrome
- honest product semantics at the app boundary

Then move in small seams. Use real apps to pressure the framework instead of
speculating about a huge widget catalog up front.

## Milestones

- [x] Extend app metadata and generated launch data to support `typescript` and
      `rust`.
- [x] Define the first public `shadow_sdk` / `@shadow/sdk` surface.
- [~] Collapse the remaining internal runtime/service boundaries behind that one
      public SDK story.
- [x] Prove a minimal Rust app runner in the real VM launcher/compositor path.
- [x] Prove shared capabilities through both app models.
- [x] Prove shared lifecycle through the Rust path first, then expose the same
      semantics to TypeScript.
- [x] Prove compositor-owned system chrome in the real shell.
- [~] Land the first serious Rust app and use it to drive framework cleanup.

## Near-Term Steps

- [x] Use the Rust Nostr client as the main pressure test for the platform.
- [~] Move theme and related UI dependencies behind a Shadow-owned context/env
      surface so app helpers stop threading `Theme` through every function.
- [~] Replace app-local async/job bookkeeping with a Shadow-owned task/effect
      surface so apps stop hand-rolling token ids and eventually stop
      hand-wiring per-task slots and wrappers in each app.
- [~] Replace per-app platform listener threads with a Shadow-owned
      lifecycle/automation/platform-event helper.
- [ ] Define a clearer cached-data model so app authors know which reads are
      safe inline and which need async effects.
- [ ] Decide where generated manifest types belong as app metadata expands.
- [ ] Rename target-specific compositor crates/binaries to match deployment
      lanes more clearly.
- [ ] Decide whether broader TypeScript platform follow-ups stay in
      [todos/vdom.md](../todos/vdom.md) or move to a broader
      `todos/typescript-apps.md`.

## Implementation Notes

- The architecture thesis is now proven enough to stop treating Rust apps as a
  speculative spike. Mixed-model manifests, real Rust app launch, shared
  services, compositor-owned shell surfaces, and one public SDK story are all
  real.
- The public app-authoring surface should feel like one SDK, not a pile of
  host/runtime crates and one-off bindings.
- `generated_apps.rs` is acceptable as a short-term static bridge, but it is
  not the end state. Revisit it before manifest growth makes it expensive to
  change.
- The main host-side Deno runner is now `shadow-system`. Keep collapsing the
  remaining `runtime-<something>-host` seams inward behind `shadow-system` and
  `shadow_sdk`.
- Masonry/Xilem remains the base implementation layer, not the product API.
- The biggest framework gap is now ergonomics, not viability. The Rust timeline
  still exposes too much framework leakage:
  - explicit `Theme` plumbing
  - app-local `pending_*` async state and token bookkeeping
  - app-local platform socket listener threads
- The first ergonomics cleanup slice is now in:
  - `shadow_sdk::ui::UiContext` owns app metrics plus theme selection for the
    current view tree
  - the Rust timeline route/render helpers now take `UiContext` instead of raw
    `Theme`
  - `shadow_sdk::ui::TaskSlot` / `with_task` now own task identity and stale
    completion filtering so apps do not carry ad hoc token counters
  - `shadow_sdk::app::spawn_platform_request_listener` now owns the raw
    platform socket bind/read/parse/write loop so apps only map parsed requests
    into app messages
  - the Rust timeline task/effect seam now lives in a dedicated `tasks.rs`
    module with one `TimelineTasks` state object and one `decorate_with_tasks`
    hook instead of spreading slot state and `with_task(...)` wiring through
    `main.rs`
  - the next cleanup slice moved the timeline app's Nostr task runners and
    cached-data helpers behind `shadow_sdk::services::nostr::timeline`, so the
    SDK now owns more of the Home/Explore/thread/contact-list/reply domain
    behavior instead of leaving that logic inside the app crate
  - the oversized timeline task module is now split across `tasks.rs`,
    `tasks/start.rs`, and `tasks/finish.rs` so the app-side task boundary stays
    readable while the SDK absorbs more of the actual domain work
- That is not the end state. The big remaining ergonomics problem is still the
  app-local shape of task/effect wiring:
  - per-app `Pending*` job structs still exist for UI-specific pending state
  - no first-class distinction between inline cache reads and async effects
  - too much app-specific begin/finish glue still sits above the generic
    `TaskSlot` / `with_task` foundation
- The new platform listener helper is in use for the Rust timeline, but other
  app paths still own raw socket/control loops. Keep collapsing those inward
  instead of letting multiple listener styles stick around.
- The next platform work should optimize for app-authoring quality, not for
  adding more ad hoc app-level product features on top of the current glue.
- The Rust Nostr app is now the main pressure test because it already exercises:
  - navigation
  - cached reads
  - explicit sync
  - write flows
  - signer approval
  - follow graph updates
  - real VM automation
- The right product bar is honest data and honest state. Do not add fake notes,
  hidden feed fallbacks, or fake onboarding just to make demos feel richer.
- VM and host test seams should keep moving toward reusable local-service
  harnesses instead of per-smoke relay bring-up scripts.
- VM automation for serious Rust apps should keep moving toward semantic
  app-owned hooks, not brittle fixed tap coordinates.
- Pixel remains TypeScript-first for now. Mixed-model metadata is valid, but
  native Rust packaging/staging on Pixel is still future work.

## Shell/System Chrome Migration

This is a real product track inside this plan. The current homegrown shell UI
is bring-up architecture, not the final direction.

- [~] Move existing shell/system chrome onto Shadow UI surfaces.
- [x] Top chrome strip.
- [x] Bottom navigation / home affordance.
- [x] Home / launcher content.
- [ ] App switcher / recents.
- [ ] Notifications / quick settings / pull-down surfaces.
- [ ] Lock, IME, and other always-on system-owned surfaces.

The next shell migration seam should come after the first ergonomics cleanup
pass, not before. The framework needs to get less awkward while the pressure
app is still small enough to refactor cleanly.
