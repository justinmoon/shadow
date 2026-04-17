# Rust Packaging Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Consolidate standalone Rust crates and repetitive Nix packaging.
- Reduce duplicated lockfiles, dependency policy, build helpers, and per-crate `flake.nix` boilerplate.
- Preserve current VM, Pixel, Android-native, and runtime-host behavior while simplifying how binaries are built.

## Approach

- Inventory first, then consolidate in small batches.
- Prefer one or a few real workspaces over many unrelated crates with independent lockfiles.
- Keep target differences explicit: host runtime helpers, Android-native helpers, Linux GNU bundles, Linux musl guest binaries, and VM artifacts have different constraints.
- Use shared Nix builder functions instead of repeating `buildRustPackage` blocks.

## Milestones

- [ ] Inventory all Rust crates, lockfiles, target triples, and flake package outputs.
- [ ] Decide which crates can move into a shared workspace without breaking Android or cross builds.
- [ ] Consolidate dependency and lint policy for runtime-host sibling crates.
- [ ] Simplify repetitive `flake.nix` Rust package definitions behind reusable functions.
- [ ] Add checks that prove Darwin host, local Linux builder, VM, and Pixel package paths still evaluate.
- [ ] Remove obsolete lockfiles once workspace boundaries are real.

## Near-Term Steps

- [ ] Map `/rust` crates by role: runtime host extensions, Android helpers, device probes, and shared libraries.
- [ ] Start with the runtime-host family because those crates already ship together.
- [ ] Leave Android-native camera packaging alone until the runtime-host workspace is stable.

## Implementation Notes

- This is separate from app metadata. Metadata reduces app drift; Rust packaging reduces build/maintenance duplication.
- Do not force every Rust crate into one workspace if target-specific constraints make that slower or more brittle.
- Use `just pre-commit` for fast safety and `just pre-merge` before landing packaging changes.

