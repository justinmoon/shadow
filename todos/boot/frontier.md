# Boot Frontier

Use this file as the shortest truthful snapshot of the current boot-owned seam.

## Active Blocker

- The C driver-discovery lane reached the first truthful boot-owned GPU frame.
- The active blocker is now the Rust PID 1 / bootstrap port.
- The next critical-path goal is:
  - preserve the helper-backed boot-owned GPU proof
  - replace `scripts/pixel/pixel_hello_init.c` as the long-lived bootstrap seam
  - keep later compositor/runtime/shell work off the C seam

## Current Truth

- Rooted control and cold-control proofs still hold, but they are no longer the frontier.
- The helper-backed boot-owned ladder is now green on `09051JEC202061` through:
  - readonly KGSL open
  - raw KGSL getproperties
  - raw Vulkan instance / count-query-exit / count-query-no-destroy / count-query / physical-device count
  - wgpu enumerate-adapters-count / enumerate-adapters / adapter / device-request / device
  - strict Vulkan offscreen render
  - `gpu-render` with KMS present
- The decisive first-frame proof is:
  - [`build/pixel/boot/oneshot/20260422T062456Z-09051JEC202061_`](../../build/pixel/boot/oneshot/20260422T062456Z-09051JEC202061_)
  - recovered [`probe-report.txt`](../../build/pixel/boot/oneshot/20260422T062456Z-09051JEC202061_/recover-traces/channels/metadata-probe-report.txt)
  - `child_completed=true`
  - `child_timed_out=false`
  - `exit_status=0`
  - `orange_gpu_mode=gpu-render`
- The helper-backed raw Vulkan ladder is also confirmed on `11151JEC200472`:
  - [`build/pixel/boot/oneshot/20260422T060706Z-11151JEC200472_`](../../build/pixel/boot/oneshot/20260422T060706Z-11151JEC200472_)
  - `probe-report.txt` shows `child_completed=true` and `exit_status=0` for `raw-vulkan-physical-device-count-query-smoke`
- The recovery truth model improved during this push:
  - `pixel_boot_recover_traces.sh` now treats `probe-report.txt` child exit `0` as proof
  - helper-backed runs no longer need shadow-tag side effects to count as success
- The helper-dir collector is still not the truth channel for these one-shot boot-owned rungs:
  - use `--skip-collect --recover-traces-after`
  - rely on `/metadata` recovery, especially `probe-report.txt`
- C has reached its intended stopping point:
  - it found the firmware-serving prerequisite
  - it proved the real boot-owned GPU frame
  - the next seam should be the Rust port, not more C expansion

## Best Observability

- Durable metadata breadcrumbs:
  - `stage.txt`
  - `probe-stage.txt`
  - `probe-fingerprint.txt`
  - `probe-report.txt`
  - `probe-timeout-class.txt`
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
- `probe-report.txt` is now a first-class proof surface:
  - `child_completed=true`
  - `child_timed_out=false`
  - `exit_status=0`
  - use that when the rung intentionally produces no shadow-tag side effects

## On-Screen Contract

- `solid-orange`: prelude / panel takeover proof
- `checker-orange`: firmware preflight succeeded before any KGSL open
- `solid-red`: timeout still points at firmware / `request_firmware`
- `solid-blue`: timeout most likely moved into GMU / HFI bring-up
- `solid-yellow`: timeout most likely moved into secure zap boot
- `solid-cyan`: timeout most likely moved into CP init / ringbuffer submit
- `solid-magenta`: timeout most likely moved into GX/OOB wake or GMU power-handshake bring-up
- `success-solid`: timeout-control rung proved the repaint path after a generic post-checkerboard hang
- `code-orange-2`: validated checkpoint
- `code-orange-3`: probe-ready checkpoint
- `code-orange-4`: success postlude
- `code-orange-9`: payload watchdog timeout
- `code-orange-10`: child died from signal
- `code-orange-11`: child exited nonzero

Use the panel as a stage channel, not just “something orange happened.”

## Highest-Leverage Next Experiments

1. Port the PID 1 / bootstrap seam to Rust now.
   - keep the same config, mount, watchdog, metadata, and child-exec contract first
   - do not redesign the boot graph during the port
2. Re-prove the current helper-backed first-frame lane on the Rust seam.
   - `gpu-render`
   - `vulkan-offscreen`
   - `vulkan-device-request-smoke`
   - raw Vulkan query/count as fallback discriminators if the Rust seam regresses earlier
3. Keep later work blocked until the Rust seam is green.
   - no compositor
   - no apps
   - no shell
   - no service spikes
4. Use `09051JEC202061` as the primary Rust-port proof device and `11151JEC200472` as confirmation.
5. Land the helper-backed C ladder and tooling truthfully so the Rust port starts from a small, coherent baseline.

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

Re-run the first-frame proof lane:

```sh
scripts/shadowctl lease acquire 09051JEC202061 --lane stream-a --owner boot --agent Codex --note 'gpu-render fw-helper'
SHADOW_DEVICE_LEASE_FORCE=1 scripts/shadowctl -t 09051JEC202061 debug boot-lab-oneshot \
  --image build/pixel/boot/shadow-boot-orange-gpu-gpurender-fw-helper-v1.img \
  --adb-timeout 120 \
  --boot-timeout 180 \
  --skip-collect \
  --recover-traces-after \
  --no-wait-boot-completed
scripts/shadowctl lease release 09051JEC202061 --agent Codex
```
