Living plan. Revise it as we learn. Do not treat this as a fixed contract.

# Fix CI

## Intent

Make `pre-merge` and `nightly` fast, cheap, and predictable by moving the main branch gates onto a Linux/KVM executor and treating real Pixel/device work as a separate manual lane.

## Scope

- Move the main CI gates off the current Mac-hosted runner shape.
- Keep host-only Pixel boot/tooling smokes in normal CI where they make sense.
- Keep real plugged-in Pixel execution out of the default branch gate.
- Define clear ownership between `shadow`, `~/configs`, and `pika-build`.
- Do not make this project about buying new ARM hardware.

## Approach

- Treat `x86_64-linux` + KVM as the default CI execution substrate.
- Treat ARM as a build target and hardware-truth lane, not the default executor for every branch gate.
- Keep Nix responsible for immutable build inputs.
- Keep the stateful VM run as an imperative executor step on `pika-build`.
- Keep machine config in `~/configs`; keep Shadow's CI contract and executor client flow in `shadow`.
- Do not add `~/code/pika` as a direct `shadow` input in phase 1. Reuse ideas from Jericho, not a whole-repo dependency.

## Steps

- [x] Project 1: Write down the target CI topology.
  Define the post-change lanes:
  `pre-commit` local,
  `pre-merge` on `pika-build`,
  `nightly` on `pika-build`,
  manual `pixel` lane on a plugged-in rooted Pixel.

- [x] Project 2: Split "host system" from "CI system".
  Stop keying the canonical gate off `builtins.currentSystem` in the branch wrapper. The default CI lane should target `x86_64-linux` even when development happens on `aarch64-darwin`.

- [x] Project 3: Replace the Darwin-only VM runner seam.
  The current `required_vm_smoke` path is blocked by `packages.${hostSystem}.ui-vm-ci`.
  Introduce a Linux/KVM VM runner path for `pika-build`.

- [x] Project 4: Define the build/execution handoff.
  Keep using a derivation-backed bundle like `vm-smoke-inputs`, but make the executor consume that bundle remotely on `pika-build` instead of trying to run the smoke inside a derivation.

- [x] Project 5: Retarget `pre-merge`.
  Make `pre-merge` mean:
  x86 Linux `preMergeCheck`,
  Linux/KVM VM smoke,
  optional `pixel_boot_demo_check.sh --if-changed`.

- [x] Project 6: Retarget `nightly`.
  Make `nightly` mean:
  everything in `pre-merge`,
  full `ui-check`,
  host-only `pixelBootCheck`,
  `hello-init-device` and `orange-init` cross-build verification.

- [x] Project 7: Define the manual `pixel` lane.
  Make a first-class manual CI lane that requires a rooted Pixel and runs `just pixel-ci` / `sc -t pixel ci ...`.
  Keep this out of normal `pre-merge`.

- [x] Project 8: Decide ownership of `pika-build` integration.
  Prefer:
  `~/configs` owns the machine, services, secrets, and generic executor prerequisites on `pika-build`.
  `shadow` owns the CI manifest, remote run protocol, and repo-specific executor entrypoints.
  Avoid a direct `pika` input unless a later phase extracts a genuinely small shared executor package.

- [x] Project 9: Add observability for remote CI execution.
  Capture run id, start/stop times, artifact paths, VM boot time, smoke wall time, and executor failures on `pika-build` so CI slowness can be explained later.

- [x] Project 10: Benchmark the new shape.
  Compare old Mac-hosted `pre-merge` / `nightly` against the new `pika-build` path and confirm that the branch gate is no longer bottlenecked on Mac-local VM execution.

## Implementation Notes

- Current `pre-merge` is host-shaped, not CI-shaped: it runs `checks.${host_system}.preMergeCheck`, then `pixel_boot_demo_check.sh --if-changed`, then `required_vm_smoke`.
- Current `nightly` is also host-shaped: it runs `pre-merge`, `ui-check`, `pixelBootCheck`, and two Pixel-targeted cross-build helpers.
- `pixelBootCheck` is host-only despite the name. It does not require a plugged-in Pixel.
- `pixel_boot_demo_check.sh --if-changed` is also host-only; it conditionally runs extra boot-demo-owned host checks when matching paths changed.
- The real plugged-in-device lane is `just pixel-ci` / `sc -t pixel ci ...`; that should become an explicit manual CI lane rather than an implicit part of `pre-merge` or `nightly`.
- The current VM smoke path is Darwin-blocked by `packages.${hostSystem}.ui-vm-ci`. That is the main execution blocker, not ARM.
- `hello-init-device` and `drm-rect-device` are cross-builds to `aarch64-unknown-linux-musl`. They produce ARM device artifacts, but they do not require ARM execution hosts.
- `pika-build` is already the right substrate shape for main CI execution: `x86_64-linux`, KVM available, and already listed as a remote builder in `~/configs`.
- Recommendation on ownership:
  keep `pika-build` host config in `~/configs`,
  keep Shadow CI behavior in `shadow`,
  do not make `shadow` depend on the full `pika` repo in phase 1.
- If a reusable remote executor substrate is worth sharing later, extract a small package or protocol boundary deliberately instead of adding `~/code/pika` as a casual flake input.
- Implementation status:
  `scripts/pre_merge.sh` and `scripts/nightly.sh` now dispatch to canonical Linux gate scripts on `pika-build` when the local host is not the CI system.
  The Linux gate path is `scripts/ci/linux_pre_merge.sh`, `scripts/ci/linux_nightly.sh`, and `scripts/ci/remote_ci.sh`.
- VM runner status:
  `ui-vm-ci` is now available on Linux and Darwin.
  `vm/shadow-ui-vm.nix` now supports Linux/KVM runner mode (`-display none`) instead of being Cocoa-only.
- Gitless remote repo support:
  VM smoke cache logic now works without `.git`, and remote sync scrubs stale `.shadow-vm` / `build` state before each run so Nix path evaluation does not trip over leftover sockets.
- VM smoke fixes found by the migration:
  x86 Linux exposed `shadow-compositor-guest` control-socket/runtime-dir bugs in tests; fixed in `ui/crates/shadow-compositor-guest/{control,main,session}.rs`.
  Remote VM smoke host tooling now comes from the Nix-built `vm-smoke-inputs` bundle instead of ambient PATH assumptions.
  The VM lane now uses a dedicated repo-owned SSH keypair for guest access instead of assuming the executor has Justin's personal key loaded.
  `nak event` needed `</dev/null` under the remote `bash -s` executor to avoid producing empty output from piped stdin semantics.
- Measurements:
  previous Mac-hosted invalidated `preMergeCheck` investigation on `../boot`: `220.64s` just for the local `checks.aarch64-darwin.preMergeCheck` half, before adding VM smoke.
  warm remote `pre-merge` on `pika-build`: `128s` total, `15s` `preMergeCheck`, `113s` VM smoke.
  latest successful VM smoke summary: `91s` total, `3s` bootstrap, `17s` to ready.
  warm public `just pre-merge` from macOS after the migration: `41.50s`.
  warm public `just nightly` from macOS after the migration: `51.65s`.
- Validation status:
  `just pre-commit` passes locally.
  remote `pre-merge` on `pika-build` passes end-to-end.
  remote `nightly` on `pika-build` passes end-to-end.
  public `just pre-merge` and `just nightly` entrypoints both dispatch to the Linux CI executor and pass from macOS.
