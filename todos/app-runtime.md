# App Runtime Plan

Living note. Revise it as we learn. Do not treat this as a fixed contract.

## Goal

- TS / TSX app modules.
- Familiar Solid-like authoring style.
- Native OS APIs from the runtime; no browser dependency.
- Blitz-backed UI path for shell apps.

## Current Bet

- Deno / `deno_core` runtime seam.
- Keep the helper backend swappable; `deno_runtime` is now a proven host-side alternative for the same session contract.
- Tiny TSX compile step with `babel-preset-solid`.
- `generate: "universal"` is the first bet.
- JS side owns the reactive tree.
- JS side emits `{ html, css }` snapshots.
- Rust side owns a persistent Blitz document frame.
- Native events round-trip back into JS.

## Non-Goals For MVP

- No hydration.
- No browser DOM compatibility.
- No fine-grained Rust-side DOM patching.
- No perfect controlled-input / caret behavior.
- No framework lock-in beyond the current bet.

## Stable Contract

- JS -> Rust: document payload with `html` and optional `css`.
- Rust -> JS: minimal native events.
- Identity via `data-*` ids on interactive nodes.
- Rust owns the outer frame.
- JS owns app content inside the frame.

### Event Payload

- Required: `{ type, targetId }`.
- Text-like events may also include `value`.
- Boolean form events may also include `checked`.
- Text-like events may also include `selection: { start?, end?, direction? }`.
- Pointer-derived events may also include `pointer: { clientX?, clientY?, isPrimary? }`.
- Keyboard-derived events may also include `keyboard: { key?, code?, altKey?, ctrlKey?, metaKey?, shiftKey? }`.
- JS handlers receive:
  - `event.type`
  - `event.targetId`
  - `event.value` plus `event.currentTarget.value`
  - `event.checked` plus `event.currentTarget.checked`
  - `event.selection`, `event.selectionStart`, `event.selectionEnd`, `event.selectionDirection`
  - `event.pointer`, `event.clientX`, `event.clientY`, `event.isPrimary`
  - `event.keyboard`, `event.key`, `event.code`, `event.altKey`, `event.ctrlKey`, `event.metaKey`, `event.shiftKey`
  - `event.target` / `event.currentTarget`
- Current transport examples:
  - click: `{ "type": "click", "targetId": "counter" }`
  - input: `{ "type": "input", "targetId": "draft", "value": "hello" }`
  - checkbox change: `{ "type": "change", "targetId": "alerts", "checked": true }`
  - text selection: `{ "type": "input", "targetId": "draft", "selection": { "start": 6, "end": 11, "direction": "forward" } }`
  - future pointer click: `{ "type": "click", "targetId": "counter", "pointer": { "clientX": 120.0, "clientY": 280.0, "isPrimary": true } }`
  - keydown: `{ "type": "keydown", "targetId": "draft", "keyboard": { "key": "G", "code": "KeyG", "shiftKey": true } }`

## MVP Ladder

- [x] Host-only TSX compile smoke.
  `just runtime-app-compile-smoke` runs Deno + Babel + Solid universal mode and caches compiled JS under `build/runtime/app-compile-smoke/`.
- [x] `deno_core` load compiled module.
  `just runtime-app-document-smoke` bundles the compiled app plus the Solid-style renderer shim into one local JS file, runs it through `nix run .#deno-core-smoke`, and returns the first `{ html, css }` payload on host.
- [x] Rust `BlitzRuntimeDocument`.
  `just runtime-app-blitz-document-smoke` proves a fixed-frame Blitz document can swap the `<style>` and app root inner HTML from a runtime payload.
- [x] Host visible proof.
  `just runtime-app-host-run` now prepares the bundled app plus the `deno-core-smoke` helper automatically, then launches a runtime-mode Blitz window backed by the real JS session instead of a Rust sample payload. `just runtime-app-host-smoke` exercises the same path with an auto-click plus auto-exit timer.
- [x] Click round-trip.
  `just runtime-app-click-smoke` keeps the app alive inside one `deno_core` session, dispatches a host click event to `data-shadow-id="counter"`, and verifies the rerendered HTML updates from `Count 1` to `Count 2`.
- [x] Basic form / input path.
  `just runtime-app-input-smoke` keeps a second app alive inside one `deno_core` session, dispatches a host `change` event with a string `value`, and verifies both the `<input value=...>` attribute and preview text rerender.
- [x] Focus / text host smoke.
  `just runtime-app-focus-smoke` now keeps a third app alive inside one runtime session, dispatches `focus -> input -> blur`, and verifies the session contract carries enough state for the next text-entry seam without claiming caret support.
- [x] Boolean form / checkbox path.
  `just runtime-app-toggle-smoke` now keeps a checkbox app alive inside one runtime session, dispatches `change` with `checked: true/false`, and verifies the boolean control state plus handler payload rerender on both backends.
- [x] Selection metadata host smoke.
  `just runtime-app-selection-smoke` now keeps a text input app alive inside one runtime session, dispatches `input` with `selection.start/end/direction`, and verifies the JS handler sees both range selections and collapsed carets on both backends.
- [x] Host helper backend swap.
  The same bundled app/session contract now also runs on `deno_runtime`: `just runtime-app-document-smoke-deno-runtime`, `just runtime-app-click-smoke-deno-runtime`, `just runtime-app-input-smoke-deno-runtime`, and `just runtime-app-host-smoke-deno-runtime` all pass without changing the Blitz-side protocol.
- [x] Host backend parity smoke.
  `just runtime-app-backend-parity-smoke` now runs the document, click, input, focus, toggle, and selection smokes on both `deno_core` and `deno_runtime` so backend drift is easier to catch.
- [x] Host OS API seam.
  `just runtime-app-nostr-smoke` proves a runtime app can call a tiny OS-owned API module (`@shadow/app-runtime-os`) for `listKind1` / `publishKind1` without embedding Nostr logic in the app bundle. The app-facing API stays stable while the default helper backend now hosts the mock service below JS; the alternate backend keeps a temporary fallback until we decide it is worth deeper promotion.
- [x] Default-backend Nostr cache seam.
  `just runtime-app-nostr-cache-smoke` now gives the default `deno_core` helper a sqlite-backed mock Nostr store, proves a published note survives a fresh helper process, and verifies author-filtered feed queries without changing the app-facing OS API.
- [x] English keyboard host smoke.
  `just runtime-app-keyboard-smoke` now proves the current runtime contract can carry focus, keydown metadata, plain text input, and selection updates for an English text field without claiming IME support.
- [x] Runtime timeline + keyboard compose smoke.
  `just runtime-app-nostr-timeline-smoke` now drives a timeline-style app through one runtime session: it syncs relay-backed notes via the OS-owned Nostr API, focuses the compose field, enters English text, and posts with `Enter`.
- [x] Rooted Pixel proof.
  `just pixel-runtime-app-drm` stages the bundled app JS plus the GNU-wrapped `deno-core-smoke` helper, pushes them to the rooted phone, and proves the runtime-mode Blitz demo reaches the real panel through the existing guest compositor DRM path. `just pixel-runtime-app-click-drm` proves the same device path survives one auto-dispatched runtime click.
- [x] Rooted Pixel timeline / Nostr app proof.
  The rooted Pixel lane now renders both the tap-driven GM app and the full-screen timeline app through the same runtime/document contract. The GM flow is interactive and publish-capable on device; the timeline app proves the feed-style layout and real runtime bundle survive the real panel path.
- [x] Re-evaluate full snapshots.
  Keep them for MVP. Host and rooted-Pixel click rerenders are good enough for the current card-sized app flows, so there is no reason to add a Rust-side patch bridge yet.

## Touch MVP Checklist

- [x] Rooted Pixel raw touch seam.
  `just pixel-touch-input-smoke` auto-detects the direct-touch evdev node, records its `getevent -pl` descriptor under `build/pixel/touch/`, and captures one raw touch sequence. Default mode injects one rooted `sendevent` tap so the seam is self-verifying; set `PIXEL_TOUCH_SMOKE_MODE=manual` and tap the screen yourself to prove the same capture path with a real finger.
- [x] Single-contact pointer backend in `shadow-compositor-guest`.
  The rooted guest compositor now creates a real Smithay seat plus pointer, detects the direct-touch panel, starts a rooted touch-reader helper, and forwards one active contact as pointer motion plus primary button press/release. On the rooted Pixel, `session-output.txt` now shows live `touch-reader-event` and `touch-input` lines during takeover instead of stalling at `touch-ready`.
- [x] Panel-to-client coordinate mapping.
  The compositor now mirrors the same centered/cropped rect that `kms.rs` uses for presentation so panel-space touches land in client-space coordinates. Unit tests still cover the math, and rooted-Pixel session logs now show in-bounds touches producing mapped client coordinates while out-of-bounds / `0,0` contacts are rejected as `touch-outside-content`.
- [x] Manual rooted-Pixel tap on the runtime demo.
  `just pixel-runtime-app-drm-hold` now builds the current compositor/session artifacts, launches the runtime Blitz card on the real panel, keeps takeover active for manual finger taps, and leaves Android stopped until `just pixel-restore-android`. The current device demo is intentionally shape-driven so tap QA is visible even while Blitz text rendering on device is still imperfect. Manual QA on the rooted Pixel now shows repeatable blue -> orange transitions from real finger taps; the remaining work is hitbox cleanup and text-entry UX, not “does touch work at all?”
- [ ] Re-evaluate touch + text-entry UX.
  Once physical taps work, decide whether full snapshots still feel acceptable for text entry, focus changes, and more animated app flows.

## Renderer Spike

- [x] Host GPU renderer spike.
  `just runtime-app-host-smoke renderer=gpu` and `just runtime-app-host-smoke-gpu` now target the same runtime session/document seam with `anyrender_vello` on host. The same runtime app/session contract auto-clicks and rerenders through the GPU renderer without changing the Blitz-side protocol.
- [x] Linux compositor / VM GPU proof.
  `just runtime-app-compositor-smoke-gpu` now proves the GPU variant can run as a Wayland client under the existing Smithay compositor smoke. The success condition is launch -> map -> runtime ready -> auto-click dispatch, not a client-side `exit-requested` marker.
- [x] Rooted-Pixel GPU viability decision.
  Keep the rooted-Pixel runtime lane on CPU for now. Host GPU and Linux compositor GPU both work, which isolates the remaining device blocker to `shadow-compositor-guest`: it still consumes SHM buffers only, so a client-side GPU swap cannot help the Pixel path until the guest compositor grows dmabuf or an equivalent GPU buffer import path.

## Open Questions

- Is a source-plus-config hash enough once imports start affecting compiled output?
- Is one bundled JS file the right embedder artifact for the first app host, or do we eventually want a custom module loader again?
- Universal renderer vs SSR string renderer for v0?
- CSS scoping model?
- Input / focus / caret strategy?
- When do we need composition / IME payloads beyond selection state?
- When to expose sqlite / fs / network ops?
- When does the device lane need more than `deno_core`, now that the same host contract also works on `deno_runtime`?
- When do full snapshots stop being acceptable for text entry, scrolling, or animation-heavy apps?

## Pivot Signals

- If Solid compile/runtime friction stays high, try a simpler HTML builder plus signals.
- If full snapshots are too slow, move to a JS tree plus incremental Rust patch bridge.
- If the GNU envelope stays fragile, favor an embedded runtime seam over subprocess Deno.
- If Blitz interactivity gaps block progress, use a more traditional browser pipeline temporarily.
