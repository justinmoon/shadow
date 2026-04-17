# App Runtime Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Finish the runtime app platform until the next serious app can reuse it.
- Keep the Nostr timeline app as the precedent, not the only proving ground.
- Start a simple Cashu wallet now that viewport, input, and lifecycle are solid enough.
- Build things we actually want to use; generalize only after both `nostr` and `cashu` feel real.
- First Cashu target is now in: trusted-mint wallet with durable seed/db state, Lightning funding, token send/receive, and Lightning pay flows.
- Next Cashu pressure should be restart/shell proofs and better operator ergonomics, not premature generalization.

## Current Position

- `counter` and `timeline` are real shell apps in the VM/home flow.
- The current app-facing host seam already exists in one concrete domain: `Shadow.os.nostr`.
- `Shadow.os.cashu` now exists as the second concrete runtime-host domain, backed by CDK plus a durable mnemonic + `redb` wallet store.
- `deno_core` remains the default runtime helper. `deno_runtime` is proven, but not promoted.
- Rooted Pixel real shell now has a primary operator lane (`pixel-shell-drm` and `just run target=pixel`).
- The direct rooted Pixel runtime-app scripts still exist, but they are now fallback/probe lanes rather than the main operator path.
- Pixel shell runs can now either stop at home or auto-open `timeline` through that same shell lane.
- `pixel-shellctl` now gives the rooted Pixel shell a reusable launch/home/state control seam once the compositor is live.
- The rooted Pixel shell lifecycle lane is now green on at least one real device (`09051JEC202061`).
- `just runtime-app-host-smokes` is now the truthful host proof surface.
- The runtime viewport contract is now unified around the shell app viewport (`540x1106` today). Pixel fits that viewport into the real panel instead of using raw panel size as the app surface.
- Host proofs already exist for focus, keyboard input, selection metadata, relay sync, and restart/cache reload.
- `just runtime-app-cashu-wallet-smoke` is now green against a local `cdk-mintd` fakewallet mint: trust mint, mint invoice into balance, send token, receive token, pay Lightning invoice, then remint it.
- Host wheel scroll already works through Blitz's native `UiEvent::Wheel` path; the runtime wrapper now suppresses drag / pan gestures from turning into synthetic runtime clicks.
- The VM shelve/reopen lane was green in the 2026-04-07 smoke and is covered by the current `just smoke target=vm` branch gate.
- `cdk` is now cloned locally at `~/code/oss/cdk` for Cashu wallet work.

## Stable Bets

- TS / TSX app modules.
- Solid-style authoring.
- JS emits `{ html, css }` snapshots.
- Rust owns the outer frame and native integration.
- Events are routed by stable app-owned ids.
- App/runtime owns text mutation semantics.
- `deno_core` remains the pragmatic default until a real feature forces promotion.
- Domain-shaped OS APIs are fine for now: `Shadow.os.<domain>`, not a generalized capability framework.

## Approach

- Copy the Nostr layering for Cashu before abstracting anything:
  - JS runtime shim installs `Shadow.os.cashu`.
  - Deno bootstrap maps tiny Cashu methods to Rust ops.
  - Rust host owns persistence, CDK integration, and request validation.
  - runtime apps keep importing thin wrappers from `@shadow/app-runtime-os`.
- Attack one seam at a time: Cashu host state, tiny app API, wallet app flow, then live-mint proof.
- Prefer a truthful host proof surface before shell/Pixel polish for the wallet lane.
- Assume one trusted mint and sats-only in the first slice unless a real use-case forces more.
- Keep app/runtime APIs pre-alpha: optimize for fast iteration and clean design, not backwards compatibility.

## Milestones

- [x] Make the runtime operator and doc surface truthful.
- [x] Unify runtime viewport sizing across shell, Blitz host window, compositor launch, VM, and Pixel.
- [x] Finish the remaining real-app input gap: host wheel / pan proof and live VM/compositor shelve/reopen proof are both in.
- [x] Decide the near-term Pixel lane so device work stops splitting: push the real shell on device; keep direct runtime-app paths as fallback/probe lanes only.
- [x] Land a host-only `Shadow.os.cashu` seam backed by CDK with durable seed + wallet state.
- [x] Ship a runtime Cashu wallet app that can add a trusted mint, show balance, receive a token, and send a token.
- [x] Add Lightning invoice funding and payment flows so the wallet is actually useful.
- [ ] Revisit shared capability conventions only after both `Shadow.os.nostr` and `Shadow.os.cashu` feel real in app code.

## Near-Term Steps

- [x] Replace stale `just` and docs references to missing runtime host smoke scripts with the current consolidated host smokes.
- [x] Move the host window and Pixel runtime scripts off hardcoded `384x720` and raw panel sizing onto one shared viewport contract.
- [x] Prove the existing host wheel / pan path and stop drag gestures from collapsing into synthetic runtime clicks.
- [x] Add a Pixel shell-side app launch/control hook so `app=timeline` opens through the real shell path instead of only booting home.
- [x] Add a real rooted-Pixel shell lifecycle proof (`timeline` -> home -> reopen) so the primary device lane is validated past first launch.
- [x] Re-check the VM shelve/reopen lane after the viewport cleanup and decide whether it needs extra runtime-specific assertions.
- [x] Define the first Cashu wallet contract around one trusted mint, sats, durable seed storage, and a durable wallet db.
- [x] Add a new Rust runtime host extension beside `runtime-nostr-host` and compose it into `shadow-runtime-host`.
- [x] Extend `shadow_runtime_os.js` and the runtime bootstrap so apps can call a tiny `Shadow.os.cashu` surface through `@shadow/app-runtime-os`.
- [x] Build the first runtime Cashu wallet app with the minimal flows: add mint, balance, receive pasted token, send token.
- [x] Add a deterministic host smoke for Cashu persistence and wallet actions before any Pixel-specific wallet work.
- [ ] Prove Cashu wallet restart persistence through a real host-session relaunch and a shell relaunch.
- [ ] Run the Cashu wallet through the VM / Pixel shell lane as the next operator proof, not a special direct-runtime path.

## Implementation Notes

- 2026-04-08: The next serious app is now the Cashu wallet, not a generic capability exercise.
  - The current Nostr path already proves the shape we should copy: `shadow_runtime_os.js` exposes domain wrappers, the Deno bootstrap installs `Shadow.os.<domain>`, and a Rust extension crate owns the real host behavior.
  - `cdk` is cloned locally at `~/code/oss/cdk` (`v0.16.0` tag exists; HEAD is `94d06f46` on 2026-04-07). Its README and CLI surface are explicit that the project is alpha, which matches this repo's pre-alpha posture.
  - The smallest wallet slice that looks useful is not the whole mint/melt surface. Start with durable wallet state plus trusted-mint balance / receive / send. Add invoice minting only after that lane is solid.
- 2026-04-08: The first usable Cashu wallet tranche is now in.
  - `shadow_runtime_os.js` is now a thin hard-require bridge. It no longer carries app-side mock/fallback behavior for `nostr` or `cashu`; if the runtime host does not install `Shadow.os.<domain>`, the app fails loudly.
  - `runtime-cashu-host` now keeps one session-scoped CDK repository in Deno op state instead of reopening `redb` on every call. That fixed the `Database already open. Cannot acquire lock.` failure and matches the intended host architecture better.
  - The durable wallet store is `redb` (`wallet.redb`) plus a file-backed BIP39 mnemonic under `SHADOW_RUNTIME_CASHU_DATA_DIR`. `cdk-sqlite` was intentionally skipped because it collided with the existing Nostr sqlite seam on `libsqlite3-sys`.
  - `scripts/runtime_app_cashu_wallet_smoke.sh` now boots a local `cdk-mintd` fakewallet mint, proves trusted-mint persistence and wallet actions through the live runtime host, and finishes with invoice funding plus invoice payment using the wallet itself.
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
- 2026-04-07: The VM shelve/reopen smoke was green.
  - The shell launch regression was that `shadow-compositor` spawned `shadow-blitz-demo` without forcing runtime mode, so the self-exiting static demo launched instead of the real runtime app.
  - `shadow-blitz-demo` now honors launch-provided title and Wayland app-id overrides, and the compositor sets runtime mode plus app-specific launch env.
  - `scripts/ui_vm_timeline_smoke.sh` no longer forces a runtime-env rebuild on every run, so it validates the live VM lane instead of first spending minutes rebuilding the aarch64 runtime host.
- 2026-04-07: The near-term Pixel lane is now the real shell/home path.
  - `pixel-shell-drm` is the primary rooted-Pixel operator rung, and `just run target=pixel` now routes there instead of to the old direct-runtime timeline path.
  - The old direct runtime-app Pixel scripts remain in the repo as fallback/probe tools for narrower runtime or GPU work.
- 2026-04-07: The rooted Pixel shell lane can now auto-open `timeline` without dropping back to the old direct-runtime path.
  - `just run target=pixel app=timeline` now calls `pixel_shell_drm.sh --app timeline` through `shadowctl`, and the launcher turns that into `SHADOW_GUEST_SHELL_START_APP_ID=timeline` for the guest compositor.
  - The guest compositor stays in shell mode, publishes the home frame, and then launches `timeline` through the same `launch_or_focus_app()` path used by later control requests.
  - The Pixel shell lane now also expects a runtime client process plus a mapped window when an initial shell app is requested, so this entrypoint fails if the shell never actually opens the app.
- 2026-04-07: The rooted Pixel shell now has a matching control helper and lifecycle smoke harness.
  - `pixel-shellctl.sh` talks to `/data/local/tmp/shadow-runtime/shadow-control.sock` over rooted `adb shell` plus Toybox `nc -U`, and `state --json` mirrors the VM control-state shape.
  - `pixel-shell-timeline-smoke.sh` now starts the rooted shell in hold mode, waits for `timeline` to launch through the real shell path, sends `home`, reopens `timeline`, and checks the same focused/mapped/shelved state transitions as the VM smoke.
- 2026-04-07: The rooted Pixel shell lifecycle smoke is live-green on `09051JEC202061`.
  - `PIXEL_SERIAL=09051JEC202061 just pixel-shell-timeline-smoke` passed and wrote its run log under `build/pixel/shell/20260407T230414Z/`.
  - The smoke proved `timeline` launch, `home` shelving, and `timeline` reopen through the real rooted shell lane, then restored Android cleanly.
  - The first live failure was a smoke bug, not a shell bug: lifecycle timeouts were starting before host-side artifact prep finished. The smoke now waits for the rooted `shadow-control.sock` to exist before starting lifecycle assertions.

## Current Runtime Contract

- JS -> Rust: `{ html, css? }`
- `Shadow.os.nostr` and `Shadow.os.cashu` both exist today as concrete host domains.
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

- Adding more apps just to prove variety beyond the Cashu wallet tranche.
- Promoting `deno_runtime` by default without concrete feature pressure.
- Perfect browser compatibility.
- IME / composition correctness.
- Fine-grained Rust-side DOM patching.

## Related Plans

- `todos/gpu.md`: device rendering/perf work that still affects typing and interaction quality.
