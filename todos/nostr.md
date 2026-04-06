# Nostr Plan

Living note. Revise it as the OS/runtime boundary gets clearer.

## Goal

- OS-owned Nostr capability.
- Tiny apps call small system APIs.
- One client/cache/signer below apps, not duplicated per app.

## Current Bet

- App-facing JS API lives at `@shadow/app-runtime-os`.
- First slices are host-only and mocked.
- The app uses `listKind1` and `publishKind1`.
- The default `deno_core` helper now installs the fake Nostr service below app JS in the runtime helper / host extension layer.
- The default `deno_core` helper now persists that mock feed in a sqlite cache, so host smokes can prove the OS-owned data seam survives helper restarts.
- The alternate `deno_runtime` helper still uses a temporary bundle fallback for this seam until we decide it is worth promoting that backend further.

## First Ladder

- [x] Host-only OS API seam.
  `just runtime-app-nostr-smoke` proves a runtime app can load kind 1 notes from a system API and publish a new kind 1 note without owning Nostr logic itself. `just runtime-app-nostr-smoke-deno-runtime` proves the same seam on the alternate backend.
- [x] Move the fake system Nostr service below JS.
  Keep the same app-facing API, but back it from the default runtime helper / Rust side instead of bootstrap JS.
- [x] Add sqlite-backed local cache and feed queries.
  `just runtime-app-nostr-cache-smoke` proves the default backend persists published kind 1 notes across fresh helper processes and still serves author-filtered feed queries through the same OS API.
- [x] Add real relay fetch for kind 1 events.
  `just runtime-app-nostr-timeline-smoke` now starts a local `nak` relay, seeds deterministic kind 1 notes, syncs them through the OS-owned `syncKind1` API, and verifies the runtime timeline app renders both relay-backed notes and a keyboard-composed local note.
- [x] Prove the same API on the rooted Pixel runtime app lane.
  `just pixel-runtime-app-nostr-gm-drm` and `just pixel-runtime-app-nostr-timeline-drm` now stage the same app/runtime seam on the rooted Pixel through the guest compositor DRM path. The GM path is interactive and publish-capable; the timeline path now renders full-screen on device and reaches repeated presented frames with real relay-backed sync.
- [ ] Remove the temporary `deno_runtime` fallback for this seam.
- [ ] Add OS-owned signer boundary for publishing.
- [ ] Add richer timeline behaviors: paging/scrolling, explicit refresh UX, and compose/send once the keyboard/device-input lane is ready.
