# Boot Handoff Prompt

Use this as the starting prompt for the next boot-lab orchestrator.

## Goal

Continue the Pixel 4a boot-owned bring-up from the current KGSL seam without broadening scope. Keep the critical path on the smallest truthful discriminator that explains why boot-owned userspace still cannot complete `open("/dev/kgsl-3d0")`.

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
- The earlier raw Vulkan query seam was narrowed until the active blocker moved earlier: KGSL open.
- Rooted tmpfs-`/dev` controls still succeed for:
  - `raw-kgsl-getproperties-smoke`
  - `raw-kgsl-open-readonly-smoke`
- Rooted cold control on `11151JEC200472` now succeeds at `cold-root-ready`:
  - [`build/pixel/runs/kgsl-cold-matrix/20260421T212908Z`](../../build/pixel/runs/kgsl-cold-matrix/20260421T212908Z)
  - `device-run/status.json.run_succeeded=true`
  - `device-run/status.json.summary.kgsl_device_opened=true`
  - the matching `props.tsv` still had `sys.boot_completed`, `dev.bootcomplete`, `pd_mapper`, `qseecom-service`, `gpu`, and display-service props all blank

## Current Critical Truth

- Boot-owned `raw-kgsl-open-readonly-smoke` on `09051JEC202061` recovers:
  - `metadata_probe_stage_value=orange-gpu-payload:kgsl-open-readonly`
  - never `...:kgsl-open-readonly-ok`
- The latest decisive boot-owned run is:
  - [`build/pixel/boot/oneshot/20260421T223433Z-09051JEC202061_`](../../build/pixel/boot/oneshot/20260421T223433Z-09051JEC202061_)
  - recovered `probe-report.txt` shows `wchan=_request_firmware`
  - recovered `/proc/<pid>/stack` shows `a6xx_microcode_read -> request_firmware -> _request_firmware`
- Two newer watched runs then proved the staged firmware seam itself:
  - [`build/pixel/boot/oneshot/20260422T002609Z-09051JEC202061_`](../../build/pixel/boot/oneshot/20260422T002609Z-09051JEC202061_)
  - [`build/pixel/boot/oneshot/20260422T002911Z-0B191JEC203253_`](../../build/pixel/boot/oneshot/20260422T002911Z-0B191JEC203253_)
  - visible sequence on both devices: `orange -> checkerboard -> black -> fastboot`
  - that proves `a630_sqe.fw`, `a618_gmu.bin`, and `a615_zap.*` are staged and readable in owned userspace before any KGSL open
- The next observability attempt also narrowed the problem:
  - the timeout-control rung showed `orange -> checkerboard -> black -> orange -> black -> fastboot`
  - so the generic parent timeout repaint path is fine
  - the real `c-kgsl-open-readonly-smoke` rung still shows `orange -> checkerboard -> black -> fastboot`
  - a new tiny `probe-timeout-class.txt` artifact also failed to survive that seam on `09051JEC202061`
- So for the post-firmware KGSL seam, `/metadata` and the repaint classifier are both unreliable:
  - recent recovery bundles came back with `metadata_probe_stage_present=false`, `metadata_probe_report_present=false`, and `metadata_probe_timeout_class_present=false`
  - do not spend more runs on color/pattern churn for the same seam
- The exact same thing is true for:
  - the staged Rust payload
  - direct C child probe
  - direct C PID1 probe
- So the current seam is:
  - any boot-owned process, including PID 1, reaches the first KGSL open path
  - the last durable blocker was still firmware loading during `a6xx_microcode_read`
  - but the next working hypothesis is now the first post-firmware seam: GMU / HFI, secure zap boot, or CP init

## What Is Strongly Ruled Out

- staged Rust payload bug
- dynamic loader bug
- Turnip/Vulkan userspace bug as the first blocker
- generic `/dev` topology mismatch
- write access being the issue
- SurfaceFlinger / composer / allocator being obvious prerequisites for readonly KGSL open under rooted Android
- late vendor-init / Android milestones (`pd_mapper`, `qseecom-service`, `gpu`, `boot_completed`) being required prerequisites for rooted readonly KGSL open

## Strongest Hypothesis

The remaining difference is no longer generic execution context or “wait later in Android.” The firmware-serving seam itself is now proven at the userspace staging layer. The best current suspect is the first post-firmware bring-up seam named by the sunfish kernel.

The best next discriminators are:

1. Re-run the same boot-owned `c-kgsl-open-readonly-smoke` rung with `log_kmsg=true` and explicit timeout-classification logging before reboot.
2. Recover the result through the existing previous-boot log channels instead of `/metadata`:
   - `logcat -L`
   - `dropbox SYSTEM_LAST_KMSG`
   - best-effort kernel log channels
3. If that still does not survive, instrument only the named source-backed post-firmware seams:
   - `a6xx_gmu_start` / `a6xx_gmu_hfi_start`
   - `subsystem_get("a615_zap")`
   - `a6xx_send_cp_init`
4. Keep execution-context and holder-scan evidence as supporting context, not the primary blocker.

Do not jump back out to `orange-gpu`, compositor, or app launch work until one of those moves the seam.
Once the first truthful boot-owned `orange-gpu` frame is proven, stop extending the C PID 1 seam and port the bootstrap path to Rust before any compositor, runtime, shell, or service milestones.

## Current Device Map

- `09051JEC202061`
  - primary boot-owned lane
  - rooted
  - best current reproducer for the KGSL-open seam
- `11151JEC200472`
  - rooted
  - transport-confounded for guarded `adb reboot bootloader` probes
  - use carefully for boot-owned runs until reboot-to-bootloader is fixed or bypassed
- `0B191JEC203253`
  - healthy rooted sidecar lane
  - proven good for sound and KGSL control experiments
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
- `scripts/pixel/pixel_boot_build_orange_gpu.sh`
- `scripts/pixel/pixel_boot_recover_traces.sh`
- `scripts/pixel/pixel_kgsl_cold_matrix.sh`
- `scripts/pixel/pixel_kgsl_matrix.sh`
- `scripts/pixel/pixel_tmpfs_dev_gpu_smoke.sh`
- `rust/drm-rect/src/lib.rs`
- `ui/crates/shadow-gpu-smoke/src/main.rs`

## Ground Rules

- Keep one critical-path boot seam at a time.
- Use rooted sidecars only for independent discriminators.
- Prefer durable evidence over watched-only evidence.
- Update [plan.md](./plan.md) before and after meaningful seam changes.
- Commit between working demos.
- Land small truthful chunks to `master`; do not pile up a giant boot branch.
