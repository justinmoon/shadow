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

## Agent Handoff

- Start with inventory and one narrow consolidation target. Do not attempt a repo-wide Rust workspace rewrite in one pass.
- Likely write areas: `flake.nix`, `rust/*`, `ui/Cargo.toml`, `ui/crates/*`, `Cargo.lock` files, and package/check definitions.
- Keep app metadata out of this plan unless packaging work exposes a concrete dependency on it.
- Do not put `cargo`, Rust toolchains, or compile steps back inside the VM. VM and Pixel should consume host-built artifacts.
- The local Linux builder is acceptable for Darwin cross builds. Do not reintroduce `NIX_BUILDERS=""` or `--option builders ""` walls without a specific documented reason.
- Preserve target boundaries: Android-native helpers, GNU runtime hosts, musl guest binaries, VM artifacts, and host tools may need different build environments.
- Avoid deleting lockfiles until the new workspace boundary is proven by checks.
- Validate small steps with `just pre-commit`; validate package-shape changes with flake evaluation and targeted `nix build` package outputs; run `just pre-merge` before landing.

## Milestones

- [ ] Inventory all Rust crates, lockfiles, target triples, and flake package outputs.
- [ ] Decide which crates can move into a shared workspace without breaking Android or cross builds.
- [ ] Consolidate dependency and lint policy for runtime-host sibling crates.
- [ ] Simplify repetitive `flake.nix` Rust package definitions behind reusable functions.
- [ ] Add checks that prove Darwin host, local Linux builder, VM, and Pixel package paths still evaluate.
- [ ] Remove obsolete lockfiles once workspace boundaries are real.

## Near-Term Steps

- [ ] Map `/rust` crates by role: runtime host extensions, Android helpers, device probes, and shared libraries.
- [ ] Map every Rust-related flake output to the crate, target triple, and consumer lane that needs it.
- [ ] Pick one first consolidation target and document why it is low-risk.
- [ ] Start with the runtime-host family because those crates already ship together.
- [ ] Leave Android-native camera packaging alone until the runtime-host workspace is stable.

## Implementation Notes

- This is separate from app metadata. Metadata reduces app drift; Rust packaging reduces build/maintenance duplication.
- Do not force every Rust crate into one workspace if target-specific constraints make that slower or more brittle.
- Cross-compilation constraints are real. Prefer clearer package functions and cache reuse over purity theater.
- If a packaging change makes VM or Pixel iteration slower, treat that as a regression unless the tradeoff is explicit and accepted.
- Use `just pre-commit` for fast safety and `just pre-merge` before landing packaging changes.
