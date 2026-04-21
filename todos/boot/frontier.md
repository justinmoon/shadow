# Boot Frontier

Use this file as the shortest truthful snapshot of the current boot-owned seam.

## Active Blocker

- Boot-owned userspace can reach PID 1, boot-owned KMS, and the orange prelude.
- The current blocker is still `open("/dev/kgsl-3d0")` in boot-owned userspace.
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

1. Run the readonly KGSL-open helper from stock init (`post-fs-data` / imported rc service) to separate execution context from “boot-owned custom PID 1”.
2. Extend boot-owned `probe-report.txt` / breadcrumbs with execution-context facts (`id`, SELinux context, mount/cgroup markers) so the failing boot-owned lane can be compared directly against the rooted `root-ready` control.
3. Keep `kgsl-holder-scan` as best-effort only; do not block the next seam on making that scan perfect.

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
