# Boot Handoff Prompt

Use this as the starting prompt for the next boot-lab orchestrator.

## Goal

Continue the Pixel 4a boot-owned bring-up from the new Rust cutoff. The C seam has already reached the first truthful boot-owned GPU frame. The critical path is now: keep the Rust migration on the working `no_std PID1 shim -> full Rust child` shape, then re-prove the same helper-backed GPU frame without broadening into compositor, app, or shell work.

## Read First

- [frontier.md](./frontier.md)
- [history.md](./history.md)
- [plan.md](./plan.md)
- [spec-scope.md](./spec-scope.md)
- [spec-phase1-shadow-at-boot.md](./spec-phase1-shadow-at-boot.md)

## What Is Already Proven

- Boot-owned PID 1 works.
- `orange-kms` works.
- Rooted `gpu-smoke` and `gpu-kms-bridge` work.
- Boot-owned bundle exec works.
- Boot-owned strict Vulkan instance creation works.
- Boot-owned raw Vulkan instance creation works.
- Helper-backed boot-owned KGSL and raw Vulkan now work:
  - readonly KGSL open
  - raw KGSL getproperties
  - raw Vulkan count-query-exit / count-query-no-destroy / count-query / physical-device count
- Helper-backed boot-owned wgpu bring-up now works:
  - enumerate-adapters-count
  - enumerate-adapters
  - adapter
  - device-request
  - device
  - offscreen render
- First truthful boot-owned GPU frame now works:
  - [`build/pixel/boot/oneshot/20260422T062456Z-09051JEC202061_`](../../build/pixel/boot/oneshot/20260422T062456Z-09051JEC202061_)
  - recovered `probe-report.txt` shows `child_completed=true`, `child_timed_out=false`, `exit_status=0`
  - the image is `shadow-boot-orange-gpu-gpurender-fw-helper-v1.img`
- Confirmation device proof exists for the helper-backed raw Vulkan ladder:
  - [`build/pixel/boot/oneshot/20260422T060706Z-11151JEC200472_`](../../build/pixel/boot/oneshot/20260422T060706Z-11151JEC200472_)

## Current Critical Truth

- The seam is no longer “what does KGSL need.” That part is solved by the userspace firmware helper.
- The active risk is now architectural, not driver discovery:
  - direct `std` Rust as exact-path `/system/bin/init` still returns `kernel_panic`
  - `no_std` Rust exact-path PID 1 returns cleanly to bootloader
  - `no_std` Rust PID 1 shim plus full Rust `hello-init` child also returns cleanly on the stripped `hello` lane
  - that bridge shape has now also re-proved:
    - `vulkan-offscreen` on `09051JEC202061`
    - `gpu-render` on `09051JEC202061`
  - the next question is whether that bridge shape can be automated and confirmed more broadly without silently regressing
- The best current proof surface is `probe-report.txt`, not shadow-tag correlation.
- The current helper-backed one-shot recipe is:
  - `--skip-collect --recover-traces-after --no-wait-boot-completed`
  - read `recover-traces/status.json`
  - treat `probe_report_proves_child_success=true` as the success condition

## What Is Strongly Ruled Out

- the old KGSL-open blocker as the current frontier
- staged Rust payload bug as the explanation for the old blocker
- dynamic loader bug
- generic `/dev` topology mismatch
- late Android/vendor milestones as the missing KGSL prerequisite

## Strongest Hypothesis

The driver-discovery phase is complete enough. The highest-value next move is no longer another helper-backed C rung; it is a narrow Rust port of the bootstrap seam.

Do this in order:

1. Keep the Rust seam on the working bridge shape:
   - `no_std` Rust PID 1 shim
   - full Rust `hello-init` child
2. Treat the Rust bridge seam as the new working truth on `09051JEC202061`.
3. Use the direct rust-bridge builder path first:
   - `pixel_boot_build_orange_gpu.sh --hello-init-mode rust-bridge`
   - stage `/system/bin/init` as the no_std Rust shim
   - stage `/hello-init-child` as the full Rust child
   - keep the companion metadata honest (`hello_init_impl=rust-bridge`, `hello_init_child_path=/hello-init-child`, blank unsupported probe files)
   - use `pixel_boot_build_rust_bridge.sh` only as a fallback/helper path when converting an already-built image
4. If the bridge helper regresses on a new rung, fall back down the already-proven helper-backed ladder:
   - `vulkan-offscreen`
   - `vulkan-device-request-smoke`
   - raw Vulkan query/count
5. Do not broaden into compositor, apps, shell, or services until the Rust seam is green.
6. Keep the bridge honest:
   - do not re-open C-only orange-gpu modes on the Rust bridge until the Rust child actually supports them
   - do not pass parent-probe configs through `rust-bridge` mode until the Rust child grows a real parent-probe implementation
   - if the Rust child still does not emit `probe-fingerprint` / `probe-timeout-class`, keep those metadata fields blank instead of advertising fake expectations
7. Keep the direct `std`-PID1 investigation narrow:
   - the leading source-backed suspect is pre-`main` `std` runtime / TLS startup
   - next smallest hardware discriminator is `no_std` exact-path PID1 shim -> direct `execv()` into the tiny `std` probe, without `fork()`
   - the build path for that now exists: `pixel_boot_build_rust_bridge.sh --shim-mode exec`

## Current Device Map

- `09051JEC202061`
  - primary boot-owned lane
  - rooted
  - primary first-frame / Rust-port proof device
- `11151JEC200472`
  - rooted
  - confirmation lane
  - keep free unless confirming a promoted rung or the Rust seam
- `0B191JEC203253`
  - healthy rooted sidecar lane
  - proven good for sidecars and rooted control experiments
- `06241JEC200520`
  - healthy rooted sidecar / spare lane

## Observability That Now Exists

- `scripts/pixel/pixel_boot_recover_traces.sh`
  - `kgsl-holder-scan`
  - `kernel-current-best-effort` preferring rooted `dmesg`
  - `probe-report.txt` recovery and parsed status fields for `observed_probe_stage`, timeout, and `wchan`
  - `probe-timeout-class.txt` recovery and parsed status fields for checkpoint / bucket / matched needle when it survives
- `scripts/pixel/pixel_tmpfs_dev_gpu_smoke.sh`
  - `kgsl-holder-scan.tsv`
  - parsed holder metadata in `status.json`
  - `exec-context.txt`
- `scripts/pixel/pixel_kgsl_cold_matrix.sh`
  - manifest-driven rooted cold KGSL ladder
  - the decisive current result is `cold-root-ready`, not any later service milestone
- `scripts/pixel/pixel_kgsl_matrix.sh`
  - manifest-driven rooted KGSL falsification batches
  - one `matrix-summary.json` plus `matrix.tsv`
- watched runs
  - `solid-red/blue/yellow/cyan/magenta`, `success-solid`, and `code-orange-2/3/4/9/10/11` stage/failure visuals
  - `checker-orange` now has a two-device proof as the firmware-preflight success contract

The smokes covering this are:

- `scripts/ci/pixel_boot_recover_traces_smoke.sh`
- `scripts/ci/pixel_boot_tooling_smoke.sh`
- `scripts/ci/pixel_kgsl_cold_matrix_smoke.sh`
- `scripts/ci/pixel_kgsl_matrix_smoke.sh`

## Files Most Likely To Matter Next

- `scripts/pixel/pixel_hello_init.c`
- `rust/init-wrapper/src/main.rs`
- `flake.nix`
- `scripts/pixel/pixel_boot_build_orange_gpu.sh`
- `scripts/pixel/pixel_boot_recover_traces.sh`
- `ui/crates/shadow-gpu-smoke/src/main.rs`

## Ground Rules

- Keep one critical-path boot seam at a time.
- Use rooted sidecars only for independent discriminators.
- Prefer durable evidence over watched-only evidence.
- Update [plan.md](./plan.md) before and after meaningful seam changes.
- Commit between working demos.
- Land small truthful chunks to `master`; do not pile up a giant boot branch.
