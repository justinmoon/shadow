# Deno / JS Runtime Plan

Living note. Revise it as we learn. Do not treat this as a fixed contract.

## Ground Rules

- Android is the current bootstrap host, not the target runtime.
- Aim at Linux-style payloads for the phone.
- Do not force `gnu` vs `musl` too early.
- Start below the full Deno CLI.

## Current Ladder

1. Done: package `rusty_v8` under Nix and prove host + GNU cross builds.
2. Done: tiny `rusty_v8` embedder.
   Eval JS, print result, no Deno yet.
3. Done: tiny `deno_core` embedder.
   Eval JS, file-backed ES modules, top-level `await`, host + GNU cross builds.
4. Done: first host/runtime protocol seam.
   Tiny async extension op from JS into Rust and back.
5. Done: first phone execution envelope.
   Rooted Android shell launches a GNU/Linux binary by pushing the loader plus the small glibc closure beside it.
6. Done: run the `deno_core` seam on the real phone.
7. Next: decide whether to stabilize the first GNU envelope or retarget toward a more self-contained payload.
8. Next: split app-model work into `todos/app-runtime.md`; keep this note on runtime substrate.
9. Done: load the first compiled Solid-universal app bundle through host `deno_core` and return a document payload from JS back to Rust.
10. Done: bundle the first app-runtime artifact into one local JS module so `deno_core` can stay file-backed while the build step still pulls Solid runtime code from npm.
11. Done: add a long-lived host session mode to the tiny `deno_core` helper so the visible Blitz host can render and dispatch events without embedding the JS runtime directly into the UI crate.
12. Done: reuse that same helper on the rooted Pixel by staging the bundled app JS beside a GNU-wrapped `deno-core-smoke` closure and pointing the static Blitz client at the wrapper script.
13. Next: decide whether that bundled artifact stays the long-term embedder contract or whether we eventually want a custom module loader again.
14. Later: add `deno_runtime` only after the lower seams are stable and the app-runtime lane justifies it.
15. Later: support the chosen Blitz document bridge from `todos/app-runtime.md`.

## Open Questions

- Can we rely on upstream `rusty_v8` archives for the first seams?
- When do we switch from the first GNU envelope to a more self-contained payload?
- Which minimum host ops does the app-runtime lane actually need first?
- Does the app-runtime lane still justify `deno_runtime`, or is `deno_core` enough longer than expected?
