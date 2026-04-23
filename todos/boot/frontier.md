# Boot Frontier

Use this file as the shortest truthful snapshot of the current boot-owned seam.

## Active Blocker

- The GPU / KGSL driver-discovery problem is solved enough for the current architecture.
- The active blocker is now product-facing:
  - moving from the proven Rust boot seam into real Shadow userspace
  - keeping the proof contract intact while climbing from compositor proofs into app, runtime, and shell milestones
- The working seam is:
  - no_std Rust PID1 shim at `/system/bin/init`
  - `exec` into the full Rust child at `/hello-init-child`
  - raw `argc/argv` child entry
- Direct `std` Rust as PID1 still panics, but that is now a background discriminator rather than the main blocker.

## Current Master Truth

- The C seam is signed off and frozen as reference.
- Signed-off Rust rungs on current `master`:
  - `gpu-render`
    - `/Users/justin/code/shadow/worktrees/rust-boot/build/pixel/boot/shadow-boot-orange-gpu-rust-bridge-default-gpurender-fw-helper-breadcrumb-v4.img.hello-init.json`
    - `/Users/justin/code/shadow/worktrees/rust-boot/build/pixel/boot/oneshot/20260422T203707Z-11151JEC200472_/recover-traces/status.json`
    - `/Users/justin/code/shadow/worktrees/rust-boot/build/pixel/boot/oneshot/20260422T203906Z-06241JEC200520_/recover-traces/status.json`
  - `orange-gpu-loop`
    - `/Users/justin/code/shadow/worktrees/rust-boot/build/pixel/boot/shadow-boot-orange-gpu-rust-bridge-default-orange-gpu-loop-parentprobe-fw-helper-breadcrumb-v2.img.hello-init.json`
    - `/Users/justin/code/shadow/worktrees/rust-boot/build/pixel/boot/oneshot/orange-gpu-loop-v2-primary-11151JEC200472/recover-traces/status.json`
    - `/Users/justin/code/shadow/worktrees/rust-boot/build/pixel/boot/oneshot/orange-gpu-loop-v2-confirm-06241JEC200520/recover-traces/status.json`
  - `compositor-scene`
    - `/Users/justin/code/shadow/worktrees/rust-boot/build/pixel/boot/shadow-boot-orange-gpu-rust-bridge-default-compositor-scene-parentprobe-fw-helper-breadcrumb-v3.img.hello-init.json`
    - `/Users/justin/code/shadow/worktrees/rust-boot/build/pixel/boot/oneshot/20260422T235214Z-11151JEC200472_/recover-traces/status.json`
    - `/Users/justin/code/shadow/worktrees/rust-boot/build/pixel/boot/oneshot/20260422T235214Z-06241JEC200520_/recover-traces/status.json`
  - `app-direct-present`
    - `/Users/justin/code/shadow/worktrees/worker-1/build/pixel/boot/shadow-boot-orange-gpu-rust-bridge-default-app-direct-present-wayland-v4.img.hello-init.json`
    - `/Users/justin/code/shadow/worktrees/worker-1/build/pixel/boot/oneshot/app-direct-present-wayland-v4-primary-11151JEC200472/recover-traces/status.json`
    - `/Users/justin/code/shadow/worktrees/worker-1/build/pixel/boot/oneshot/app-direct-present-wayland-v4-confirm-06241JEC200520/recover-traces/status.json`
  - `ts-app-minimal`
    - `/Users/justin/code/shadow/worktrees/worker-1/build/pixel/boot/shadow-boot-orange-gpu-rust-bridge-default-ts-counter-app-direct-present-gpu-v3.img.hello-init.json`
    - `/Users/justin/code/shadow/worktrees/worker-1/build/pixel/boot/oneshot/ts-counter-app-direct-present-gpu-v3-primary/recover-traces/status.json`
    - `/Users/justin/code/shadow/worktrees/worker-1/build/pixel/boot/oneshot/ts-counter-app-direct-present-gpu-v3-confirm/recover-traces/status.json`
  - `app-direct-present-touch-counter`
    - `/Users/justin/code/shadow/worktrees/worker-2/build/pixel/boot/shadow-boot-orange-gpu-rust-bridge-default-app-direct-present-touch-counter-v1.img.hello-init.json`
    - `/Users/justin/code/shadow/worktrees/worker-2/build/pixel/boot/oneshot/app-direct-present-touch-counter-v1-primary-0B191JEC203253/recover-traces/status.json`
- The truth surface is `recover-traces/status.json` plus recovered metadata files, not the top-level one-shot wrapper result.
- The `ts-app-minimal` proof contract is now explicit in recovered status:
  - `expected_app_direct_present_app_id`
  - `expected_app_direct_present_client_kind`
  - `expected_app_direct_present_typescript_renderer`
  - `expected_app_direct_present_runtime_bundle_env`
  - `expected_app_direct_present_runtime_bundle_path`
  - `expected_metadata_compositor_frame_path`
  - `app_direct_present_proof_contract`
- The `app-direct-present` fix was two-part:
  - replace the boot-owned app client shell wrapper with a static Rust launcher
  - stage the Wayland libraries that `winit` loads dynamically and set `LD_LIBRARY_PATH` for the app bundle
- The next honest product rung on `master` is runtime-backed input on the same boot-owned render/present path.
- The `app-direct-present-touch-counter` proof uses a compositor-owned synthetic tap in the Rust demo app path and requires recovered metadata showing input observed, tap dispatched, counter incremented, touch-present latency, and a post-touch frame capture.
- Stock-init trigger / imported-rc / preflight work is now parked:
  - latest high-signal negative result: `/Users/justin/code/shadow/worktrees/rust-boot/build/pixel/runs/boot-kgsl-trigger-ladder/20260423T082243Z-09051JEC202061_/matrix-summary.json`
  - treat that seam as fallback evidence, not as a peer execution stream

## Best Observability

- Durable metadata breadcrumbs:
  - `stage.txt`
  - `probe-stage.txt`
  - `probe-fingerprint.txt`
  - `probe-report.txt`
  - `probe-timeout-class.txt`
- Recovery:
  - [`scripts/pixel/pixel_boot_recover_traces.sh`](../../scripts/pixel/pixel_boot_recover_traces.sh)
- Keep using:
  - `--skip-collect --recover-traces-after --no-wait-boot-completed`
  - `recover-traces/status.json` as the hardware truth surface

## Highest-Leverage Next Experiments

1. Run `touch-counter-gpu` so the first runtime-backed input redraw lands on the same boot-owned render/present path.
2. Run `ts-runtime-app-matrix-proof` if the TS worker is free, so app direct-present is not counter-demo-specific.
3. Run `boot-camera-rust-hal-frame-probe` as the camera sidecar; provider-service capture is reference evidence only.
4. Move into `shell-home-static` only after both the first real app lane and the first runtime-backed input lane are truthful.
5. Keep direct `std` PID1 and stock-init imported-rc work as fallback discriminators only.

## Fast Commands

Recover traces from the last boot-owned run:

```sh
PIXEL_SERIAL=11151JEC200472 scripts/pixel/pixel_boot_recover_traces.sh
```

Run the direct `std` PID1 regression discriminator:

```sh
scripts/shadowctl lease acquire 11151JEC200472 --lane stream-a --owner boot --agent Codex --note 'rust-bridge std-probe exec regression'
SHADOW_DEVICE_LEASE_FORCE=1 scripts/shadowctl -t 11151JEC200472 debug boot-lab-rust-bridge-run \
  --input build/pixel/boot/shadow-boot-hello-init-rust-minimal-v2.img \
  --shim-mode exec \
  --child-profile std-probe \
  --adb-timeout 120 \
  --boot-timeout 180 \
  --skip-collect \
  --recover-traces-after \
  --no-wait-boot-completed
scripts/shadowctl lease release 11151JEC200472 --agent Codex
```
