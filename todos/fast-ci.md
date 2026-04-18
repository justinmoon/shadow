# Fast CI Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Speed up `just pre-merge` and `just land` without weakening the required local branch gate.
- Prefer reuse when the logical inputs to a lane have not changed.
- Keep the supported operator surface intact:
  - `just pre-commit`
  - `just smoke target=vm`
  - `just pre-merge`
  - `just land`
- Borrow the useful parts of Pika's CI design:
  - lane-specific source snapshots
  - Nix-prepared outputs
  - path-filtered lane selection
  - prepared-output reuse
- Do not start by porting the full forge / Jericho stack unless local design work proves the simpler path insufficient.

## Approach

- Treat current `pre-merge` as two different concerns:
  - fast static / unit checks
  - expensive VM lifecycle validation
- Move expensive lane inputs toward first-class Nix outputs instead of rebuilding them inside imperative shell scripts.
- Define cacheability in terms of logical lane inputs, not branch names or worktree paths.
- Split "build / prepare" from "final impure smoke" so only the smallest necessary step reruns on unchanged artifacts.
- Add lane selection filters so unrelated changes do not schedule the VM lane.
- Keep `land` conservative:
  - rerun when the post-rebase lane inputs changed
  - skip rerun when the realized lane inputs and gate version are identical
- Keep Jericho as a follow-on option for prepared-output orchestration or remote execution, not a prerequisite for the first speedup.

## Milestones

- [x] Baseline the current gate and identify the dominant cost.
- [x] Compare Shadow's current design with Pika's staged Nix / crane pattern.
- [x] Define a minimal Shadow CI lane model with explicit logical inputs.
- [x] Add Nix outputs for the VM lane's prepared artifacts.
- [x] Refactor `just smoke target=vm` to consume prepared outputs instead of preparing them inline.
- [x] Add path filters so the VM lane only runs when relevant inputs changed.
- [x] Teach `just land` to reuse a green result when the rebased lane inputs are unchanged.
- [ ] Add a broader `just nightly` lane so the full local/host/device suite is explicit without bloating `pre-merge`.
- [ ] Decide whether a Jericho-style prepared-output handoff layer is still necessary after the simpler Nix-first pass.

## Near-Term Steps

- [x] Record current observations from the repo:
  - `just pre-commit` is roughly 17s on the current machine.
  - `just smoke target=vm` is roughly 192s and dominates `pre-merge`.
  - the current VM smoke recreates fresh VM images and a clean state image each run.
- [x] Confirm the recent `~/configs` Linux-builder change did not reduce capacity.
- [x] Inspect Pika's `crane`-backed `workspaceDeps` / `workspaceBuild` pattern and lane filters.
- [x] Inventory the real logical inputs for `just smoke target=vm`.
  - UI Rust build products
  - runtime host binaries
  - runtime app bundles / podcast assets
  - VM runner / microVM config
  - smoke script version and app sequence
- [x] Sketch target outputs in `flake.nix`, implemented as:
  - `packages.<system>.vm-smoke-inputs`
  - `legacyPackages.<system>.ci.vmRuntimeHost`
  - `legacyPackages.<system>.ci.vmUiRunner`
  - `legacyPackages.<system>.ci.vmSmokeInputs`
- [x] Decide that the final VM smoke should remain a small imperative validator keyed by a prepared-input store path.
- [x] Add a local result record keyed by realized lane input path plus smoke definition version.
- [x] Update the `just land` path by making `pre-merge` reuse the recorded VM result after rebase when the logical inputs are unchanged.

## Implementation Notes

- Current `pre-merge` is just `just pre-commit` plus `just smoke target=vm`.
- The dominant cost is not `ui-check`; it is the VM smoke lifecycle.
- `just land` serializes on root `master`, so duplicate reruns matter even if the per-run wall time is acceptable.
- The current VM smoke deletes the state image before each run and `ui_vm_run.sh` drops the writable store overlay before boot; this keeps the gate honest but defeats reuse of prepared state.
- Shadow already has some good Nix ingredients:
  - `crane` is already present in `flake.nix`
  - narrowed source snapshots already exist for UI and runtime packages
  - the VM runner is already a named package (`.#ui-vm-ci`)
- The missing piece is a Nix-shaped CI lane contract for the VM gate, not basic package build support.
- Pika's most relevant ideas are:
  - lane-specific `fileset` snapshots
  - `buildDepsOnly` + staged build outputs
  - path-filtered lane selection
  - consumers using realized prepared outputs instead of recompiling
- Path filtering helps avoid running a lane at all, but it is not enough by itself. Shadow also needs prepared-output reuse once a lane is selected.
- First implementation pass should stay local and boring. Avoid coupling the speedup project to forge scheduling, remote executors, or a broad CI platform rewrite.
- Implemented first pass:
  - `vm-smoke-inputs` is a Nix derivation keyed by a filtered VM-lane source snapshot plus the runtime-host and VM-runner dependencies.
  - `just smoke target=vm` now resolves that prepared input path first and uses it for the runtime-host binary and source snapshot flake ref.
  - the final smoke stays imperative because the VM boot, app open/home sequence, and screenshot are intentionally outside the store.
  - passing results are recorded under the shared git common dir at `.git/shadow-ci/vm-smoke-success`, so every worktree can reuse them.
  - the branch-gate wrapper first compares the current logical input path to root `master` when available, then falls back to the shared success cache, and only boots the VM when neither reuse path applies.
  - the VM runner still has to be built per worktree port, so the prepared input path supplies the immutable flake snapshot while `ui_vm_run.sh` rebuilds `ui-vm-ci` from that snapshot with the current SSH port.
