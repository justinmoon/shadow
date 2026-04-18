Living plan. Revise it as we learn. Do not treat this as a fixed contract.

# Landing Gates

## Scope

- Make `just pre-merge` and `just land` cheaper without making them ad hoc.
- Keep landing deterministic and repo-defined.
- Split broad gates into smaller Nix-backed lanes with narrower input scopes.
- Reuse previously green results when the realized lane inputs are unchanged.
- Keep a clear path to broader post-merge or nightly validation outside the branch gate.

## Approach

Use Nix for lane identity, source scoping, and cache reuse.
Do not use Nix to decide which git diff requires which lane.

Keep the selection layer thin and explicit:

- Nix defines lanes and their source snapshots.
- `pre-merge` runs cheap universal checks first.
- a small checked-in selector maps changed paths to lane attrs and scripts
- `land` stays deterministic and conservative

The current problem is mostly lane shape, not missing dependency caching:

- `ui-check` is one monolithic `uiCheck`
- `pre-commit` unconditionally runs work that is not universal hygiene
- VM smoke already has logical-input reuse, but its source scope is still broad

## Milestones

- [ ] Split `uiCheck` into smaller deterministic suites in `flake.nix`.
- [ ] Slim `pre-commit` down to cheap universal checks.
- [ ] Add a checked-in gate selector that maps changed paths to required lanes.
- [ ] Teach `pre-merge` to dispatch only the selected lanes.
- [ ] Narrow VM smoke logical inputs so unrelated shell/script changes do not invalidate it.
- [ ] Add one explicit full gate for manual or nightly use.
- [ ] Decide whether post-merge Codex notifications are worth building after the gate refactor lands.

## Near-Term Steps

- [ ] Define the first lane split:
  - `uiCheckCore`
  - `uiCheckBlitz`
  - `uiCheckGpu`
  - `uiCheckAll`
- [ ] Update `scripts/ui_check.sh` to accept a suite name instead of always building `uiCheck`.
- [ ] Move these out of unconditional `pre-commit`:
  - runtime-host cargo/test checks
  - runtime bundle prep Deno test
  - Pixel boot helper smokes
  - `just ui-check`
- [ ] Keep these unconditional in `pre-commit`:
  - script inventory
  - app metadata generation check
  - app metadata smoke
  - shell syntax
  - operator CLI smoke
  - timeline sync defaults smoke
  - docs / justfile checks
  - `nix flake check --no-build`
- [ ] Add a small selector, likely under `scripts/ci/`, with checked-in path-to-lane rules.
- [ ] Make `scripts/pre_merge.sh` run:
  - slim `pre-commit`
  - selector-driven lanes
  - `required_vm_smoke.sh` only when selected
- [ ] Add a manual `pre-merge-full` or equivalent recipe that still runs the broad gate.

## Implementation Notes

- `scripts/pre_merge.sh` is currently fixed: `just pre-commit` plus `scripts/ci/required_vm_smoke.sh`.
- `scripts/pre_commit.sh` is currently too broad. It mixes universal repo hygiene with runtime, Pixel-tooling, and UI/build-heavy checks.
- `scripts/ui_check.sh` always builds `.#checks.${host_system}.uiCheck`.
- `uiCheck` currently bundles:
  - UI fmt
  - `shadow-ui-core` tests
  - Blitz app tests
  - Blitz runtime-document tests
  - Rust demo check
  - Blitz host-system-fonts check
  - Blitz GPU check
  - compositor checks
- Crane is already in use. The pain is not missing dependency caching; the pain is that the gate currently requests several separate Blitz derivations on every land.
- Nix already gives the desired “instant pass when inputs are unchanged” behavior for derivation-backed lanes, as long as the lane attr and filtered source snapshot stay stable and the output remains available.
- VM smoke already has a custom logical-input reuse path in `scripts/ci/required_vm_smoke.sh`. That should stay, but its logical-input bundle should be narrowed where possible.
- The selector should stay outside Nix. Diff-based lane selection depends on git state; encoding that in flake eval would be more brittle than a small checked-in script.
- The selector should be deterministic, reviewable, and boring. Avoid agent judgment in the landing path.
- Post-merge or nightly failure reporting to Codex is a separate problem. Treat it as follow-up work after the core gate split exists, not as a prerequisite.
