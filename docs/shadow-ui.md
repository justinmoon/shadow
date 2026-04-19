---
summary: V1 platform specification for the Shadow app platform, with equal TypeScript and Rust app models, one shared Shadow SDK surface, and a Shadow-owned Rust UI framework built over Masonry/Xilem foundations
read_when:
  - defining the long-term Shadow app platform
  - extending the current manifest-driven app metadata beyond the current runtime-only shape
  - deciding what belongs in the public SDK versus internal implementation layers
  - planning the rewrite of shell and system chrome onto the Shadow UI foundation
---

# Shadow UI

This document specifies the intended v1 shape of the Shadow app platform.
It is a contract document, not a marketing doc and not a changelog.

Today, the shipped app-authoring surface in this repo is still heavily centered on the TypeScript/Deno/Solid path.
This doc is about converging both app models onto a shared platform contract while adding the new Rust UI path.

This spec covers two things at once:

1. the shared platform contract for all Shadow apps
2. the leading Rust UI implementation direction for that contract

## What Is Stable Here

The following are intended platform contracts:

- TypeScript apps and Rust apps are both supported app models.
- there should be one shared Shadow SDK surface
- apps should be separate processes by default
- app-owned surfaces should remain the default for normal apps
- shell/system chrome should migrate onto the same platform foundation

The following are current implementation bets and may change:

- Masonry/Xilem as the leading Rust UI foundation
- exact module names inside `shadow_sdk`
- whether internal implementation ends up as one crate or several non-public crates/packages

The target model is:

- TypeScript apps and Rust apps are both first-class supported app models.
- Apps are separate processes by default.
- Apps render their own surfaces by default.
- Both app models should consume one shared Shadow SDK and one shared lifecycle/capability model.
- App authors should target Shadow-owned APIs, not upstream Xilem/Masonry internals and not scattered one-off Deno extensions.
- Masonry/Xilem is the leading candidate foundation for the Rust UI implementation layer, not the public product API.
- Shadow's own shell and system chrome should migrate onto the same foundation instead of staying on the current homegrown shell UI indefinitely.
- some system surfaces may render directly into compositor-owned textures, but that is not the default for normal apps.

## Goals

1. Support both TypeScript apps and Rust apps as first-class app models.
2. Define one shared Shadow SDK surface for platform capabilities like storage, camera, audio, nostr, cashu, notifications, lifecycle, and background work.
3. Make that shared SDK importable directly from Rust apps and bound once into the Deno/TypeScript environment in one place instead of being scattered across service-specific hooks.
4. Keep the OS-like properties that matter: process isolation, lifecycle control, explicit app metadata, packaging, testing, and service boundaries.
5. Build a declarative Rust UI model that can support serious phone-style product work, not just desktop widgets or debug panels.
6. Reuse one UI foundation across app surfaces and Shadow's own shell/system chrome where practical.
7. Create a stable Shadow-owned app API so upstream Masonry/Xilem churn does not become app-author-facing churn.

## Non-Goals

1. Supporting every Rust UI framework as a first-class platform target.
2. Making the compositor own every app's widget tree in v1.
3. Building a third-party package ecosystem or app store in v1.
4. Matching Android feature-for-feature in v1.
5. Freezing every widget and service API before any implementation work.

## App Models

Shadow should support two app models equally at the metadata and launcher layer:

- `typescript`: apps authored in TypeScript
- `rust`: apps authored in Rust

Those names describe the app-authoring model, not a forever commitment to one exact implementation underneath. Today the TypeScript path is implemented with Deno and Solid. That may evolve. The app model name should stay stable.

This document spends more time on the Rust path because that is where the new UI foundation work is concentrated. That does not imply TypeScript apps are a temporary compatibility lane or scheduled for removal.

### Shared expectations across both app models

- one app manifest model
- one lifecycle model
- one capability and permission model
- one operator/testing surface
- one shared SDK/service surface
- process isolation and app-owned surfaces by default

### Default execution shape

For both TypeScript and Rust apps, the default execution shape is:

- one app process
- one Wayland client surface
- one app launch contract
- one shared Shadow SDK surface

This is closer to Android's app/process model than to a single-process "all apps are widgets inside the shell" architecture.

## Architecture Overview

### High-Level Layers

```text
Shadow platform
  -> compositor, shell, launch/lifecycle, manifest, staging, permissions, services

Shadow SDK
  -> public app API, lifecycle, capabilities, services, tasks, UI surface, TypeScript bindings

Implementation layers
  -> Rust UI runner, TypeScript runtime bindings, system UI embedding hooks

Foundation
  -> Masonry/Xilem, Vello, wgpu, Parley, AccessKit
```

### TypeScript App Path

```text
shell launch
  -> manifest lookup
  -> typescript app launch plan
  -> Deno host bootstraps app process
  -> app uses Shadow SDK TypeScript bindings
  -> app renders through its TypeScript UI/runtime path
  -> compositor composites the surface
```

### Rust App Path

```text
shell launch
  -> manifest lookup
  -> rust app launch plan
  -> rust runner bootstraps app process
  -> app uses shadow_sdk directly
  -> Shadow UI tree updates
  -> Masonry/Xilem layout + paint
  -> Vello/wgpu render into app-owned surface
  -> compositor composites the surface
```

### Embedded System UI Path

```text
shell input
  -> embedded Shadow UI root
  -> Masonry/Xilem layout + paint
  -> render to Shadow-owned texture
  -> compositor blends shell/system surfaces with app surfaces
```

The same UI foundation should support both app-owned surfaces and embedded system UI surfaces, but app-owned surfaces remain the default path for normal apps.

## Ownership Boundaries

### Shadow Owns

- the public SDK surface
- app lifecycle semantics
- app metadata schema and launch plan
- capability and permission model
- runner integration and diagnostics
- mobile primitives and product behavior
- shell and system chrome built on top of the framework
- testing and screenshot harnesses
- TypeScript bindings for the shared SDK

### Upstream Foundation Owns

- core widget tree machinery
- layout/paint pass infrastructure
- renderer integration hooks
- text shaping internals where Parley is already the abstraction
- accessibility tree plumbing where AccessKit is the abstraction

### Important Rule

App code should depend on Shadow-owned APIs, not directly on `xilem`, `masonry`, or scattered service-specific runtime hosts.

The current `runtime-<something>-host` pattern is transitional and should converge on one shared SDK/service surface.

## Public SDK Shape

The public app-authoring surface should look like one SDK:

- Rust apps import `shadow_sdk`
- TypeScript apps import `@shadow/sdk`

The public mental model should be one SDK, even if internal implementation later splits for build, ownership, or tooling reasons.

### `shadow_sdk`

The main public app surface.

Suggested module structure:

- `shadow_sdk::app`
  - app identity
  - lifecycle hooks
  - environment
  - launch-time window metrics
  - task/effect helpers
  - background behavior
- `shadow_sdk::ui`
  - declarative UI surface
  - layout primitives
  - text/image/button primitives
  - theme and typography
- `shadow_sdk::mobile`
  - navigation stacks
  - sheets/dialogs
  - tabs
  - virtualized lists
  - gesture primitives
  - text-input/mobile affordances
- `shadow_sdk::services`
  - `storage`
  - `camera`
  - `audio`
  - `notifications`
  - `nostr`
  - `cashu`
  - additional shared platform services as they stabilize

The exact module names can move, but the public shape should stay coherent.

### Shared service rule

Reusable platform/service logic should be shared once and surfaced through the SDK for both app models.

Examples:

- a Nostr client app should use shared SDK/service code for Nostr access
- a Cashu wallet app should use shared SDK/service code for Cashu access
- TypeScript apps and Rust apps should not have separate conceptual platform APIs for the same service

The host implementation can still have internal layers, but the app-facing model should be unified.

### Internal boundaries

The public SDK may still be backed by narrower internal crates or packages. That is an implementation detail, not the product surface.

Likely internal boundaries:

- app metadata/model generation
- runner implementation
- Rust UI bridge over Masonry/Xilem
- Deno binding layer for the shared SDK
- service host internals

If internal crates exist, they should exist to keep ownership and build boundaries clean, not to create a many-crate public app-authoring experience.

## App Metadata and Launch Model

The repo already has the first step of the app-metadata cleanup:

- [runtime/apps.json](../runtime/apps.json) is the checked-in app manifest
- [scripts/runtime/generate_app_metadata.py](../scripts/runtime/generate_app_metadata.py) generates Rust metadata from that manifest
- [ui/crates/shadow-ui-core/src/generated_apps.rs](../ui/crates/shadow-ui-core/src/generated_apps.rs) is the generated Rust output

That baseline should now evolve from a runtime-only schema into a schema that can describe both app models cleanly.

The manifest needs to evolve from "every app has runtime bundle metadata" into a discriminated app model.

Target shape:

```text
app
  -> identity
  -> display metadata
  -> profiles
  -> appType
      -> typescript
      -> rust
  -> launch
  -> capabilities
  -> lifecycle policy
```

### `typescript` metadata must cover

- runtime bundle identity
- runtime host bootstrap information
- bundle/config assets
- Wayland app id
- requested capabilities

### `rust` metadata must cover

- executable identity
- target profiles and artifact names
- Wayland app id
- window policy
- requested capabilities
- optional service configuration

The launcher must not assume every app needs `SHADOW_RUNTIME_APP_BUNDLE_PATH`.

## Lifecycle Model

Shadow apps should have one lifecycle model shared across TypeScript and Rust apps.

### Required States

- `Created`
- `Launching`
- `RunningForeground`
- `RunningBackground`
- `Suspended`
- `Terminating`
- `Terminated`
- `Crashed`

### Required Events

- `on_launch`
- `on_resume`
- `on_pause`
- `on_suspend`
- `on_terminate`
- `on_low_memory`
- `on_visibility_changed`

### Lifecycle Rules

1. A backgrounded app remains a separate process unless Shadow explicitly suspends or kills it.
2. Suspension is platform-controlled, not app-controlled.
3. Apps may request durable state flushes, but the platform decides when termination happens.
4. Media and background-task behavior must be explicit capability-mediated exceptions, not accidental "still running" behavior.

### Rollout note

The shared lifecycle contract may land in the Rust path first, because that is where the new framework work is concentrated. Once the model settles, the same lifecycle should be surfaced to TypeScript apps through the shared SDK binding layer.

Current implementation note: the first shipped lifecycle subset is smaller than the full target model. Today the truthful shared contract is `foreground` / `background` state, delivered over the existing per-app platform-control socket and exposed through both Rust and TypeScript SDK surfaces.

## Rendering Model

### Default Mode: App-Owned Surface

This is the standard app path for both TypeScript and Rust apps.

Properties:

- separate app process
- app-owned event loop or runtime loop
- app-owned surface
- platform-owned lifecycle and composition

This remains the default because it gives the right isolation, debugging, crash containment, and OS-like structure.

### Embedded Mode: Shadow-Owned Texture

This is for:

- home screen
- app switcher
- lock screen
- quick settings
- notifications
- soft keyboard
- tightly-integrated system surfaces

Properties:

- compositor-owned texture target
- compositor-owned input routing
- no independent app surface
- tighter coupling to shell internals

This mode should not be the default for normal apps.

### Shared foundation across both modes

What should be shared:

- declarative programming model
- widget/layout/passes
- text shaping stack
- accessibility semantics
- theme primitives

What should not be assumed shared:

- one universal GPU device across all app processes
- one event loop across all apps
- one in-process widget tree for every app

## Programming Model

For Rust apps, the public programming model should resemble SwiftUI or Jetpack Compose more than raw Xilem or desktop widget APIs.

### Core concepts

- application root
- screen/view composition
- typed app state
- typed actions/messages
- async effects/tasks
- environment/dependency access
- navigation state
- lifecycle hooks

### Desired authoring feel

```rust
fn app() -> impl AppRoot<AppState> {
    mobile_app("Notes")
        .on_resume(load_notes)
        .on_pause(save_draft)
        .screen(notes_home())
}
```

The public Rust UI API should be:

- declarative
- typed
- opinionated about mobile navigation and state
- explicit about side effects

The public Rust API should avoid exposing raw Masonry/Xilem internals as the default pattern.

### TypeScript note

This spec does not require a new TypeScript UI framework in v1.
TypeScript apps may keep their current UI implementation path while still converging on the same lifecycle, service, capability, and testing model.

## State, Effects, and Concurrency

V1 should support:

- local view state
- app-level shared state
- async tasks spawned from user actions or lifecycle hooks
- subscription-style inputs for clocks, media state, and service streams
- cancellation on lifecycle changes where appropriate

V1 should not require apps to invent their own effect system.

Required invariants:

1. UI updates happen on the UI thread or equivalent serialized app state boundary.
2. Long-running work is offloaded through an explicit task/effect mechanism.
3. Effects can be canceled or ignored safely when screens or apps leave scope.
4. Background behavior is capability-bound and lifecycle-aware.

## Platform Services

Services must be explicit, typed, and permission-gated.

### V1 service categories

- local storage
- structured preferences
- camera access
- audio playback and media transport
- notifications
- nostr
- cashu
- networking helpers needed by first-party apps
- background task scheduling for narrow approved cases

### Service design rules

1. TypeScript apps and Rust apps should share the same conceptual service contracts.
2. The Deno/TypeScript environment should bind the shared SDK once, not through scattered service-specific hooks.
3. App code should consume typed APIs whenever practical, not raw sockets or ad hoc JSON.
4. Permission checks must be explicit and testable.
5. Service clients must behave sensibly across foreground, background, and suspended states.

## Input, Text, and Accessibility

This is a major risk area and must be first-class in v1 design.

### Input domains

- pointer
- touch
- keyboard
- text input
- IME composition
- accessibility actions
- scroll and gesture routing

### Required behavior

- deterministic focus rules
- explicit focusable semantics
- proper text selection and editing model
- IME cursor/selection area reporting
- accessibility node generation
- consistent gesture arbitration

### Important constraint

Input behavior must be defined by Shadow's public contract, not left as accidental toolkit behavior.

## Mobile Primitive Set for V1

The v1 public UI surface should be intentionally small but serious enough to build real apps.

### Required primitives

- text
- image
- icon
- button
- toggle
- text field
- multiline editor
- scroll container
- virtual list
- row/column/stack layouts
- spacer/divider
- top bar and bottom bar
- nav stack
- tabs
- sheet/dialog
- async image/media placeholders
- loading/empty/error states

### Nice-to-have but not mandatory in the first drop

- rich animation choreography
- advanced grids beyond basic virtualization
- complex drawing/canvas primitives
- desktop-specific window chrome features

## Shell and System Chrome Rewrite

Shadow should use this same UI foundation for its own shell and system chrome.

The current shell/home UI is useful as bring-up code, but it should not be treated as the long-term product architecture.

The intended direction is to replace homegrown shell UI over time with Shadow UI surfaces built on the same underlying foundation.

Priority surfaces:

- home screen / launcher
- app switcher
- lock screen
- quick settings
- notification shade
- media controls
- soft keyboard

This is important for two reasons:

1. Shadow should dogfood its own framework on real product surfaces.
2. These surfaces exercise the exact hard problems the framework must solve: focus, text, gestures, animations, accessibility, and embedded rendering.

## Testing Model

V1 must ship with testing hooks built in, not bolted on later.

### Required test layers

1. Pure widget/render tests
   - layout assertions
   - snapshot tests
   - accessibility tree assertions

2. Runner-level interaction tests
   - input event routing
   - focus and text entry
   - lifecycle transitions

3. App smoke tests
   - launch
   - home/background/resume
   - media controls where applicable

4. End-to-end platform tests
   - VM path first
   - Pixel path after the runner and artifact model are stable

## Migration and Coexistence

TypeScript apps and Rust apps should coexist as first-class supported app models.

### Transition rules

- The metadata system must support both app models simultaneously.
- New shared lifecycle and service capabilities should be defined once and exposed to both app models where practical.
- The Rust framework path will likely move faster at first because that is where the new UI foundation work is happening.
- TypeScript apps should not be treated as deprecated; they should converge on the shared SDK and lifecycle model as those contracts harden.
- First serious Rust apps should begin as narrow proofs, not immediate rewrites of every current app.

Good early targets:

- a simple notes/tasks app for navigation, list, edit, and persistence
- a media control app for lifecycle and transport semantics
- one shell/system surface using embedded rendering
- one existing TypeScript app upgraded to the shared lifecycle/service model

## Upstream Strategy

Shadow should begin by wrapping upstream Masonry/Xilem rather than immediately forking it.

Fork criteria:

- recurring need for mobile-specific behavior upstream does not provide
- instability in APIs Shadow must expose indirectly
- renderer/input hooks that Shadow must rely on but cannot keep patching externally
- performance or correctness work that becomes core to the platform

The public Shadow SDK should remain stable even if the internal implementation transitions from wrapper-heavy to fork-heavy.

## Open Questions

These are real questions, but they should be answered by targeted spikes instead of indefinite abstract discussion.

1. What is the cleanest public effect/task model for apps?
2. How much of text editing and IME can be inherited from Masonry/Xilem versus redefined in Shadow wrappers?
3. Which service categories need host-side IPC from day one versus direct Rust linking?
4. What is the minimum virtualized list primitive needed for product-scale feeds and message views?
5. Which shell/system surface should be the first one rendered directly into a compositor-owned texture?
6. What is the cleanest single binding story for exposing `shadow_sdk` into the TypeScript runtime?

## First Implementation Spikes

1. Rust runner spike
   - launch one minimal Rust Shadow UI app as a real app process
2. Shared SDK binding spike
   - prove one capability end-to-end through both Rust and TypeScript app surfaces using one shared SDK contract
3. Text and IME spike
   - prove focus, text entry, and IME geometry reporting
4. Embedded rendering spike
   - prove the same foundation can render one shell/system surface into a Shadow-owned texture

Those spikes should tighten this spec rather than replace it.
