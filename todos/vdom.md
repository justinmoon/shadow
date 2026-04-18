Living plan. Revise it as we learn. Do not treat this as a fixed contract.

# Incremental Virtual DOM Updates for Shadow Runtime

## Scope

Replace Shadow's full-HTML-reserialize-reparse-relayout cycle with incremental
DOM mutations, using the same Blitz `DocumentMutator` APIs that Dioxus native-dom
already uses. Keep the existing full-HTML path as the initial-render and fallback
mechanism.

Once incremental mutations are proven, move Blitz into the compositor process so
that all TS/Solid apps share one Vello renderer and one wgpu device, eliminating
per-app GPU contexts and Wayland surface buffer copies entirely.

## Approach

Solid already knows exactly which nodes changed via fine-grained reactivity. Today
that knowledge is discarded: `serializeNode()` walks the entire virtual DOM to
produce an HTML string, Blitz reparses it from scratch via `set_inner_html`. The
fix is to capture Solid's mutations as they happen on the JS side, send them as a
compact mutation list over the existing stdin/stdout JSON protocol, and apply them
directly to the existing Blitz DOM tree using `DocumentMutator` methods that
already exist in the crate Shadow depends on.

### Current hot path (the problem)

```
touch event
  -> compositor -> shadow-blitz-demo -> JSON stdin -> Deno
  -> Solid re-renders -> serializeNode (FULL HTML string)
  -> JSON stdout -> Blitz parses HTML -> full CSS resolve
  -> full Taffy layout -> full Vello repaint
```

A single text change reprocesses the entire document. Estimated ~30-50ms for a
200-item timeline vs the 16ms frame budget at 60fps.

### Target hot path (phase 1: incremental mutations, Blitz still in shadow-blitz-demo)

```
touch event
  -> compositor -> shadow-blitz-demo -> JSON stdin -> Deno
  -> Solid re-renders -> drain pending mutations (small JSON array)
  -> JSON stdout -> MutationApplier looks up Blitz node IDs
  -> DocumentMutator.set_node_text / append_children / etc
  -> mark dirty subtree -> incremental relayout -> repaint dirty region
```

### Target hot path (phase 2: Blitz moved into compositor)

```
touch event
  -> compositor routes input -> JSON over pipe/socket -> Deno
  -> Solid re-renders -> drain pending mutations (small JSON array)
  -> JSON over pipe/socket -> compositor's MutationApplier
  -> DocumentMutator calls on this app's Blitz DOM
  -> mark dirty subtree -> incremental relayout
  -> Vello repaints in same render pass as shell (no Wayland surface, no buffer copy)
```

Phase 2 eliminates the shadow-blitz-demo middle process entirely. Each app's
Blitz DOM lives in the compositor. Deno processes remain crash-isolated — if an
app's JS crashes, the compositor drops that app's DOM and shows an error state.
Blitz itself is a deterministic layout engine (no I/O, no user code, bounded
memory) so the crash risk of hosting it in the compositor is low.

Benefits of phase 2:
- One wgpu device and one Vello renderer for all apps + shell (critical on Pixel
  where GPU memory is constrained)
- No Wayland surface per app — no SHM fallback, no dmabuf negotiation, solves
  the Pixel dmabuf issue (`shadow-compositor-guest/src/main.rs:1719`)
- App switching / shelving animations are compositor scene operations, not
  "capture surface as texture then animate"
- Screenshots and smoke tests trivially capture compositor output

The mutation protocol from phase 1 becomes the clean IPC boundary for phase 2.
The MutationApplier doesn't care which process it lives in — moving it from
shadow-blitz-demo to the compositor is a relocation, not a rewrite.

## Current Reality Check

The pure-GPU Pixel latency probe in
`build/pixel/touch/20260418T214921Z` says phase 1 is probably not the first
scroll fix:

- `touch_latency.routes.app-scroll.input_to_present` p50 was `205.264ms`, p95
  was `222.971ms`.
- `touch_latency.dispatch_to_flush` p50 was `0.055ms`.
- During the swipe window, the runtime saw only touch-down refresh dispatches
  (`runtime-dispatch-start ... type=click target=refresh`). The `app-scroll`
  move path itself was compositor dispatch plus present, not repeated runtime
  DOM updates.

Implication:

- Phase 1 incremental mutations still make sense for TS app update latency and
  general correctness.
- For the current slow-scroll problem, phase 2 is more likely to matter:
  eliminate the per-app process/surface/render-present path before spending a
  lot of time polishing full-HTML replacement on the move path.
- Shell-lane measurements after compositor fast-path work reinforce that:
  `build/pixel/touch/shell-post-cut-runonly2` still spent about `204ms` in app
  render and `102ms` in dmabuf CPU capture on a panel-sized surface, while shell
  app compositing was only about `4ms` p50. Shrinking the shell viewport to the
  logical app size (`build/pixel/touch/shell-small-surface`) dropped those to
  about `81ms` render and `27ms` capture. The biggest remaining tax is still
  "one app process renders a surface, then the compositor captures and
  composites it", which is exactly what phase 2 removes.
- Even after lowering Pixel antialiasing to `Area`
  (`build/pixel/touch/shell-area-aa`), the supported shell lane still lands
  around `53ms` app render + `26ms` dmabuf capture + `17ms` shell composite on
  scroll frames. That is materially better, but still not a path to smooth
  60fps scroll without removing the per-app surface hop.
- The strongest evidence is the direct-runtime control case:
  `build/pixel/touch/runtime-area-aa` reached `app-scroll.input_to_present` p50
  `38.336ms` on the same device after the AA cut. That means the app/client path
  itself is no longer catastrophically slow; the supported shell lane remains
  slow because it still pays the extra surface capture/composite step that phase
  2 removes.

### Current process architecture

```
compositor (Smithay + Vello + wgpu)
  └── shadow-blitz-demo (Blitz + Vello + wgpu, per-app)  ← 5 copies of this
        └── Deno (Solid/TSX app logic, per-app)
```

### Phase 2 process architecture

```
compositor (Smithay + Vello + wgpu + Blitz DOM per app)
  ├── Deno for Counter (sends mutations over pipe/socket)
  ├── Deno for Timeline
  ├── Deno for Podcast
  └── ...
```

## Prior Art References

### Blitz DocumentMutator API

Shadow already depends on `blitz-dom` from `DioxusLabs/blitz` at rev `781ae63fdb`
(see `ui/apps/shadow-blitz-demo/Cargo.toml:26`). The mutator returned by
`self.inner.mutate()` in `runtime_document.rs:176` exposes these methods that
Shadow does not use today:

Source: `~/code/oss/dioxus/packages/blitz-dom/src/mutator.rs`
(also at `~/code/blitz/packages/blitz-dom/src/mutator.rs`)

```
create_element(name: QualName, attrs: Vec<Attribute>) -> usize
create_text_node(text: &str) -> usize
create_comment_node() -> usize
deep_clone_node(node_id: usize) -> usize
append_children(parent_id: usize, child_ids: &[usize])
insert_nodes_before(anchor_id: usize, node_ids: &[usize])
insert_nodes_after(anchor_id: usize, node_ids: &[usize])
remove_node(node_id: usize)
remove_and_drop_node(node_id: usize)
replace_node_with(anchor_id: usize, new_ids: &[usize])
set_attribute(node_id: usize, name: QualName, value: &str)
clear_attribute(node_id: usize, name: QualName)
set_node_text(node_id: usize, value: &str)
set_style_property(node_id: usize, name: &str, value: &str)
remove_style_property(node_id: usize, name: &str)
```

Node IDs are `usize` (slab arena indices into `Slab<Node>`).
Node structure: `blitz-dom/src/node/node.rs`.

### Dioxus native-dom MutationWriter

Dioxus solves this exact problem: VirtualDom produces diffs, MutationWriter
translates them into Blitz DocumentMutator calls.

Key files in `~/code/oss/dioxus/`:

- `packages/core/src/mutations.rs` -- `WriteMutations` trait defining all
  VirtualDom mutation operations (create_text_node, create_placeholder,
  load_template, set_node_text, set_attribute, append_children,
  insert_nodes_before, insert_nodes_after, remove_node, replace_node_with,
  push_root, assign_node_id, create_event_listener, remove_event_listener)

- `packages/native-dom/src/mutation_writer.rs` -- `MutationWriter` struct that
  implements `WriteMutations`. Core pattern:
  - `DioxusState` holds `node_id_mapping: HashMap<ElementId, usize>` mapping
    VirtualDom element IDs to Blitz node IDs
  - `DioxusState` holds `stack: Vec<usize>` for Dioxus's stack-machine batching
    protocol (push N nodes, then append_children pops N and appends them all)
  - Each trait method: look up Blitz node ID from mapping, call corresponding
    `DocumentMutator` method
  - Templates cached via `deep_clone_node` for fast repeated creation
  - Special handling for: style attributes (merged to individual style
    properties), `dangerous_inner_html`, `checked` state, event listeners

- `packages/native-dom/src/dioxus_document.rs:61` -- `DioxusDocument` showing
  the initialization flow: create base document structure, create `DioxusState`
  with main element ID, wrap in `MutationWriter`, call `vdom.rebuild(&mut writer)`

### Shadow files to modify

- **JS renderer**: `runtime/app-runtime/shadow_runtime_solid.js`
  - Virtual DOM node creation: ~line 140-159
  - `setProperty` (attribute changes): ~line 206-214
  - `serializeNode` (HTML serialization to eliminate): ~line 670-709
  - `createRuntimeApp` (render/dispatch/renderIfDirty API): ~line 80-117
  - `renderMountToDocument` (builds RuntimeDocumentPayload): ~line 123-132
  - `dispatchRuntimeEvent` (event dispatch to target node): ~line 266-277

- **Protocol**: `rust/shadow-runtime-protocol/src/lib.rs`
  - `RuntimeDocumentPayload`: line 4
  - `SessionRequest` / `SessionResponse` enums: lines 101-116

- **Rust runtime document**: `ui/apps/shadow-blitz-demo/src/runtime_document.rs`
  - `apply_render` (current full-HTML injection): line 162-209
  - `replace_document`: line 144-147
  - `dispatch_runtime_event` (calls replace_document after each dispatch): line 544-578
  - `FrameNodes` (holds root_id, style_id, etc.): line 1207-1238

- **Rust runtime session**: `ui/apps/shadow-blitz-demo/src/runtime_session.rs`
  - `dispatch` / `render_if_dirty` / `render_document`: lines 58-98
  - `send_request` / JSON parse response: lines 155-189

## Milestones

- [ ] **Protocol**: add `DomMutation` enum and `RuntimeMutationPayload` to
  `shadow-runtime-protocol`. Mutation types: `CreateElement`, `CreateText`,
  `SetAttribute`, `RemoveAttribute`, `SetText`, `AppendChild`, `InsertBefore`,
  `RemoveChild`, `ReplaceNode`. Add `SessionResponse::OkMutations` variant.
  Keep existing full-HTML `Ok` path compiling and working.

- [ ] **Rust MutationApplier**: add `MutationApplier` struct to
  `runtime_document.rs` holding `HashMap<u64, usize>` (JS nodeId to Blitz
  nodeId). After initial full-HTML render, build the mapping by walking the Blitz
  DOM tree under `#shadow-blitz-root` and matching structural positions + any
  `data-shadow-id` attributes to JS-assigned node IDs sent alongside the initial
  render. Apply incoming `DomMutation`s by looking up Blitz IDs and calling the
  corresponding `DocumentMutator` methods.

- [ ] **JS mutation recording**: modify `shadow_runtime_solid.js` DOM operations
  (`createElement`, `createTextNode`, `insertBefore`, `removeChild`,
  `setProperty`, `setText`) to push mutation entries to a `pendingMutations`
  array. Each virtual DOM node gets a monotonic `nodeId` at creation.
  `renderIfDirty` drains pending mutations instead of calling `serializeNode`.
  `renderDocument` (first render) still sends full HTML plus a `nodeIdMap`
  associating each `data-shadow-id` and structural position with its JS nodeId.

- [ ] **Wire up end-to-end**: modify `runtime_session.rs` to deserialize
  `OkMutations` responses. In `runtime_document.rs` `dispatch_runtime_event`
  (line 544), call `apply_mutations` when response is `OkMutations`, fall back
  to `replace_document` for full `Ok` responses. Test with Counter app: tap
  increment, verify only a `SetText` mutation is sent, verify counter updates
  on screen.

- [ ] **Fallback and robustness**: add full-HTML fallback when mutation list
  exceeds a size threshold or on navigation-level changes. Add protocol version
  field so old runtime hosts that only speak full-HTML still work. Ensure
  CSS-only changes (class/style attribute mutations) trigger proper Blitz style
  re-resolution on affected subtrees. Verify soft keyboard input still works
  (text input state path in `runtime_document.rs:599-650`).

- [ ] **Validation**: measure per-interaction latency on Counter (baseline full-
  HTML vs incremental). Measure on Timeline with 50+ items. Run `just pre-commit`
  and `just ui-check` green.

- [ ] **Phase 2 — Move Blitz into compositor**: relocate `MutationApplier` and
  per-app Blitz DOM ownership from `shadow-blitz-demo` into the compositor
  (`shadow-compositor` / `shadow-compositor-guest`). Replace the Wayland surface
  per TS app with a compositor-owned Blitz DOM that renders directly into the
  compositor's Vello scene. Deno processes communicate mutations over a
  pipe/socket to the compositor instead of to shadow-blitz-demo. Remove
  shadow-blitz-demo from the TS app launch path. Handle app crashes gracefully:
  if a Deno process dies, drop the app's Blitz DOM and surface an error state
  without affecting other apps or the shell.

  Files to modify:
  - `ui/crates/shadow-compositor/src/launch.rs` — launch Deno directly, not
    shadow-blitz-demo
  - `ui/crates/shadow-compositor-guest/src/launch.rs` — same for guest path
  - Compositor app state — hold a `Blitz DOM + MutationApplier` per app instead
    of a Wayland client surface
  - Compositor render loop — render each app's Blitz DOM as a sub-scene in the
    Vello render pass, positioned in the app viewport
  - `ui/apps/shadow-blitz-demo/` — can be removed or kept only for standalone
    testing/development

## Near-Term Steps

Start with the protocol and a minimal Rust-side `MutationApplier` that handles
just `SetText`. Prove the concept end-to-end with the Counter app before
expanding to the full mutation vocabulary. Phase 2 (moving Blitz into the
compositor) should wait until the mutation protocol is validated end-to-end in
phase 1.

## Implementation Notes

(none yet)
