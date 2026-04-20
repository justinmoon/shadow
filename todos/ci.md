# CI Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Make `just pre-merge` and `just land` faster without weakening determinism.
- Keep Shadow on the current local, boring, Nix-first path first.
- Push as much of the branch gate as possible into Nix's notion of a build result.
- Keep branch-gate policy, nightly policy, and device or boot-lab validation clearly separate.
- Only absorb adjacent boot-lab work into Shadow CI if it becomes durable Shadow-owned policy.

## Approach

- Prefer derivation-backed checks over git-diff selectors.
- Treat the current split as the new baseline: `pre-commit` is universal hygiene, `pre-merge` is the required local branch gate, and `nightly` is the slow superset lane.
- For pure lanes, make success itself a derivation output in the flake: keep required-gate lanes under `checks.<system>.*`, and keep nightly-only private lanes under `legacyPackages.<system>.ci.*` so the explicit `pre-merge` attr contract stays narrow.
- For impure lanes, keep the prepared inputs in Nix and keep only the final attestation outside Nix, keyed by the prepared-input store path.
- Reuse the existing decomposed UI derivations, but narrow their source scope so unrelated edits do not invalidate them.
- Treat selectors as a last resort for irreducibly impure host or device lanes, not as the main branch-gate mechanism.
- Revisit remote Linux fanout only after the derivation-first local pass is complete.

## Milestones

- [x] Slim `pre-commit` down to cheap universal hygiene checks.
- [x] Move `ui-check`, the hermetic private Pixel boot/tooling checks, and the real Pixel boot artifact cross-builds out of the required branch gate and into `just nightly`.
- [x] Keep VM smoke local and reuse green results by logical input identity.
- [~] Keep `uiCheck` decomposed in Nix, expose smaller public suites, and then narrow sources where that remains truthful and green.
- [x] Convert the current runtime cargo and Deno checks in `pre-merge` into real derivation-backed checks.
- [~] Convert any remaining hermetic boot or tooling smokes that can honestly be pure into derivation-backed checks.
- [x] Narrow VM smoke logical inputs so unrelated changes do not invalidate its prepared-input derivation.
- [x] Decide which current boot and tooling smokes remain required in `pre-merge` and which belong in `nightly`.
- [~] Re-measure the branch gate after the derivation-first pass before deciding whether Jericho-style remote fanout or any selector is still worth doing.

## Near-Term Steps

- [x] Add `checks.<system>` entries for the work currently run here imperatively:
- `cargo test -p shadow-sdk --features nostr`
- `cargo test -p shadow-system`
- `deno test scripts/runtime/runtime_prepare_app_bundle_test.ts`
- [x] Make `scripts/pre_merge.sh` consume those checks through `nix build` instead of `nix develop -c ...`.
- [x] Replace the broad `nix flake check --no-build` step with an explicit current-host `checks.<system>.preMergeSurfaceCheck` for the public devShells plus the VM/runtime attrs `pre-merge` actually depends on, and aggregate that with `runtimeCheck` as `checks.<system>.preMergeCheck`.
- [x] Split `scripts/ui_check.sh` into named suites backed by existing check attrs.
- [~] Add narrower `src` definitions for the current UI sub-suites so unrelated app or crate edits do not invalidate every UI derivation. A first truthful pass is green for `core`, `blitz-demo`, and `compositor`; `fmt` and `apps` still use the broader workspace source.
- [~] Audit the current boot and tooling smokes one by one:
- if the smoke is hermetic and only depends on declared files, move it into a check derivation
- if it depends on live host state, keep it out of Nix and make that impurity explicit
- [x] Keep `required_vm_smoke.sh` on the current model: pure prepared-input derivation plus external success attestation.
- [x] Keep `just nightly` as the home for full `ui-check`, derivation-backed `legacyPackages.<system>.ci.pixelBootCheck`, real `hello-init` and `orange-init` cross-builds, and any future slow boot-demo validation that is still Shadow-owned.
- [ ] If hosted automation matters later, mirror `just pre-merge` and `just nightly` as separate CI jobs instead of inventing a second policy surface.
- [ ] Only reconsider a small selector after the derivation-first pass, and only for impure host or device checks that cannot be modeled honestly in Nix.

## Implementation Notes

- Current state after this seam: `scripts/pre_commit.sh` now stops after repo hygiene plus operator, docs, and justfile checks; `scripts/pre_merge.sh` owns host-system `checks.<system>.preMergeCheck` plus the required VM smoke; `scripts/nightly.sh` is now `pre-merge` plus `just ui-check`, host-system `legacyPackages.<system>.ci.pixelBootCheck`, and the real `hello-init` and `orange-init` cross-builds.
- Current landed seam in this worktree:
- `scripts/pre_merge.sh` now builds `checks.<system>.preMergeCheck` instead of pairing `nix flake check --no-build` with a separate `runtimeCheck` build.
- `checks.<system>.preMergeSurfaceCheck` is a cheap derivation-backed manifest of the current-host public devShells plus `packages.<system>.ui-vm-ci`, `packages.<system>.vm-smoke-inputs`, and the host-selected VM `shadow-system-*` package. It forces that branch-gate attr surface to instantiate without widening `pre-merge` to every package, check, or dev shell in the flake.
- `checks.<system>.preMergeCheck` aggregates `preMergeSurfaceCheck` with `runtimeCheck`.
- `checks.<system>.runtimeCheck` aggregates `runtimeShadowSdkNostrTests`, `runtimeShadowSystemTests`, and `runtimePrepareAppBundleTests`.
- The boot-only `rust/init-wrapper` compile seam is intentionally no longer part of `pre-merge`; nightly owns it through `legacyPackages.<system>.ci.pixelBootChecks.pixelBootInitWrapperCheck`.
- `scripts/pre_commit.sh` now overlaps `app_metadata_manifest_smoke.sh` and `operator_cli_smoke.sh` in the background while the remaining cheap hygiene checks run in the foreground. Those two smokes are read-only and temp-file-scoped, so the overlap cuts wall-clock time without weakening coverage.
- `scripts/nightly.sh` now builds `legacyPackages.<system>.ci.pixelBootCheck` instead of keeping the current hermetic Pixel boot/tooling smoke set in the required branch gate.
- `legacyPackages.<system>.ci.pixelBootChecks.pixelBootCheck` aggregates `pixelBootInitWrapperCheck`, `pixelBootHelloInitSmoke`, `pixelBootOrangeInitSmoke`, `pixelBootToolingSmoke`, `pixelBootRecoverTracesSmoke`, `pixelBootCollectLogsSmoke`, and `pixelBootSafetySmoke`.
- Policy seam: keep the private boot-lab surface derivation-backed, but keep it outside flake `checks` and run it only from `just nightly` so the explicit `pre-merge` attr contract does not widen back out.
- The new Pixel boot/tooling check set now uses per-smoke filtered source snapshots, with only the shared shell or bootimg helpers carried across smokes and adjacent files like `flake.nix` or `rust/drm-rect` included only where those smokes actually read or assert on them.
- `scripts/ui_check.sh` and `just ui-check [suite...]` now expose `fmt`, `core`, `apps`, `blitz-demo`, and `compositor` suites while keeping the aggregate default.
- `flake.nix` now groups the UI derivations into family-scoped check builders so `uiCheckCore`, `uiCheckBlitzDemo`, and `uiCheckCompositor` can build against narrower truthful source snapshots with workspace-member patching applied consistently through vendoring, deps, and leaf checks.
- `uiCheckFmt` and `uiCheckApps` still intentionally use the broader UI workspace source. The next gain is to narrow those remaining broad families without lying to Cargo about workspace shape.
- The abandoned `ci` branch selector was solving the problem at the wrong layer. It encoded path-to-lane dependency knowledge outside Nix instead of letting derivation inputs define invalidation.
- A good Nix-first rule: if a passing result should be trusted across machines of the same target system, make it a derivation. If it should only be trusted as a statement about this host, this device, or this moment, keep only the prepared inputs in Nix and treat the final pass as an external attestation.
- `scripts/ci/required_vm_smoke.sh` already reuses a passing result when the logical inputs match clean root `master` or a cached success record.
- `vm-smoke-inputs` now keys its prepared source root off the current-worktree VM smoke controllers plus the host runtime artifact builder inputs; the prebuilt `ui-vm-ci` runner path is carried separately in metadata instead of forcing the prepared source root to rebuild that runner.
- `scripts/vm/ui_vm_run.sh` now materializes a local runner wrapper from the prepared `ui-vm-ci` package, rewrites the guest SSH hostfwd port at runtime, and keeps the logical-input key path-independent so clean worktrees can still compare against root `master`.
- `scripts/vm/ui_vm_stop.sh` no longer rebuilds `.#ui-vm-ci`; when the runner link is missing it now falls back to the VM QMP socket and only then to repo-root-scoped process termination.
- Measurement note from this worktree after the explicit `preMergeCheck` seam:
  hot `checks.<system>.preMergeSurfaceCheck` builds are now about 0.1s once the flake eval cache is warm, and a hot outer `just pre-merge` run with a reused VM-smoke success record landed around 4-5s instead of the previous ~15-16s floor.
  Cold first-run flake evaluation or shell bootstrap can still spike higher, but the steady-state branch gate is now mostly the parallelized `pre-commit` lane plus the lightweight VM-smoke reuse path instead of a broad `nix flake check --no-build`.
- `../boot/scripts/ci/pixel_boot_demo_check.sh` is a useful reference for a path-gated boot-owned lane, but it should stay outside Shadow's main CI plan for now.
- Reason: it is tied to the temporary boot-labs owned-userspace effort, and Shadow already has a clear home for slow boot cross-builds in `just nightly`.
- If `../boot` is folded back here before it sunsets, import that lane into Shadow as a nightly or path-gated adjunct first, not as unconditional `pre-merge`.
- Jericho follow-up remains a second pass. Only revisit it after the derivation-first local pass lands and the remaining expensive lanes are clearly Linux-clean and parallelizable.
