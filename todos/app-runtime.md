# App Runtime Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Finish the runtime app platform until the next serious app can reuse it.
- Keep the Nostr timeline app as the proving ground.
- Do not start the Bitcoin wallet tranche until viewport, input, lifecycle, and capability seams are solid enough.

## Current Position

- `counter` and `timeline` are real shell apps in the VM/home flow.
- `deno_core` remains the default runtime helper. `deno_runtime` is proven, but not promoted.
- Rooted Pixel real shell now has a primary operator lane (`pixel-shell-drm` and `ui-run target=pixel`).
- The direct rooted Pixel runtime-app scripts still exist, but they are now fallback/probe lanes rather than the main operator path.
- Pixel shell runs can now either stop at home or auto-open `timeline` through that same shell lane.
- `just runtime-app-host-smokes` is now the truthful host proof surface.
- The runtime viewport contract is now unified around the shell app viewport (`540x1106` today). Pixel fits that viewport into the real panel instead of using raw panel size as the app surface.
- Host proofs already exist for focus, keyboard input, selection metadata, relay sync, and restart/cache reload.
- Host wheel scroll already works through Blitz's native `UiEvent::Wheel` path; the runtime wrapper now suppresses drag / pan gestures from turning into synthetic runtime clicks.
- The VM shelve/reopen lane is green again on the current machine.

## Stable Bets

- TS / TSX app modules.
- Solid-style authoring.
- JS emits `{ html, css }` snapshots.
- Rust owns the outer frame and native integration.
- Events are routed by stable app-owned ids.
- App/runtime owns text mutation semantics.
- `deno_core` remains the pragmatic default until a real feature forces promotion.

## Approach

- Make the operator/docs/check surface truthful before widening the contract again.
- Attack one seam at a time: operator truth, viewport contract, scroll/input parity, Pixel lane decision, then capability shaping.
- Prefer proofs on real host/VM/Pixel lanes over stdio-only coverage when picking the next chunk.
- Keep app/runtime APIs pre-alpha: optimize for fast iteration and clean design, not backwards compatibility.

## Milestones

- [x] Make the runtime operator and doc surface truthful.
- [x] Unify runtime viewport sizing across shell, Blitz host window, compositor launch, VM, and Pixel.
- [x] Finish the remaining real-app input gap: host wheel / pan proof and live VM/compositor shelve/reopen proof are both in.
- [x] Decide the near-term Pixel lane so device work stops splitting: push the real shell on device; keep direct runtime-app paths as fallback/probe lanes only.
- [ ] Keep the OS capability seam small, reusable, and easy to change while we iterate quickly toward a good app API.

## Near-Term Steps

- [x] Replace stale `just` and docs references to missing runtime host smoke scripts with the current consolidated host smokes.
- [x] Move the host window and Pixel runtime scripts off hardcoded `384x720` and raw panel sizing onto one shared viewport contract.
- [x] Prove the existing host wheel / pan path and stop drag gestures from collapsing into synthetic runtime clicks.
- [x] Add a Pixel shell-side app launch/control hook so `app=timeline` opens through the real shell path instead of only booting home.
- [ ] Decide whether any app actually needs a JS-facing wheel/scroll event shape, now that host and VM/native scroll lanes are both proven.
- [ ] Add a real rooted-Pixel shell lifecycle proof (`timeline` -> home -> reopen) so the primary device lane is validated past first launch.
- [x] Re-check the VM shelve/reopen lane after the viewport cleanup and decide whether it needs extra runtime-specific assertions.

## Implementation Notes

- 2026-04-07: `just runtime-app-keyboard-smoke` passed. That already covers focus, keyboard input, and selection metadata on the bundled host seam.
- 2026-04-07: `just runtime-app-nostr-timeline-smoke` passed. That proves relay sync, keyboard compose, restart behavior, and cache-backed timeline reload on the host runtime seam.
- 2026-04-07: The old split host commands (`runtime-app-document-smoke`, `runtime-app-click-smoke`, `runtime-app-input-smoke`, `runtime-app-focus-smoke`, `runtime-app-toggle-smoke`, `runtime-app-selection-smoke`, `runtime-app-host-smoke`, `runtime-app-compositor-smoke-gpu`) were removed from the live `just` surface because their scripts no longer exist.
- 2026-04-07: The viewport contract is now unified around the shell app viewport from `shadow-ui-core` (`540x1106` today).
  - `shadow-blitz-demo` defaults to that viewport on the host.
  - `shadow-compositor` and `shadow-compositor-guest` both use the same viewport contract when no override is supplied.
  - Pixel runtime scripts fit that logical viewport into the real panel and pass the fitted size to both the guest compositor and the runtime client (`1080x2212` on a Pixel 4a panel).
- 2026-04-07: Host scroll did not need a new runtime JSON event shape for the current app lane.
  - Blitz already converts host wheel input into `UiEvent::Wheel` and scrolls overflow containers natively.
  - The real runtime-wrapper bug was that press-drag-release gestures could still synthesize a runtime click after a pan.
  - `RuntimeDocument` now cancels synthetic clicks after pointer movement crosses a small threshold, and unit coverage now proves host wheel scroll, finger-pan scroll, and tap-to-click separately.
- 2026-04-07: The VM shelve/reopen smoke is green again.
  - The shell launch regression was that `shadow-compositor` spawned `shadow-blitz-demo` without forcing runtime mode, so the self-exiting static demo launched instead of the real runtime app.
  - `shadow-blitz-demo` now honors launch-provided title and Wayland app-id overrides, and the compositor sets runtime mode plus app-specific launch env.
  - `ui-vm-timeline-smoke` no longer forces `SHADOW_UI_VM_REFRESH_RUNTIME_ENV=1` on every run, so it validates the live VM lane instead of first spending minutes rebuilding the aarch64 runtime host unless the operator explicitly asks for that refresh.
- 2026-04-07: The near-term Pixel lane is now the real shell/home path.
  - `pixel-shell-drm` is the primary rooted-Pixel operator rung, and `ui-run target=pixel` now routes there instead of to the old direct-runtime timeline path.
  - The old direct runtime-app Pixel scripts remain in the repo as fallback/probe tools for narrower runtime or GPU work.
- 2026-04-07: The rooted Pixel shell lane can now auto-open `timeline` without dropping back to the old direct-runtime path.
  - `ui-run target=pixel app=timeline` now exports `PIXEL_SHELL_START_APP_ID=timeline`, and `pixel_shell_drm.sh` turns that into `SHADOW_GUEST_SHELL_START_APP_ID=timeline` for the guest compositor.
  - The guest compositor stays in shell mode, publishes the home frame, and then launches `timeline` through the same `launch_or_focus_app()` path used by later control requests.
  - The Pixel shell lane now also expects a runtime client process plus a mapped window when an initial shell app is requested, so this entrypoint fails if the shell never actually opens the app.

## Current Runtime Contract

- JS -> Rust: `{ html, css? }`
- Rust -> JS events always include:
  - `type`
  - `targetId`
- Optional event payload:
  - `value`
  - `checked`
  - `selection`
  - `pointer`
  - `keyboard`
- Host wheel / pan scrolling still lives in the Blitz document layer; it is not yet forwarded through the JS runtime event schema.

## What Is Out Of Scope Right Now

- Adding more apps just to prove variety.
- Promoting `deno_runtime` by default without concrete feature pressure.
- Perfect browser compatibility.
- IME / composition correctness.
- Fine-grained Rust-side DOM patching.

## Related Plans

- `todos/gpu.md`: device rendering/perf work that still affects typing and interaction quality.
