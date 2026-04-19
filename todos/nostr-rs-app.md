Living plan. Revise it as we learn. Do not treat this as a fixed contract.

# Shadow Rust Nostr App

## Scope

Build the first serious Rust Shadow app as a Nostr client, and define the OS-owned Nostr platform surface it needs:

- shared event cache
- shared relay pool
- OS-owned signer and approval flow
- one public `shadow_sdk::nostr` surface for Rust and TypeScript apps
- a VM-first Rust app with timeline, thread, profile, and persistence

This plan covers both the app and the Nostr service/platform seam below it.

## Approach

Start with a read-first Rust Nostr app and the smallest honest OS Nostr service behind it.

Do not expose `nostr_sdk::Client` directly to apps. Use `rust-nostr` as an internal foundation, then present a Shadow-owned API through `shadow_sdk`.

Do not hard-code event kinds into top-level SDK function names. The core API should be cache-first and filter/event based, with optional helper builders or typed convenience wrappers on top.

## Milestones

- [x] Replace the current per-call runtime Nostr host path with one persistent OS Nostr service.
- [ ] Share one relay pool and one websocket connection per relay within an account scope.
- [ ] Share one verified event cache and local index across apps.
- [ ] Define the first public `shadow_sdk::nostr` API for Rust and matching `@shadow/sdk` bindings for TypeScript.
- [ ] Define the OS-owned signer flow with approval prompts and durable app-level policy.
- [ ] Land the first read-first Rust Nostr app: account bootstrap, timeline, thread, profile, refresh, warm restore.
- [ ] Add compose and publish once the text-input seam is ready.

## Near-Term Steps

- [x] Freeze scope language: use `account` or `identity` for Nostr ownership, not manifest `profiles`.
- [ ] Decide the initial internal scope model: one active account today, but account-scoped service boundaries from the start.
- [x] Land one OS-owned active Nostr account slice: load current account, import `nsec`, generate a new account, and persist it outside app-local state.
- [x] Replace `listKind1` / `publishKind1` as the conceptual center with `query`, `count`, `get_event`, `get_replaceable`, `subscribe`, `publish`, and `sync`.
- [x] Freeze the first seam semantics: `query` / `count` / `get_event` / `get_replaceable` are local cache reads; `sync` is explicit relay import; `publish` is reserved for signed relay publication, not local fake insertion.
- [ ] Decide whether to back the shared cache with `nostr-sqlite` directly or keep a thinner Shadow-owned storage layer over SQLite first.
- [~] Sketch the first Rust and TypeScript SDK calls and the event/filter types they share.
- [ ] Define the first signer prompt and permission states: deny, allow once, always allow.
- [x] Choose the read-first app slice order: home timeline -> thread -> profile.
- [x] Land the first generic read-side SDK slice with a single filter object first, then keep the old kind1 helpers only as compatibility wrappers until their callers migrate.
- [~] Land the first Rust UI framework seam in `shadow_sdk::ui`: app runner, window/env wiring, theme, and a tiny set of reusable primitives over Xilem/Masonry.
- [~] Land the first Rust timeline slice on that framework: feed-first list, refresh, note detail, warm restore, visible sync state.
- [x] Add first-run timeline onboarding: import or generate an account, then expose the active `npub` in-app.
- [x] Remove shared-store demo seed notes so the Rust app only surfaces real cached relay data.
- [x] Remove the TypeScript timeline's fake demo feed and local fake publish path so the compatibility app also stays read-first over real cached relay data.

## Implementation Notes

- The current shared-engine slice now exists:
  - `shadow-system` can run a dedicated `--nostr-service <socket-path>` daemon.
  - TypeScript runtime hosts auto-start that daemon on first Nostr use when a socket path can be derived from the state dir / sqlite path.
  - The daemon owns the long-lived `nostr_sdk::Client`, relay registry, and sqlite-backed cache writes.
  - `shadow_sdk::services::nostr` now speaks to that daemon when `SHADOW_RUNTIME_NOSTR_SERVICE_SOCKET` is set, while still falling back to direct sqlite reads in local/unit-test environments.
  - the TypeScript runtime now has a generic `nostr.sync(...)` path, with `syncKind1(...)` kept as a compatibility wrapper.
- This is a single-account, single-daemon slice for now. It improves the real OS-owned seam without pretending multi-account, signer policy, or live subscriptions are solved.
- There is no real Shadow multi-user or profile system yet. The `profiles` field in [runtime/apps.json](../runtime/apps.json) is for target/build lanes like `vm-shell` and `pixel-shell`, not end-user identity.
- The Nostr service should still be internally account-scoped from day one so we do not hard-wire the whole stack to a singleton. Start with one active default account and make the scope explicit in the internal model.
- The next product seam is not more generic timeline chrome by itself. The app needs a real user identity first:
  - one OS-owned active Nostr account persisted alongside the shared Nostr state
  - app-visible summary only (`npub`, source, setup state), not raw secret leakage as the long-term API
  - first-run app onboarding that can import an `nsec` or generate a new account
  - a simple in-app account screen so the user can see the active `npub` on-device
  - starter-feed polish can begin before a full follow-graph model exists, but the real follow/contact model belongs with the later signer/write path
- The current account/bootstrap slice now exists:
  - `shadow_sdk::services::nostr` exposes `current_account`, `generate_account`, and `import_account_nsec`
  - the shared Nostr daemon persists account state next to the shared Nostr sqlite/db state
  - Rust apps can now auto-start that daemon through `SHADOW_SYSTEM_BINARY_PATH` when the socket is configured but the service is not running yet
  - the Rust timeline app now gates first run on account setup and exposes the active `npub` in-app
  - TypeScript runtime host ops and `@shadow/sdk` now expose the same account entrypoints: `currentNostrAccount`, `generateNostrAccount`, `importNostrAccountNsec`, plus the grouped `nostr.currentAccount()` / `generateAccount()` / `importAccountNsec()` forms
  - shared protocol/event/filter typing between Rust and TypeScript is still incomplete; this slice only closes the account/read API gap
- A shared clipboard seam now exists across both app models:
  - `shadow_sdk::services::clipboard::write_text` is the Rust-side public API
  - `shadow-system` binds that into the TypeScript runtime as `clipboard.writeText(...)` and `writeClipboardText(...)`
  - the Rust timeline account screen can now copy the active `npub` into the device clipboard instead of trapping identity inside the app UI
- The next below-app Nostr seam should likely be shared contract parity:
  - move the public Nostr request/response/account/event types behind one explicit `shadow_sdk::services::nostr` type module
  - expose the same shapes to TypeScript with real declarations instead of per-app aliases and test-local shape drift
  - do that before a real signer/write path so approval and publish APIs sit on stable shared types
- The signer should be OS-owned, Amber-style. Apps request publication or signing work from the OS; the OS decides whether to prompt, deny, sign once, or sign automatically because the user already granted standing approval.
- The first public SDK should likely expose:
  - protocol types like `Event`, `EventId`, `Filter`, `Kind`, `PublicKey`, `RelayUrl`, `Timestamp`
  - cache reads like `query(filter_or_filters)`, `count(filter_or_filters)`, `get_event(id)`, and `get_replaceable(kind, author, identifier?)`
  - live updates like `subscribe(filter_or_filters)`
  - writes like `publish(request)`
  - explicit network refresh like `sync(request)`
- For the first landable seam, narrow that to one filter object instead of multi-filter OR queries. That keeps the cache API honest while leaving room to add array filters later.
- Be explicit about semantics:
  - `query` / `count` / `get_event` / `get_replaceable` read only from the local shared cache.
  - `sync` talks to relays and imports into that cache.
  - `publish` should eventually mean signed relay publication through the OS-owned signer.
  - The current `publishKind1` local insert helper and `publishEphemeralKind1` throwaway-key relay path are legacy/demo helpers, not the long-term model.
- Raw REQ/subscription escape hatches may still be useful, but they should not be the primary app-authoring story.
- `window.nostrdb.js` is good prior art for the app-facing shape: the public surface should feel like a shared store with query and subscribe, not like every app owns its own relay client.
- `fetch` / `observe` can still exist as internal or advanced concepts, but they should not displace `query` / `subscribe` as the primary app mental model.
- `rust-nostr` looks like the right internal foundation:
  - `nostr` for protocol types
  - `nostr-sdk` for relay pool, subscriptions, and publish flow
  - `nostr-sqlite` if we want to lean on its storage layer instead of keeping the current handwritten cache schema
- The current in-repo Nostr path is still a spike:
  - it stores a reduced kind-1-only schema
  - it creates short-lived `nostr_sdk::Client` instances per sync/publish path
  - it is useful as a proof, but it does not satisfy the shared-pool or shared-cache architecture we want
- The immediate implementation seam is to introduce the generic read-side API shape now, backed by the current host/store, while deferring the persistent shared engine and real signer to the next deeper seams.
- The next product slice should stay read-first:
  - keep the timeline mostly feed-first
  - use the shared `query` + `sync` path
  - demote or remove misleading local-only compose affordances
  - add note detail before thread/profile, unless the cache grows reply/profile metadata first
- The Rust `shadow_sdk::services::nostr` module is feature-gated for now:
  - enable `shadow-sdk/nostr` for the generic cache API
  - `shadow-system` pulls that host-side feature in when it binds the TypeScript runtime
  - default UI workspace builds keep the module off so app-facing SDK builds do not pull in extra runtime-service dependencies unless they need them
- The first Rust app should validate product reality, not just plumbing. Read-first is enough for the first serious slice if it has:
  - timeline list quality
  - thread navigation
  - profile navigation
  - cached warm restore
  - visible sync state
- The immediate framework/app seam is:
  - keep the public app-facing model under `shadow_sdk::ui` so app authors still see one SDK
  - use Xilem/Masonry as the implementation foundation, not the product API
  - add a Shadow-owned app runner that applies Shadow window env, safe-area padding, and Wayland app-id wiring
  - start with a very small primitive set: screen, panel/card, section title, buttons, text input, and scroll container
  - keep note/timeline-specific components in the app crate until repeated product patterns become obvious
- The current Rust UI seam is still a spike, not the final product API:
  - the first app compiles and renders through `shadow_sdk::ui`, but it still reaches into upstream Xilem composition/effect types in places
  - the next framework seam should wrap more of that surface behind Shadow-owned context, composition, and effect helpers instead of reexporting raw upstream building blocks forever
- The first Rust timeline slice now includes:
  - cache-backed feed
  - explicit refresh against the shared Nostr engine
  - route-based timeline -> thread -> profile navigation
  - cached kind-0 profile metadata headers via `get_replaceable`
  - local thread parent/reply loading from shared cached reference data
  - on-demand thread fetch through the shared engine: exact parent ids plus generic referenced-event sync for replies
  - thread-only cached notes can now be opened even when they never appeared in the top-level timeline feed
  - startup and lifecycle log markers for smoke coverage
  - VM launcher metadata/tests and VM smoke coverage
- The shared Nostr store no longer seeds fake `shadow-note-*` rows into empty caches, and initialization now scrubs those old demo ids from existing sqlite state so upgraded VMs do not keep surfacing placeholder notes.
- Timeline refresh failures should be presented as cache state, not product panic: when relays fail but cached notes exist, the app should keep showing the feed with a neutral cached-data message and log the relay error separately.
- The TypeScript timeline compatibility app is now read-only over the shared cache:
  - it no longer falls back to hard-coded demo notes when the cache is empty
  - it no longer exposes the local `publishKind1` fake-note path in product UI
  - runtime and Pixel smokes now validate real relay-seeded note persistence instead of fake local compose
- The next Nostr product blocker is now clear:
  - the shared cache now stores reply/root relationships, exact references, and cache-side reply/reference queries
  - the next deeper app seam is the first real write path: a reply composer that forces multiline editing, sheet/dialog presentation, and a less ad hoc async/navigation model in `shadow_sdk::ui`
