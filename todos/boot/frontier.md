# Boot Frontier

Use this file as the shortest truthful snapshot of the current boot-owned seam.

## Active Blocker

- Boot-owned userspace can reach PID 1, boot-owned KMS, and the orange prelude.
- The current blocker is the first firmware load inside boot-owned `open("/dev/kgsl-3d0")`.
- The decisive recovered boot-owned stack on `09051JEC202061` is:
  - `kgsl_open`
  - `adreno_init`
  - `a6xx_microcode_read`
  - `request_firmware`
  - `_request_firmware`
- That seam is now narrower than:
  - the staged Rust bundle
  - the dynamic loader
  - Vulkan instance creation
  - generic `/dev` topology
  - Android display services as the obvious prerequisite
  - late vendor-init / Android milestones like `pd_mapper`, `qseecom-service`, `gpu`, or `boot_completed`

## Current Truth

- Rooted tmpfs-`/dev` controls still succeed for:
  - `raw-kgsl-getproperties-smoke`
  - `raw-kgsl-open-readonly-smoke`
- Rooted cold control now succeeds at the earliest measured rung:
  - [`build/pixel/runs/kgsl-cold-matrix/20260421T212908Z`](../../build/pixel/runs/kgsl-cold-matrix/20260421T212908Z)
  - `cold-root-ready` on `11151JEC200472` returned `run_succeeded=true` and `summary.kgsl_device_opened=true`
  - the matching [`props.tsv`](../../build/pixel/runs/kgsl-cold-matrix/20260421T212908Z/cold-root-ready/props.tsv) still had `sys.boot_completed`, `dev.bootcomplete`, `init.svc.pd_mapper`, `init.svc.qseecom-service`, `init.svc.gpu`, and display-service props all blank
- Boot-owned runs still stop before `...:kgsl-open-readonly-ok`.
- The same failure shape reproduces for:
  - direct C child probe
  - direct C PID 1 probe
  - the staged Rust payload
- The latest discriminating run is:
  - [`build/pixel/boot/oneshot/20260421T223433Z-09051JEC202061_`](../../build/pixel/boot/oneshot/20260421T223433Z-09051JEC202061_)
  - recovered `probe-report.txt` shows `wchan=_request_firmware`
  - recovered `/proc/<pid>/stack` shows `a6xx_microcode_read -> request_firmware -> _request_firmware`

## Best Observability

- Durable metadata breadcrumbs:
  - `stage.txt`
  - `probe-stage.txt`
  - `probe-fingerprint.txt`
  - `probe-report.txt`
- Recovery:
  - [`scripts/pixel/pixel_boot_recover_traces.sh`](../../scripts/pixel/pixel_boot_recover_traces.sh)
  - recovers the metadata files above, `kgsl-holder-scan`, and best-effort kernel logs
- Rooted falsification lane:
  - [`scripts/pixel/pixel_tmpfs_dev_gpu_smoke.sh`](../../scripts/pixel/pixel_tmpfs_dev_gpu_smoke.sh)
  - [`scripts/pixel/pixel_kgsl_matrix.sh`](../../scripts/pixel/pixel_kgsl_matrix.sh)
  - [`scripts/pixel/pixel_kgsl_cold_matrix.sh`](../../scripts/pixel/pixel_kgsl_cold_matrix.sh)
- Holder scans are now timeout-bounded and best-effort:
  - pre-run and post-run `kgsl-holder-scan` timeouts should not invalidate a positive readonly-open result
  - treat holder counts as helpful context, not as a gating success signal for the cold ladder
- Rooted tmpfs-`/dev` controls now also recover `exec-context.txt`, so the rooted control lane can be compared directly against boot-owned `probe-fingerprint` / `probe-report` output.

## On-Screen Contract

- `solid-orange`: prelude / panel takeover proof
- `code-orange-2`: validated checkpoint
- `code-orange-3`: probe-ready checkpoint
- `code-orange-4`: success postlude
- `code-orange-9`: payload watchdog timeout
- `code-orange-10`: child died from signal
- `code-orange-11`: child exited nonzero

Use the panel as a stage channel, not just “something orange happened.”

## Highest-Leverage Next Experiments

1. Add the smallest boot-owned firmware-serving seam for the first named blocker:
   - satisfy `a6xx_microcode_read` / `request_firmware("a630_sqe.fw")`
   - do not jump straight to generic full `ueventd`
2. Re-run the same boot-owned `c-kgsl-open-readonly-smoke` rung immediately after that seam lands:
   - if it moves forward, the next likely blockers are `a6xx_gmu_load_firmware("a618_gmu.bin")` and then secure zap boot (`a615_zap`)
   - if it still sleeps in `_request_firmware`, inspect the exact firmware helper contract instead of widening the ladder
3. Keep the tracefs-backed `probe-report.txt` enhancement as a useful refinement, but not the blocker: the current proc snapshot already proved where the hang is.

## Fast Commands

Rooted KGSL matrix:

```sh
PIXEL_SERIAL=0B191JEC203253 scripts/pixel/pixel_kgsl_matrix.sh
```

Rooted cold KGSL ladder:

```sh
PIXEL_SERIAL=11151JEC200472 scripts/pixel/pixel_kgsl_cold_matrix.sh
```

Dry-run the matrix runner contract:

```sh
PIXEL_SERIAL=TESTSERIAL scripts/pixel/pixel_kgsl_matrix.sh --dry-run
```

Recover traces from the last boot-owned run:

```sh
PIXEL_SERIAL=09051JEC202061 scripts/pixel/pixel_boot_recover_traces.sh
```
