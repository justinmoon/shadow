# Boot Frontier

Use this file as the shortest truthful snapshot of the current boot-owned seam.

## Active Blocker

- Boot-owned userspace can reach PID 1, boot-owned KMS, the orange prelude, and a dedicated firmware-only checkpoint rung.
- The current blocker is now the first post-firmware seam inside boot-owned `open("/dev/kgsl-3d0")`.
- The last durable recovered blocker before the firmware-only proof was:
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
- New proof on real hardware:
  - `firmware-probe-only` now visibly succeeds on both `09051JEC202061` and `0B191JEC203253`
  - watched sequence on both devices: `orange -> checkerboard -> black -> fastboot`
  - that proves the staged `a630_sqe.fw`, `a618_gmu.bin`, and `a615_zap.*` files are readable in owned userspace before any KGSL open
- Post-firmware observability is now the blocker, not just GPU bring-up:
  - watched `c-kgsl-open-readonly-smoke` still shows `orange -> checkerboard -> black -> fastboot`
  - the timeout-control rung proved the parent repaint path is healthy in general
  - but on the real KGSL seam, the post-timeout repaint still never appears
  - a new tiny `probe-timeout-class.txt` artifact also failed to survive the same seam on `09051JEC202061`
  - a follow-up `log_kmsg=true` run on `09051JEC202061` still recovered zero timeout-class lines through previous-boot log channels
  - a control `timeout-control-smoke` run with `orange_gpu_timeout_action=panic` on `11151JEC200472` came back with `ro.boot.bootreason=kernel_panic`, so the sysrq-panic path itself is real when the timeout branch actually wins
  - the matching real KGSL run with `orange_gpu_timeout_action=panic` still returned to fastboot/Android with `ro.boot.bootreason=reboot` and `sys.boot.reason=bootloader`
  - forcing the KGSL watchdog down to `12s` still did not change that `31s` fastboot-return shape on `09051JEC202061`
  - a live tracefs monitor that tried to advance `probe-stage.txt` to `trace-subsystem-get`, `trace-pil-boot`, `trace-gmu-start`, `trace-gmu-hfi-start`, or `trace-cp-init` also left no surviving metadata on the same seam
  - so for this post-firmware seam, both the panel timeout classifier and `/metadata` artifacts are currently weaker than they looked
- C remains acceptable only for the current driver-discovery seam:
  - use it to finish post-firmware KGSL classification through the first truthful `orange-gpu` frame
  - once that first boot-owned GPU frame is proven, cut the PID 1 / bootstrap seam over to Rust before compositor, runtime, shell, or service bring-up
- The latest discriminating run is:
  - [`build/pixel/boot/oneshot/20260421T223433Z-09051JEC202061_`](../../build/pixel/boot/oneshot/20260421T223433Z-09051JEC202061_)
  - recovered `probe-report.txt` shows `wchan=_request_firmware`
  - recovered `/proc/<pid>/stack` shows `a6xx_microcode_read -> request_firmware -> _request_firmware`
- The latest source-guided diagnosis is:
  - the post-firmware reboot-class suspect is now secure zap / PAS, not generic KGSL or GMU timeout handling
  - the strongest named path is `subsystem_get("a612_zap")` / `pil_boot()` during `a6xx_microcode_load()`
  - the rooted/control evidence still says ordinary Android display services are not the missing prerequisite for readonly KGSL open

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

1. Stop spending runs on the screen-only timeout classifier for this exact seam:
   - `orange -> checkerboard -> black -> fastboot` is reproducible
   - the timeout-control rung already proved the repaint path in general
   - the real KGSL seam suppresses the repaint, so more color tweaks are low-value
2. `log_kmsg=true` was worth trying and is now ruled out as the next easy answer:
   - the live timeout classifier now logs directly to kmsg before reboot
   - the previous-boot log recovery channels still came back empty on the same seam
3. Treat the direct PID 1 seam as an observability wall for now:
   - control panic works, so the missing `kernel_panic` on the real KGSL seam is evidence
   - the KGSL path is escaping to bootloader before the userspace watchdog can win
   - even live trace-stage writes do not survive once that seam starts
4. The next discriminator should come from a different seam, not more color churn on the same one:
   - use the stock-init helper / `rc` trigger ladder to launch the helper later in boot and see whether readonly KGSL open still resets there
   - if a later stock-init trigger stops the reboot, the missing prerequisite is timing / early-init state, not the open call alone
5. If the stock-init trigger ladder does not move it, the next diagnostic rung is kernel-facing:
   - target the zap/PAS seam named by source (`subsystem_get("a612_zap")` / `pil_boot()`)
   - prefer a minimal diagnostic branch or patch over more blind boot-image permutations

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
