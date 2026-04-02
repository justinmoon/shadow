# App Runtime Plan

Living note. Revise it as we learn. Do not treat this as a fixed contract.

## Goal

- TS / TSX app modules.
- Familiar Solid-like authoring style.
- Native OS APIs from the runtime; no browser dependency.
- Blitz-backed UI path for shell apps.

## Current Bet

- Deno / `deno_core` runtime seam.
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
- [x] Rooted Pixel proof.
  `just pixel-runtime-app-drm` stages the bundled app JS plus the GNU-wrapped `deno-core-smoke` helper, pushes them to the rooted phone, and proves the runtime-mode Blitz demo reaches the real panel through the existing guest compositor DRM path. `just pixel-runtime-app-click-drm` proves the same device path survives one auto-dispatched runtime click.
- [x] Re-evaluate full snapshots.
  Keep them for MVP. Host and rooted-Pixel click rerenders are good enough for the current card-sized app flows, so there is no reason to add a Rust-side patch bridge yet.

## Open Questions

- Is a source-plus-config hash enough once imports start affecting compiled output?
- Is one bundled JS file the right embedder artifact for the first app host, or do we eventually want a custom module loader again?
- Universal renderer vs SSR string renderer for v0?
- CSS scoping model?
- Input / focus / caret strategy?
- Event payload shape?
- Do we keep `change`-plus-string-value as the first transport, or add richer form payloads before Blitz integration?
- When to expose sqlite / fs / network ops?
- When does the device lane need more than `deno_core`?
- When do full snapshots stop being acceptable for text entry, scrolling, or animation-heavy apps?

## Pivot Signals

- If Solid compile/runtime friction stays high, try a simpler HTML builder plus signals.
- If full snapshots are too slow, move to a JS tree plus incremental Rust patch bridge.
- If the GNU envelope stays fragile, favor an embedded runtime seam over subprocess Deno.
- If Blitz interactivity gaps block progress, use a more traditional browser pipeline temporarily.
