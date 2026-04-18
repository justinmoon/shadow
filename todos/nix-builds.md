# Nix Builds Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Improve Shadow build throughput and stability for roughly `2-7` active worktrees on this Mac.
- Finish the current local linux-builder tuning work and validate it with real concurrent Shadow workloads.
- Move more of the expensive branch-gate work into real Nix derivations/checks so remote builders and cache reuse can help.
- Evaluate a native remote ARM builder as an additive step, with OCI as the current candidate.
- Keep "push past the local 8 vCPU ceiling" as a follow-on investigation, not a blocker for landing the current builder work.

## Approach

- Treat this as two separate problems:
  - local linux-builder sizing / scheduling
  - non-derivation `cargo` work in `ui-check`
- Finish the local builder pass first:
  - host fan-out
  - builder memory
  - builder disk headroom
  - builder activation correctness
- Measure with real Shadow derivations and multiple disposable worktrees before landing.
- After the local builder is stable, shift focus to Nixifying `ui-check` so native remote ARM capacity can actually carry more of the lane.
- Treat OCI as a likely next builder, not a substitute for fixing the check shape.

## Milestones

- [x] Baseline current local-builder behavior with real Shadow workloads.
- [x] Confirm the darwin ARM builder path is using QEMU + HVF and not pure emulation.
- [x] Confirm the current local builder path hard-fails above `8` vCPUs on this stack.
- [x] Tune the local host/builder scheduling split in `~/configs`.
- [x] Validate the final local builder config after the activation-hook fix lands cleanly.
- [x] Land the local builder tuning in `~/configs`.
- [x] Convert `ui-check`'s heavy Rust/test work from `nix develop -c cargo ...` into derivation-backed Nix checks.
- [x] Re-benchmark after the Nixified `ui-check` pass.
- [x] Decide whether an OCI ARM builder should be added as a shared native `aarch64-linux` builder.
- [x] Non-blocking: investigate ways to exceed the local `8` vCPU builder ceiling without depending on that work for the current landing.

## Near-Term Steps

- [x] Apply the latest `~/configs/worktrees/linux-builder-scale` fix that moves:
  - qcow migration into `preActivation`
  - builder key ACL into `postActivation`
- [x] Verify the local builder comes up with:
  - `160G` root disk instead of `20G`
  - user-accessible `ssh builder@linux-builder`
- [x] Re-run one short sanity build on the fixed builder to confirm the config actually took.
- [x] Land the local builder tuning branch in `~/configs`.
- [x] Add a first `checks.<system>` surface for the work now run by [scripts/ui_check.sh](/Users/justin/code/shadow/worktrees/nix-builds/scripts/ui_check.sh:1).
- [x] Switch `just ui-check` to call those Nix checks instead of direct `cargo` commands where feasible.
- [x] Inspect `~/configs/worktrees/oci-builder` and decide whether to wire an OCI ARM host into `/etc/nix/machines` after `ui-check` is more Nix-shaped.

## Implementation Notes

- Current `ui-check` on `master` is still host-local execution inside a dev shell, not derivation-backed execution:
  - `nix develop .#ui -c cargo ...` in [scripts/ui_check.sh](/Users/justin/code/shadow/scripts/ui_check.sh:9)
- Current `nix-builds` branch now resolves `just ui-check` through `checks.<system>.uiCheck` and `crane`, with dev-profile test/check commands and empty pass/fail outputs for the test derivations instead of multi-hundred-megabyte archived `target/` trees.
- The local builder tuning is landed in `~/configs` `master` as `bfc475d build: tune local linux builder for shadow workloads`.
- The activation-hook fix landed cleanly after the later switch, but the old `20G` guest had to be powered off once from inside the guest so launchd would recreate a fresh builder on the new config.
- Verified fixed-builder state:
  - `/etc/nix/builder_ed25519` is usable directly from the host user
  - guest root disk is `160G` with about `149G` free immediately after recreation
  - the corrected guest keeps `64 GiB` RAM and `8` vCPUs
- Post-fix build results:
  - forced dirty `shadow-runtime-host` rebuild on the fresh guest: `134.70s`
  - within that run, cargo compile time was about `57.87s`; the rest was cold hydration / copy and result transfer
  - corrected 3-way ARM build contention run:
    - runtime host `204.95s`
    - audio `156.61s`
    - blitz gpu-softbuffer `439.04s`
  - compared with the earlier partial-tuning run:
    - runtime host stayed improved versus the old baseline (`240.09s -> 204.95s`)
    - blitz improved modestly (`474.47s -> 439.04s`)
    - audio regressed versus the older run (`93.08s -> 156.61s`), which suggests cross-build contention is still workload-dependent even after the disk fix
- Resource profile on the corrected builder:
  - peak sampled guest load during the 3-way run reached about `13.01`
  - guest RAM stayed low, around `3.6 GiB` used out of `62 GiB`
  - guest disk use remained low, about `7.1G` used out of `157G`
  - interpretation: disk headroom is fixed; memory is not the limiter; the remaining constraint is CPU/shared build concurrency plus the shape of the workloads
- Shadow already has good derivation-backed Linux build surfaces in [flake.nix](/Users/justin/code/shadow/worktrees/nix-builds/flake.nix:565) and nearby package definitions:
  - `shadow-runtime-host`
  - `shadow-linux-audio-spike`
  - `shadow-blitz-demo-*`
  - `shadow-compositor-guest`
- Current Shadow-side seam:
  - `checks.<system>.uiCheck` is now being added in [flake.nix](/Users/justin/code/shadow/worktrees/nix-builds/flake.nix:641)
  - `just ui-check` now shells straight to `nix build .#checks.${host_system}.uiCheck`
  - measured serial timings on `aarch64-darwin`:
    - first sampled cold end-to-end `just ui-check`: `290.88s` while some component checks were already warm
    - corrected end-to-end run after removing archived test outputs: `313.36s`
    - immediate warm rerun: `0.39s`
  - measured 3-way concurrent `just ui-check` on three disposable worktrees with distinct comment-only UI edits:
    - `1408.18s`
    - `1407.64s`
    - `1407.61s`
    - interpretation: distinct local macOS UI-check snapshots still contend very heavily even after Nixification; the win is deterministic reuse and near-instant reruns on the same logical inputs, not good parallel scaling on one host
- OCI builder worktree status:
  - there is a real `aarch64-linux` NixOS host definition at [flake.nix](/Users/justin/configs/worktrees/oci-builder/flake.nix:534) and [configuration.nix](/Users/justin/configs/worktrees/oci-builder/hosts/oci-builder/configuration.nix:1)
  - the `oci-builder` worktree also wires `oci-builder.taild659a1.ts.net` into the Mac build-machine list in [linux-builder.nix](/Users/justin/configs/worktrees/oci-builder/hosts/mac/linux-builder.nix:60)
  - recommendation: worth pursuing for shared `aarch64-linux` derivations and Linux package builds, but it will not accelerate the local `aarch64-darwin` `ui-check` lane directly because that lane still runs host-system checks
  - that makes OCI additive, not a prerequisite for landing this Shadow-side pass
- Local `8` vCPU ceiling follow-on:
  - the current nix-darwin/QEMU/HVF builder path is hard-capped at `8` vCPUs on this machine
  - exceeding that ceiling is not a small config tweak; it means either multiple local builder VMs, a different local hypervisor/builder path, or more remote native ARM capacity
