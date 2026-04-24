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
  - `ts-runtime-app-matrix`
    - `/Users/justin/code/shadow/worktrees/worker-1/build/pixel/boot/shadow-boot-orange-gpu-rust-bridge-default-ts-timeline-app-direct-present-gpu-v1.img.hello-init.json`
    - `/Users/justin/code/shadow/worktrees/worker-1/build/pixel/boot/oneshot/ts-timeline-app-direct-present-gpu-v1-primary/recover-traces/status.json`
    - `/Users/justin/code/shadow/worktrees/worker-1/build/pixel/boot/oneshot/ts-timeline-app-direct-present-gpu-v1-confirm/recover-traces/status.json`
  - `app-direct-present-touch-counter`
    - `/Users/justin/code/shadow/worktrees/worker-2/build/pixel/boot/shadow-boot-orange-gpu-rust-bridge-default-app-direct-present-touch-counter-v1.img.hello-init.json`
    - `/Users/justin/code/shadow/worktrees/worker-2/build/pixel/boot/oneshot/app-direct-present-touch-counter-v1-primary-0B191JEC203253/recover-traces/status.json`
  - `touch-counter-gpu`
    - `/Users/justin/code/shadow/worktrees/worker-2/build/pixel/boot/oneshot/rt-touch-v1-0905-20260423230353/orange-gpu.img.hello-init.json`
    - `/Users/justin/code/shadow/worktrees/worker-2/build/pixel/boot/oneshot/rt-touch-v1-0905-20260423230353/run-adb-recover/recover-traces/status.json`
- The truth surface is `recover-traces/status.json` plus recovered metadata files, not the top-level one-shot wrapper result.
- Payload storage truth: `/metadata` is control-plane only. Hardware showed `/metadata` is ~10 MiB total, while the real compressed compositor/session/blitz/system/GPU-driver/app payload archive is 106 MiB and 1.0 GiB expanded.
- `/data` has enough capacity and Android-side staging works, but boot-owned PID1 cannot mount raw `userdata` directly. Sunfish fstab uses `fileencryption=ice` with keys under `/metadata/vold/metadata_encryption`; live Android mounts `/data` from dm device `userdata` (`dm-default-key, AES-256-XTS - 8:15 0`). The current recovered blocker is `userdata-mount-failed` / `userdata-mount-f2fs:Invalid argument (os error 22)` from `build/pixel/boot/oneshot/data-payload-hw-20260424T032531Z-0905-09051JEC202061/recover-traces/status.json`.
- The payload decision is now a custom logical partition in `super`, not `/data`: every lab Pixel has a 256 MiB ext4 `shadow_payload_<active-slot>` dynamic partition with the same `shadow-logical-uniform-20260424T001500Z` manifest and the 106 MiB real payload archive.
- Boot-owned Rust PID1 can parse Android liblp metadata from `super`, validate geometry/header/table SHA-256 checksums, create a read-only dm-linear mapping for `shadow_payload_<slot>`, mount it at `/shadow-payload`, and verify `/shadow-payload/manifest.env` plus `payload.txt`.
- Current hardware proof:
  - image: `build/pixel/boot/shadow-logical-uniform-20260424T001500Z.img`
  - recover status: `build/pixel/boot/oneshot/shadow-logical-uniform-20260424T001500Z-09051JEC202061/recover-traces/status.json`
  - proof fields: `proof_ok=true`, `probe_summary_proves_payload_partition=true`, `metadata_probe_summary_payload_source=shadow-logical-partition`, `metadata_probe_summary_payload_root=/shadow-payload`, `metadata_probe_summary_payload_mounted_roots=["/metadata","/shadow-payload"]`, and empty `metadata_probe_summary_payload_shadow_logical_mount_error`.
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
- The next honest product rung on `master` is a real boot-owned shell session on top of the proven runtime app and input path.
- A static shell frame is not enough unless it is attached to the real session contract: no dummy client product path, no one-frame-only success contract, no automatic success reboot, and recovered metadata showing session readiness.
- The `app-direct-present-touch-counter` proof uses a compositor-owned synthetic tap in the Rust demo app path and requires recovered metadata showing input observed, tap dispatched, counter incremented, touch-present latency, and a post-touch frame capture.
- The `touch-counter-gpu` proof uses the same compositor-owned synthetic tap on the TypeScript runtime `counter` app and requires recovered metadata showing input observed, tap dispatched, `counter_incremented`, post-touch commit, touch-present latency, and a post-touch frame capture.
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

1. Continue from the partition-backed shell proofs: `ss-timeline-logical-r1-20260424052405` proved shell-launched TypeScript `timeline` with the GPU renderer, and `ss-rust-demo-logical-r2-20260424055521` proved shell-launched Rust `rust-demo` with SHM frames imported into the GPU shell scanout path.
2. Fold in worker-2's manual touch path against the partition-backed shell image so the demo becomes interactive instead of only first-frame/proof driven.
3. Turn the one-shot proof path into the first non-rebooting held session that leaves the compositor/app stack running long enough for operator interaction.
4. Run `boot-camera-vendor-linker-stage` opportunistically as the camera sidecar so the Rust boot HAL probe can advance past the current `/vendor/lib64/hw/camera.sm6150.so` visibility blocker.
5. Keep camera and sound as sidecars until the shell/app loop exists; keep direct `std` PID1 and stock-init imported-rc as fallback discriminators only.

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
