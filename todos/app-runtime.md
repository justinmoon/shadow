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

1. Host-only TSX compile smoke.
   Run Babel + Solid preset. Cache compiled JS.
2. `deno_core` load compiled module.
   No display yet. Return first document payload.
3. Rust `BlitzRuntimeDocument`.
   Fixed frame. Swap `<style>` and app root via inner HTML.
4. Host visible proof.
   Launch one sample app. First frame on desktop host.
5. Click round-trip.
   Native click -> JS handler -> rerender.
6. Basic form / input path.
   Prefer uncontrolled, or `change` / `submit` first.
7. Rooted Pixel proof.
   Same transport on the real panel.
8. Re-evaluate full snapshots.
   Keep them if fast enough. Add patch lane only if needed.

## Open Questions

- Compile cache key / format?
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
