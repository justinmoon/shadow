Living plan. Revise it as we learn. Do not treat this as a fixed contract.

# Incremental Runtime Mutations

## Scope

Replace the runtime's full-document HTML payloads with incremental DOM mutations
for TS apps. Keep a full snapshot path for initial render, recovery, and tests.

This is no longer the plan for "move Blitz into the compositor." That already
exists on the rooted-Pixel hosted TS path. If we keep this file, it should only
cover the remaining mutation-protocol work.

## Recommendation

[~] Park this for now.

The core idea is still sound, but it is not the main bottleneck on the current
Pixel path. Recent latency work says the visible cost is dominated by GPU
render/present, not runtime HTML serialization or `set_inner_html`.

Revisit this only when we have a concrete workload where full-document
replacement is measurably hurting update cost, correctness, or battery.

## Current Reality

- JS still serializes the whole tree on every dirty render in
  `runtime/app-runtime/shadow_runtime_solid.js` via `serializeNode()`.
- The runtime protocol still only carries full snapshots in
  `rust/shadow-runtime-protocol/src/lib.rs` through
  `RuntimeDocumentPayload { html, css, text_input }`.
- Rust still applies updates by replacing large HTML regions with
  `set_inner_html()` in `ui/apps/shadow-blitz-demo/src/runtime_document.rs`.
- The rooted-Pixel hosted shell path already runs Blitz in-process through
  `ui/apps/shadow-blitz-demo/src/hosted_runtime.rs`, so the old "phase 2" part
  of this plan is stale.

## Approach

If we revive this work, keep it narrow:

1. Add a mutation protocol with explicit node identity and a small snapshot
   fallback.
2. Capture pending mutations on the JS side instead of rebuilding `html` on
   every dirty render.
3. Apply those mutations in Rust through `DocumentMutator`, shared by the
   standalone and hosted runtime paths.
4. Keep the snapshot path for initial render, protocol desync, and debugging.

## Milestones

- [x] Compositor-hosted Blitz exists for the rooted-Pixel TS shell lane.
- [ ] Define the mutation model and recovery contract.
- [ ] Extend the runtime protocol with snapshot and mutation responses.
- [ ] Capture pending mutations in `shadow_runtime_solid.js`.
- [ ] Add a Rust `MutationApplier` on top of `DocumentMutator`.
- [ ] Benchmark a real workload where this should help.
- [ ] Decide whether to land it broadly or delete this plan.

## Near-Term Steps

- [ ] Do nothing until a real app proves the current full-snapshot path is a
  problem worth solving.
- [ ] If revived, start with measurement: time `serializeNode()`,
  protocol payload size, and `set_inner_html()` / relayout cost on one concrete
  app.
- [ ] Delete this file if it stays dormant and no workload appears.

## Implementation Notes

- This is no longer a scroll-latency project first. Scroll feel on Pixel is
  currently limited by render/present cost, not snapshot transport.
- The likely wins here are smaller update payloads, less document churn, better
  text-input fidelity, and a cleaner app-runtime boundary.
- If we do this, the Rust mutation applier should be shared between hosted and
  standalone runtime paths. Do not build two mutation stacks.
