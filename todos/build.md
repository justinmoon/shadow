Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Simplify the VM build/runtime architecture so CI consumes prebuilt artifacts instead of compiling inside the guest.
- Keep the local macOS `pre-merge` gate.
- Allow the VM CI lane to use the local `linux-builder`.
- Make the CI VM clean enough that build-time and runtime responsibilities are clearly separated.
- Treat "no guest builds" as an invariant, not an optimization:
  no Cargo, no Rust toolchain, no fallback compile path inside any VM lane.
- Avoid creating two unrelated systems. The default goal is one artifact graph and one clean artifact-consumer VM lane; a separate dev execution mode exists only if later evidence justifies it.
- Do not try to collapse `shadow-compositor` and `shadow-compositor-guest` as part of this first build cleanup.

## Approach

- Canonical build surface:
  - Nix-owned stable dependencies and Linux binaries
  - one shared host-side runtime artifact builder for app bundles and fixture assets
  - one manifest/env contract consumed by VM, Pixel, and host smokes
  - one shared smoke surface
- Canonical execution mode:
  - `.#ui-vm-ci`: clean artifact-consumer runner; used by the VM scripts that back `pre-merge` and `land`
- Optional fallback mode:
  - not justified yet. Add `ui-vm-dev` only if a measured iteration problem remains after the artifact lane is boring, and still do not put Cargo/Rust in the guest.
- Keep the DRY boundary explicit:
  - shared flake packages for compositor, app client, runtime host, bundles, fixtures
  - shared VM base module for users, services, shell control, smoke wiring, runtime env shape
  - if a second mode survives, keep its overlay thin:
    - how host-built artifacts are delivered into the guest
    - whether repo source is visible for inspection/debugging
    - never whether the guest can build
- Do not force every runtime bundle into a pure Nix derivation yet.
  The Deno/npm bundler is also the path we likely need for runtime-created apps, so the better seam is an explicit host-side artifact builder with deterministic inputs where CI needs them.
- Prefer staging this in order:
  1. package the missing VM Linux binaries
  2. make the CI VM execute them from store paths
  3. centralize runtime app bundling behind one host-side artifact builder
  4. make VM/Pixel/host prep consume the same manifest contract
  5. only then decide whether any source-mounted dev VM still adds value as an artifact-consumption convenience mode

## Milestones

- [x] Map the current builder topology and target architecture.
  The local `linux-builder` is a local `aarch64-linux` builder on `localhost:31022`; the current VM path on this Mac is `aarch64-linux`.
- [x] Trim the current guest-build tax enough to keep working.
  Warm `just pre-merge` is back down to about 1m30s via guest build-cache reuse, but the architecture is still source-built in guest.
- [x] Decide and document the canonical CI build model.
  `pre-merge` now uses the local `linux-builder` to build Linux VM artifacts; the UI/emulator VM is no longer a builder.
- [x] Package the VM compositor as a Nix Linux artifact.
  `flake.nix` now exports a native Linux `shadow-compositor` package and the VM image executes it directly.
- [x] Package the VM app client as a Nix Linux artifact.
  `flake.nix` now exports `shadow-blitz-demo-host-system-fonts`, matching the current VM shell/app lane behavior.
- [x] Remove guest Cargo from the VM architecture.
  The guest warmup build path is gone, Cargo/Rust are removed from the image, and the session runs packaged store binaries.
- [x] Make runtime app bundling first-class without pretending it is pure Nix.
  Runtime app bundles now flow through `scripts/runtime_build_artifacts.sh`, with VM/host/Pixel prep consuming the same manifest/env output.
- [x] Make CI fixtures reproducible.
  The podcast asset resolver now defaults to the checked-in episode `00` fixture when callers do not request a custom feed, asset directory, or episode set. VM, host podcast smoke, and Pixel CI podcast paths are offline-safe by default while still allowing explicit live-feed overrides.
- [x] Add a clean artifact-consumer VM config.
  The repo mount is gone and the VM now mounts only `.shadow-vm/runtime-artifacts` plus `/nix/store`; bundles/fixtures are deliberately host-prepared, manifest-driven artifacts.
- [x] Repoint `pre-merge` and `land` at the artifact VM lane.
  The branch gate now validates the artifact-driven VM session. It is not fully pure yet because runtime bundles/fixtures still come from host-prepared paths.
- [x] Decide whether a separate dev lane is still justified.
  Not now. Keep one artifact-consumer VM lane and one build graph; introduce a dev delivery overlay only after measuring a real iteration-speed problem that cannot be solved by host-side artifact caching.

## Near-Term Steps

- [x] Remove the CI-path builder bans once the artifact spike is ready.
  `pre-merge`, `ui-vm-smoke`, and the VM runner/stop helpers now allow `linux-builder`.
- [x] Spike `shadow-compositor` packaging for `aarch64-linux`.
  `nix build .#packages.aarch64-linux.shadow-compositor --no-link` succeeded from this Mac through the local `linux-builder`.
- [x] Spike the VM-side `shadow-blitz-demo` package for `aarch64-linux`.
  `nix build .#packages.aarch64-linux.shadow-blitz-demo-host-system-fonts --no-link` succeeded through the same path.
- [x] Make the no-toolchain rule enforceable.
  The guest smoke now asserts `cargo` and `rustc` are absent while the compositor is up.
- [x] Thread explicit binary paths into the VM session.
  The VM session now exports `SHADOW_APP_CLIENT` and runs packaged store paths instead of relying on Cargo fallback.
- [x] Cut the repo share out of the VM lane.
  `ui-vm` now mounts `.shadow-vm/runtime-artifacts` instead of the repo, and VM smoke asserts that artifact share path.
- [x] Make the VM podcast sample offline-safe.
  `ui-vm-run` now points podcast prep at a checked-in local fixture for episode `00`, so `just pre-merge` no longer depends on a live RSS/media fetch just to open the podcast app.
- [x] Trim unnecessary podcast fetch volume on the Pixel shell lane.
  Pixel shell/runtime prep now defaults to episode `00` unless an explicit `SHADOW_PODCAST_PLAYER_EPISODE_IDS` override is provided.
- [~] Introduce a VM base module plus mode overlays.
  `.#ui-vm-ci` is now the canonical package name and `.#ui-vm` is a compatibility alias. Do not add a second NixOS mode until there is a proven dev-only delivery seam; if that happens, keep the overlay limited to artifact delivery and source visibility.
- [x] Write down and enforce the runtime artifact contract.
  The builder contract is now `apps/<id>/bundle.js`, optional colocated assets, `artifact-manifest.json`, and optional `runtime-host-session-env.sh`. The VM session validates the manifest before starting the compositor, and `ui-vm-smoke` validates the same manifest from the host side.

## Implementation Notes

- The current architectural smell is real:
  - `vm/shadow-ui-vm.nix` installs Cargo/Rust tooling in the guest, compiles in `shadow-ui-warmup`, and starts the session with `cargo run`.
  - `ui/crates/shadow-compositor/src/launch.rs` also falls back to `cargo run` if it cannot find a sibling binary.
- Current landed state:
  - `just ui-vm-smoke` and `just pre-merge` both pass on the artifact-driven VM path.
  - the canonical VM runner package is now `.#ui-vm-ci`; `.#ui-vm` remains as a compatibility alias for old scripts/operators
  - the guest no longer mounts the repo; it mounts `.shadow-vm/runtime-artifacts` and `/nix/store`
  - the podcast asset resolver now defaults to the checked-in local episode `00` fixture, so VM, host, and Pixel CI podcast paths are offline-safe unless a caller explicitly requests live feed assets
  - runtime bundles are still host-prepared by design, and the Deno/npm bundler seam is now an explicit artifact-builder layer rather than hidden launch glue
  - `scripts/runtime_build_artifacts.sh` is the single public builder wrapper; the older host/Pixel prep scripts are compatibility callers over that manifest contract
  - the VM runtime artifact manifest is now an enforced contract, not just diagnostic output: required apps must have bundle paths under the mounted artifact share
  - VM smoke step markers now show which app transition is under test, and the app-state timeout is 90s to tolerate cold app/runtime starts without hiding hard hangs
  - `SHADOW_UI_VM_SOURCE` / repoShare are gone from the VM definition; the remaining `--impure` use is only for dynamic SSH port selection
- User invariant for this plan:
  - build outside the VM
  - run inside the VM
  - if a workflow needs Cargo in the guest, that workflow is architecturally wrong and should be redesigned
- The current flake already packages adjacent pieces:
  - `shadow-runtime-host`
  - `shadow-compositor-guest`
  - Pixel-oriented `shadow-blitz-demo` Linux variants
  The missing VM artifact seam is mainly `shadow-compositor` plus the VM-side `shadow-blitz-demo` package.
- The VM target on this machine is `aarch64-linux`, not `x86_64-linux`.
  The local `linux-builder` already matches that target, so the VM CI lane should lean on it.
- “Two ways” should mean two artifact-delivery modes at most, not two build graphs and not two compilation models.
- A source mount is acceptable only if it helps the guest consume host-built outputs faster.
  It is not acceptable as a back door for `cargo run`, guest-side warmup builds, or keeping a toolchain in the emulator.
- Current runtime artifact contract:
  - host stages app bundles into `.shadow-vm/runtime-artifacts/apps/<app-id>/bundle.js`
  - host writes `.shadow-vm/runtime-artifacts/runtime-host-session-env.sh`
  - guest mounts that share at `/opt/shadow-runtime`
- Bundle derivation spike changed the target:
  - the runtime app bundler depends on Deno/npm resolution for Babel/Solid packages
  - naive fixed-output `DENO_DIR` packaging self-references or drags in mutable cache behavior
  - this same dynamic app-bundling machinery is useful for runtime-created apps, so the immediate goal is not "all bundles are store derivations"
  - the goal is one explicit host-side builder with a manifest contract, clean inputs, local fixtures for CI, and no guest-side build tools
- Keep one VM mode until evidence says otherwise. A separate `ui-vm-dev` should be an artifact-delivery overlay only, not a second build graph.
- `shadow-compositor` and `shadow-compositor-guest` are different binaries because they use different display backends:
  - `shadow-compositor`: nested Linux compositor with Smithay `backend_winit`
  - `shadow-compositor-guest`: direct guest/hardware compositor without `backend_winit`, with DRM/KMS/input-specific code
  This is concerning only if app/shell/control logic diverges; the current cleanup should keep backend-specific code narrow and shared UI/shell logic centralized.
- The “single nix build” end state is now represented by `.#ui-vm-ci`, backed by multiple derivations underneath for cacheability. It should not become one giant monolithic derivation.
