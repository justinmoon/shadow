Living plan. Revise it as we learn. Do not treat this as a fixed contract.

# Shadow Rust Nostr App

## Scope

Build the first serious Rust Shadow app as a real Nostr client, and define the
OS-owned Nostr platform surface it needs:

- shared event cache
- shared relay pool
- OS-owned signer and approval flow
- one public `shadow_sdk::services::nostr` surface for Rust and TypeScript apps
- a VM-first Rust app with honest Home, Explore, thread, profile, and publish
  flows

This plan covers both the app and the Nostr service/platform seam below it.

## Approach

Keep the product honest:

- `Home` means the follow graph only
- `Explore` is separate discovery, not a secret Home fallback
- no fake notes
- no fake publish path
- no fake starter account

Bootstrap a real account, expose the real `npub`, and let the user build a real
follow graph. If richer first-run onboarding is needed later, make it explicit
and user-chosen, for example optional starter packs, not hidden scaffolding.

Do not expose `nostr_sdk::Client` directly to apps. Use `rust-nostr` as the
internal foundation and keep the public boundary Shadow-owned.

## Milestones

- [x] Replace the old per-call runtime Nostr host path with one persistent OS
      Nostr service.
- [ ] Share one relay pool and one websocket connection per relay within an
      account scope.
- [~] Share one event cache and local index across apps through the OS-owned
      service.
- [x] Define the first public Nostr SDK surface for Rust and matching
      TypeScript bindings.
- [x] Define the OS-owned signer flow with approval prompts and durable
      app-level policy.
- [~] Land the first serious Rust Nostr app: account bootstrap, Home, Explore,
      thread, profile, refresh, warm restore.
- [~] Land honest compose/publish flows once the UI framework seams are ready.

## Near-Term Steps

- [ ] Decide the initial internal scope model: one active account today, but
      account-scoped service boundaries from the start.
- [ ] Decide whether the shared cache should stay Shadow-owned SQLite first or
      move closer to `nostr-sqlite`.
- [x] Land one OS-owned active account slice: load current account, import
      `nsec`, generate a new account, persist it outside app-local state.
- [x] Replace old kind-specific APIs with `query`, `count`, `get_event`,
      `get_replaceable`, `publish`, and `sync`.
- [x] Freeze the basic semantics:
  - cache reads are local
  - `sync` imports from relays
  - `publish` signs and sends to relays
- [x] Land the first follow-management slice over the shared kind-3 contact
      list.
- [x] Split discovery from Home with an explicit Explore route.
- [x] Remove fake store/demo data from both Rust and TypeScript Nostr apps.
- [~] Clean up the Rust UI ergonomics that this app is currently exposing:
  - theme/env context
  - task/effect surface
  - platform event helper
- [ ] Extend compose beyond reply-only into real top-level note creation.
- [ ] Tighten profile and thread UX into a serious client, not just a seam
      demonstration.
- [ ] Decide whether optional starter packs are worth adding later as explicit
      follow-list imports. Do not add a starter-account concept.

## Implementation Notes

- The shared-engine slice is real:
  - `shadow-system` can run a dedicated `--nostr-service <socket-path>` daemon
  - runtime hosts auto-start it on first Nostr use when socket/session config is
    available
  - the daemon owns the long-lived relay client, relay registry, and cache
    writes
- This is still a single-account slice today. The important thing is that the
  internal service seam should stay account-scoped so we do not hard-wire the
  whole stack to a singleton forever.
- There is no real Shadow multi-user/profile system yet. Manifest `profiles`
  are build/target lanes, not end-user identity.
- The public Nostr boundary is now operation-typed rather than a flat numeric
  kind bag. Keep that pattern: Shadow-owned product operations at the boundary,
  raw protocol details inside the host.
- The OS-owned signer seam is real:
  - per-app policy
  - deny / allow once / always allow
  - compositor-owned prompt UI
  - deterministic headless override for noninteractive tests
- The current app is no longer a fake read demo. It now has:
  - real account bootstrap
  - visible/copyable `npub`
  - honest empty Home semantics
  - explicit Explore discovery
  - thread/profile navigation
  - real reply publish through the shared signer
  - real follow/unfollow through shared contact-list publish
- The current biggest problem is no longer “missing Nostr plumbing.” It is app
  and framework ergonomics. The timeline app still carries too much manual
  async/state/platform glue.
- The first cleanup slice is now in:
  - the app renders through a Shadow-owned `UiContext` instead of threading raw
    `Theme` through route/render helpers
  - `shadow_sdk::ui::TaskSlot` / `with_task` now own task identity and stale
    completion filtering instead of app-local token counters
  - the raw platform socket server loop moved under
    `shadow_sdk::app::spawn_platform_request_listener`
  - the timeline task/effect seam now sits behind a dedicated `tasks.rs`
    module and one `TimelineTasks` state object instead of scattering slot
    fields and `with_task(...)` wiring through `main.rs`
- That still is not the end state. The timeline app still owns:
  - one `Pending*` struct per job family
  - route prep that still mixes inline cache reads with async follow-up work
  - app-specific task runners and finish handlers that should shrink further as
    the shared framework grows
- The next cleanup slice should attack that remaining app-local task/effect
  shape, not add more product-specific glue on top of it.
- The next useful product work is not a starter account. That would hide product
  truth and distract from the real platform problems.
- If first-run richness becomes important later, prefer explicit starter packs
  or explicit follow imports over any hidden fallback/feed seeding.
- The next Nostr product seams, after framework cleanup, are:
  - top-level compose
  - better thread UX
  - better profile UX
  - optional curated follow import if the empty-account experience still needs
    more help
- The local relay-backed test story is getting better, but it should keep
  converging toward one shared test harness instead of each smoke owning its own
  relay setup logic.
