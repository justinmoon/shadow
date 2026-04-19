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

- [ ] Replace the current per-call runtime Nostr host path with one persistent OS Nostr service.
- [ ] Share one relay pool and one websocket connection per relay within an account scope.
- [ ] Share one verified event cache and local index across apps.
- [ ] Define the first public `shadow_sdk::nostr` API for Rust and matching `@shadow/sdk` bindings for TypeScript.
- [ ] Define the OS-owned signer flow with approval prompts and durable app-level policy.
- [ ] Land the first read-first Rust Nostr app: timeline, thread, profile, refresh, warm restore.
- [ ] Add compose and publish once the text-input seam is ready.

## Near-Term Steps

- [x] Freeze scope language: use `account` or `identity` for Nostr ownership, not manifest `profiles`.
- [ ] Decide the initial internal scope model: one active account today, but account-scoped service boundaries from the start.
- [x] Replace `listKind1` / `publishKind1` as the conceptual center with `query`, `count`, `get_event`, `get_replaceable`, `subscribe`, `publish`, and `sync`.
- [x] Freeze the first seam semantics: `query` / `count` / `get_event` / `get_replaceable` are local cache reads; `sync` is explicit relay import; `publish` is reserved for signed relay publication, not local fake insertion.
- [ ] Decide whether to back the shared cache with `nostr-sqlite` directly or keep a thinner Shadow-owned storage layer over SQLite first.
- [ ] Sketch the first Rust and TypeScript SDK calls and the event/filter types they share.
- [ ] Define the first signer prompt and permission states: deny, allow once, always allow.
- [ ] Choose the read-first app slice order: home timeline -> thread -> profile.
- [x] Land the first generic read-side SDK slice with a single filter object first, then keep the old kind1 helpers only as compatibility wrappers until their callers migrate.

## Implementation Notes

- There is no real Shadow multi-user or profile system yet. The `profiles` field in [runtime/apps.json](../runtime/apps.json) is for target/build lanes like `vm-shell` and `pixel-shell`, not end-user identity.
- The Nostr service should still be internally account-scoped from day one so we do not hard-wire the whole stack to a singleton. Start with one active default account and make the scope explicit in the internal model.
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
- The Rust `shadow_sdk::services::nostr` module is feature-gated for now:
  - enable `shadow-sdk/nostr` for the generic cache API
  - `shadow-sdk/runtime-host` includes that feature automatically
  - default UI workspace builds keep the module off so we do not force the UI vendor set to absorb `deno_core` yet
- The first Rust app should validate product reality, not just plumbing. Read-first is enough for the first serious slice if it has:
  - timeline list quality
  - thread navigation
  - profile navigation
  - cached warm restore
  - visible sync state
