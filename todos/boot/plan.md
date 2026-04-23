# Boot Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

Related docs:

- [frontier.md](./frontier.md)
- [history.md](./history.md)
- [spec-scope.md](./spec-scope.md)
- [spec-phase1-shadow-at-boot.md](./spec-phase1-shadow-at-boot.md)

## Intent

- Boot a Pixel 4a (`sunfish`) into full Shadow userspace from a custom `boot.img`.
- Perfect-world target for this push: wake up to a booted Pixel running the real Shadow experience, not just one more proof artifact.
- Treat boot ownership as "from kernel handoff / PID 1 upward" on unlocked hardware.
- Use the proven Rust Stream A seam as the only critical path.
- Preserve the signed-off GPU proof contract while replacing proof demos with real app, runtime, and shell milestones.

## Scope

- In scope:
  - boot-owned Rust bootstrap (`no_std` PID1 shim -> Rust child)
  - boot-owned GPU render/present, compositor, app, and shell ladders
  - the smallest runtime and launch contract needed to run real Shadow userspace
  - input and selected services only when they unblock the next product rung
- Parked unless they directly unblock Stream A:
  - direct `std` PID1 investigation
  - stock-init trigger / imported-rc / preflight seams
  - rooted takeover extraction and service inventory work
  - new C seam work
- Out of scope for now:
  - shipping the rooted Android takeover lane as architecture
  - broad service bring-up before shell/home/app loop exists
  - camera, Wi-Fi, update, and recovery product work before usable shell

## Current Master Truth

- The C seam is signed off and frozen as reference only.
- The live boot seam on current `master` is:
  - `/system/bin/init` = no_std Rust shim
  - `exec` into `/hello-init-child`
  - raw `argc/argv` parsing in the child
- Direct `std` Rust as PID1 still panics. Keep it as a background regression discriminator, not the main execution plan.
- Signed-off Rust rungs on current `master` are `gpu-render`, `orange-gpu-loop`, `compositor-scene`, and `app-direct-present`.
- See [frontier.md](./frontier.md) for the current proof artifacts and absolute validation paths.
- The truth surface is:
  - `recover-traces/status.json`
  - `probe-report.txt`
  - `probe-summary.json`
  - `probe-fingerprint.txt`
  - `probe-timeout-class.txt` when applicable
- The top-level one-shot wrapper can still end at `fastboot-return-auto-rebooted`. Treat `recover-traces/status.json` as truth.
- The stock-init trigger / imported-rc / preflight seams are no longer peer execution streams:
  - latest negative proof: `/Users/justin/code/shadow/worktrees/rust-boot/build/pixel/runs/boot-kgsl-trigger-ladder/20260423T082243Z-09051JEC202061_/matrix-summary.json`
  - current interpretation: later stock init actions prove, but injected `/init.shadow.rc` action registration still does not prove on normal `sunfish` boots
  - keep that seam parked as fallback evidence, not as the product path

## Strategy

- Keep exactly one critical path: Stream A.
- Advance the smallest rung that moves toward full Shadow userspace.
- Favor real product-path milestones over more generic proof demos once a seam is established.
- Keep the current proof contract and observability intact while climbing.
- Use absolute paths for artifact references in docs.
- Land small, truthful chunks instead of carrying a second parallel roadmap.

## Ladder To Full Shadow Userspace

- Signed off:
  - `gpu-render`
  - `orange-gpu-loop`
  - `compositor-scene`
  - `app-direct-present`
- Next product rungs:
  - `ts-app-minimal`
  - first minimal Shadow runtime / TypeScript app rung on the boot-owned seam
  - `touch-counter-gpu`
  - prove one minimal input-driven redraw on the real boot-owned render/present path
  - `rust-app-minimal`
  - secondary isolation rung; raise priority only if the TS runtime obscures bootstrap bugs
  - `shell-home-static`
  - `shell-launch-ts-app`
  - `shell-launch-rust-app`
  - `shell-interaction`
  - selected service spikes required for a usable shell
    - audio output
    - storage / networking / control seams as needed
  - decide whether direct `std` PID1 still matters for the shipping architecture or stays a parked non-goal

## Immediate Milestones

- Land `app-direct-present` on current `master` truth.
- Pick the first real app lane after `app-direct-present`.
  - prefer `ts-app-minimal` if it is the shortest path to actual Shadow userspace
  - use `rust-app-minimal` first only if it materially de-risks the boot seam
- Land one minimal touch/input rung before starting shell interaction work.
- Keep the direct `std` PID1 seam honest as a regression discriminator while not letting it block the main ladder.

## Next Dispatch Batch

- [x] `finish-inflight-app-direct-present`
  - why first: this is the current in-flight seam and it blocks every downstream product rung
  - result: signed off in `/Users/justin/code/shadow/worktrees/worker-1`
  - proof image:
    - `/Users/justin/code/shadow/worktrees/worker-1/build/pixel/boot/shadow-boot-orange-gpu-rust-bridge-default-app-direct-present-wayland-v4.img.hello-init.json`
  - proof bundles:
    - `/Users/justin/code/shadow/worktrees/worker-1/build/pixel/boot/oneshot/app-direct-present-wayland-v4-primary-11151JEC200472/recover-traces/status.json`
    - `/Users/justin/code/shadow/worktrees/worker-1/build/pixel/boot/oneshot/app-direct-present-wayland-v4-confirm-06241JEC200520/recover-traces/status.json`
  - root cause fixed:
    - the first boot-owned app client path used a shell launcher and then hit `winit` `NoWaylandLib`
    - the landed contract uses a static launcher, explicit mock-camera env for the proof app, staged Wayland runtime libraries, and `LD_LIBRARY_PATH=/orange-gpu/app-direct-present/lib`
  - owned paths:
    - `rust/init-wrapper/src/bin/hello-init.rs`
    - `rust/init-wrapper/src/bin/app-direct-present-launcher.rs`
    - `scripts/lib/pixel_runtime_linux_bundle_common.sh`
    - `scripts/pixel/pixel_boot_build_orange_gpu.sh`
    - `scripts/pixel/pixel_boot_recover_traces.sh`
    - `scripts/ci/pixel_boot_orange_gpu_smoke.sh`
    - `scripts/ci/pixel_boot_recover_traces_smoke.sh`
    - `todos/boot/plan.md`
    - `todos/boot/frontier.md`
  - acceptance:
    - land the current `app-direct-present` seam on `master`, or land a truthful note/doc update saying why the current seam is not the right contract
    - keep the signed-off `recover-traces/status.json` truth model intact
  - validation:
    - `scripts/ci/pixel_boot_orange_gpu_smoke.sh`
    - `scripts/ci/pixel_boot_recover_traces_smoke.sh`
    - canonical rooted proof recipe on the primary/confirm device pair
  - blocked_by: none
- [ ] `ts-app-minimal`
  - why next: default first real app lane unless the runtime itself becomes the blocker
  - owned paths:
    - `runtime/`
    - `rust/shadow-system/`
    - `scripts/pixel/`
    - `todos/boot/`
  - acceptance:
    - a minimal TypeScript-backed Shadow app launches on the boot-owned Rust seam with a truthful recovered proof bundle
  - validation:
    - `scripts/ci/pixel_boot_orange_gpu_smoke.sh`
    - `scripts/ci/pixel_boot_recover_traces_smoke.sh`
    - canonical rooted proof recipe for the app-direct-present successor on the preferred rooted proof pair
  - blocked_by:
    - `finish-inflight-app-direct-present`
- [ ] `touch-counter-gpu`
  - why next: first honest input rung on the real boot-owned render/present path
  - owned paths:
    - `scripts/pixel/`
    - `ui/`
    - `runtime/app-counter/`
    - `todos/boot/`
  - acceptance:
    - one input-driven redraw is proved on the same boot-owned render/present path, not on rooted takeover
  - validation:
    - `scripts/ci/pixel_boot_orange_gpu_smoke.sh`
    - `scripts/ci/pixel_boot_recover_traces_smoke.sh`
    - canonical rooted proof recipe for the first input-driven redraw artifact on the preferred rooted proof pair
  - blocked_by:
    - `ts-app-minimal`
- [ ] `shell-home-static`
  - why after app + input: shell work should sit on top of the first truthful app lane and the first truthful input lane
  - owned paths:
    - `ui/`
    - `rust/shadow-system/`
    - `scripts/pixel/`
    - `todos/boot/`
  - acceptance:
    - a static Shadow home/shell surface appears from the boot-owned seam and preserves the current recovered proof contract
  - validation:
    - `scripts/ci/pixel_boot_orange_gpu_smoke.sh`
    - `scripts/ci/pixel_boot_recover_traces_smoke.sh`
    - canonical rooted proof recipe for the first static shell/home artifact on the preferred rooted proof pair
  - blocked_by:
    - `touch-counter-gpu`

## Parked / Fallback Seams

- [~] Direct `std` PID1 `lang_start` regression lane.
  - use `scripts/shadowctl -t <serial> debug boot-lab-rust-bridge-run --shim-mode exec --child-profile std-probe ...`
- [~] Stock-init trigger / imported-rc / preflight lane.
  - use only if the boot-owned launch contract regresses or `/data` artifact handling needs independent evidence
  - latest high-signal negative result: `/Users/justin/code/shadow/worktrees/rust-boot/build/pixel/runs/boot-kgsl-trigger-ladder/20260423T082243Z-09051JEC202061_/matrix-summary.json`
- [~] C seam.
  - reference only; do not extend it
- [~] Rooted KGSL falsification matrices.
  - use as falsifiers only, not as the execution plan

## Device Policy

- Preferred rooted proof pair when available:
  - `11151JEC200472`
  - `06241JEC200520`
- Treat one phone as the primary hypothesis lane and one as confirmation.
- Use other attached phones only for independent sidecars or recovery.
- Verify current root state before hardware work; do not trust stale notes.

## Implementation Notes

- Canonical builder: `scripts/pixel/pixel_boot_build_orange_gpu.sh --hello-init-mode rust-bridge`
- Canonical proof recipe:
  - `--skip-collect --recover-traces-after --no-wait-boot-completed`
  - read `recover-traces/status.json`
- Keep later compositor, app, shell, and service work on the Rust seam only.
- Delete demo-only wrappers, binaries, and smokes once a product rung fully subsumes them.
