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
- The exact same thing is true for:
  - the staged Rust payload
  - direct C child probe
  - direct C PID1 probe
- So the current seam is:
  - any boot-owned process, including PID 1, hangs on `open("/dev/kgsl-3d0")`

## What Is Strongly Ruled Out

- staged Rust payload bug
- dynamic loader bug
- Turnip/Vulkan userspace bug as the first blocker
- generic `/dev` topology mismatch
- write access being the issue
- SurfaceFlinger / composer / allocator being obvious prerequisites for readonly KGSL open under rooted Android
- late vendor-init / Android milestones (`pd_mapper`, `qseecom-service`, `gpu`, `boot_completed`) being required prerequisites for rooted readonly KGSL open

## Strongest Hypothesis

The remaining difference is execution context, not “wait later in Android.”

The best next discriminators are:

1. Run the readonly KGSL-open helper from stock init (`post-fs-data` / imported rc service) to separate stock-init context from Magisk/root-shell context.
2. Extend boot-owned breadcrumbs with execution-context facts (`id`, SELinux context, mount/cgroup markers) and compare them directly against the rooted cold control.
3. Keep `kgsl-holder-scan` best-effort only; do not block the next seam on making holder counting perfect.

Do not jump back out to `orange-gpu`, compositor, or app launch work until one of those moves the seam.

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
- `scripts/pixel/pixel_tmpfs_dev_gpu_smoke.sh`
  - `kgsl-holder-scan.tsv`
  - parsed holder metadata in `status.json`
- `scripts/pixel/pixel_kgsl_cold_matrix.sh`
  - manifest-driven rooted cold KGSL ladder
  - the decisive current result is `cold-root-ready`, not any later service milestone
- `scripts/pixel/pixel_kgsl_matrix.sh`
  - manifest-driven rooted KGSL falsification batches
  - one `matrix-summary.json` plus `matrix.tsv`
- watched runs
  - `code-orange-2/3/4/9/10/11` stage/failure visuals

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
