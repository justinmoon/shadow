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

## Current Truth

- Rooted tmpfs-`/dev` controls still succeed for:
  - `raw-kgsl-getproperties-smoke`
  - `raw-kgsl-open-readonly-smoke`
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

1. Stock-init trigger ladder for the readonly KGSL-open helper.
2. Warm-vs-cold rooted KGSL holder matrix on sidecar devices.
3. Read the new `probe-report.txt` from a boot-owned timeout and classify the blocked task by `observed_probe_stage` and `wchan`.

## Fast Commands

Rooted KGSL matrix:

```sh
PIXEL_SERIAL=0B191JEC203253 scripts/pixel/pixel_kgsl_matrix.sh
```

Dry-run the matrix runner contract:

```sh
PIXEL_SERIAL=TESTSERIAL scripts/pixel/pixel_kgsl_matrix.sh --dry-run
```

Recover traces from the last boot-owned run:

```sh
PIXEL_SERIAL=09051JEC202061 scripts/pixel/pixel_boot_recover_traces.sh
```
