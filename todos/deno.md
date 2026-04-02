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
8. Later: add `deno_runtime` only after the lower seams are stable.
9. Later: feed Blitz documents from the runtime seam.

## Open Questions

- Can we rely on upstream `rusty_v8` archives for the first seams?
- When do we switch from the first GNU envelope to a more self-contained payload?
- Which minimum runtime features does Blitz actually need first?
