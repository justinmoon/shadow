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
  `just runtime-app-document-smoke` bundles the compiled app with a tiny renderer shim, runs it through `nix run .#deno-core-smoke`, and returns the first `{ html, css }` payload on host.
- [x] Rust `BlitzRuntimeDocument`.
  `just runtime-app-blitz-document-smoke` proves a fixed-frame Blitz document can swap the `<style>` and app root inner HTML from a runtime payload.
- [ ] Host visible proof.
  Launch one sample app. First frame on desktop host.
- [ ] Click round-trip.
  Native click -> JS handler -> rerender.
- [ ] Basic form / input path.
  Prefer uncontrolled, or `change` / `submit` first.
- [ ] Rooted Pixel proof.
  Same transport on the real panel.
- [ ] Re-evaluate full snapshots.
  Keep them if fast enough. Add patch lane only if needed.

## Open Questions

- Is a source-plus-config hash enough once imports start affecting compiled output?
- Do we keep file-relative bundle wiring for the first app host, or add a custom module-loader alias before Blitz integration?
- Universal renderer vs SSR string renderer for v0?
- CSS scoping model?
- Input / focus / caret strategy?
- Event payload shape?
- When to expose sqlite / fs / network ops?
- When does the device lane need more than `deno_core`?

## Pivot Signals

- If Solid compile/runtime friction stays high, try a simpler HTML builder plus signals.
- If full snapshots are too slow, move to a JS tree plus incremental Rust patch bridge.
- If the GNU envelope stays fragile, favor an embedded runtime seam over subprocess Deno.
- If Blitz interactivity gaps block progress, use a more traditional browser pipeline temporarily.
