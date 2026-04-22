# Boot Frontier

Use this file as the shortest truthful snapshot of the current boot-owned seam.

## Active Blocker

- The C lane is now signed off in the narrow helper-backed `gpu-render` sense.
- The active blocker is the Rust PID 1 / bootstrap port, and the seam is now narrower:
  - Rust's normal `main` / `lang_start` startup path is the bad boundary under PID 1
  - `std` Rust as exact-path `/system/bin/init` still panics as real PID 1
  - `std-minimal-probe` still panics as PID 1
  - `std-nomain-probe` now returns cleanly to bootloader
  - the full Rust `hello-init` child now also returns cleanly once it enters through raw `argc/argv`
- The next critical-path goal is:
  - preserve the signed-off helper-backed boot-owned GPU proof
  - promote the `exec + raw-argv + hello-init-rust` bridge as the primary Rust seam
  - replace `scripts/pixel/pixel_hello_init.c` as the long-lived bootstrap seam
  - keep later compositor/runtime/shell work off the C seam
  - stop treating the old `fork` bridge as the primary target

## Current Truth

- Rooted control and cold-control proofs still hold, but they are no longer the frontier.
- This branch hardens that contract in three ways:
  - `hello-init` now persists `/orange-gpu/summary.json` durably to `/metadata/.../probe-summary.json`
  - recovery validates `gpu-render` from that summary, not just from `probe-report.txt`
  - `gpu-render` now uses the stable `flat-orange` GPU scene plus a green `success-solid` postlude after validated success
- The new trustworthy `gpu-render` proof tuple is:
  - `probe-report.txt`: `child_completed=true`, `child_timed_out=false`, `exit_status=0`
  - `probe-summary.json`: `scene=flat-orange`, `present_kms=true`, `kms_present` present, `software_backed=false`, `adapter.backend=Vulkan`, `distinct_color_count=1`, `distinct_color_samples_rgba8=["ff7a00ff"]`
  - watched run: solid orange prelude, then green success postlude before reboot
- Signed-off hardware evidence for that tuple now exists on two devices:
  - [`build/pixel/boot/oneshot/20260422T163601Z-09051JEC202061_`](../../build/pixel/boot/oneshot/20260422T163601Z-09051JEC202061_)
  - [`build/pixel/boot/oneshot/20260422T163601Z-06241JEC200520_`](../../build/pixel/boot/oneshot/20260422T163601Z-06241JEC200520_)
  - both recovered bundles have `probe_summary_proves_gpu_render=true` with checksum `bb77813ec3232325`
- The watched operator-facing confirmation run is:
  - [`build/pixel/boot/oneshot/20260422T165710Z-06241JEC200520_`](../../build/pixel/boot/oneshot/20260422T165710Z-06241JEC200520_)
  - human-observed sequence: orange, then green for about 10 seconds, then black -> fastboot -> Android
  - recovered summary still proves the same `flat-orange` Vulkan/Turnip/KMS tuple with `hold_secs=10`
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
  - Rust-port breakpoint on 2026-04-22:
  - direct `hello-init-rust` as exact-path `/system/bin/init` still returns `kernel_panic` even with `payload=hello`, `mount_dev=false`, `mount_proc=false`, `mount_sys=false`, `log_kmsg=false`, and `log_pmsg=false`
  - [`build/pixel/boot/oneshot/20260422T073954Z-09051JEC202061_`](../../build/pixel/boot/oneshot/20260422T073954Z-09051JEC202061_) proves a tiny `std` Rust exact-path probe also returns `kernel_panic`
  - [`build/pixel/boot/oneshot/20260422T074257Z-09051JEC202061_`](../../build/pixel/boot/oneshot/20260422T074257Z-09051JEC202061_) proves a `no_std` Rust exact-path probe returns to fastboot/bootloader instead of `kernel_panic`
  - [`build/pixel/boot/oneshot/20260422T074912Z-09051JEC202061_`](../../build/pixel/boot/oneshot/20260422T074912Z-09051JEC202061_) proves a `no_std` Rust PID 1 shim can fork/exec the full Rust `hello-init` child and still return cleanly to fastboot/bootloader
  - that makes `std`-as-PID1 the active Rust blocker, not “Rust at PID1 at all”
  - Rust bridge proofs on the primary device:
    - [`build/pixel/boot/oneshot/20260422T075537Z-09051JEC202061_`](../../build/pixel/boot/oneshot/20260422T075537Z-09051JEC202061_) proves `vulkan-offscreen` on the Rust bridge seam with `probe_report_proves_child_success=true`
    - [`build/pixel/boot/oneshot/20260422T075901Z-09051JEC202061_`](../../build/pixel/boot/oneshot/20260422T075901Z-09051JEC202061_) proves `gpu-render` on the Rust bridge seam with `probe_report_proves_child_success=true`
    - in both runs the recovered `probe-report.txt` shows `child_completed=true`, `child_timed_out=false`, `child_exit_status=0`
    - the recovered `observed_probe_stage` is still `orange-gpu-payload:firmware-helper-waiting`, so the surviving stage file is stale relative to the successful child exit; trust `probe_report_proves_child_success` over the stage string for now
  - Confirmation status on `11151JEC200472` is weaker:
    - the same Rust-bridge `vulkan-offscreen` image returns cleanly to fastboot/bootloader
    - but recovery did not recover the metadata files there, so `09051JEC202061` remains the truth device for the Rust bridge seam until the `11151` metadata gap is explained
  - Rust-bridge guardrails on 2026-04-22:
    - the builder now rejects C-only orange-gpu modes up front instead of silently repacking them into a Rust image that cannot execute them
    - the builder now rejects parent-probe configs in `rust-bridge` mode up front instead of letting the Rust child fail late
    - cloned Rust-bridge metadata now clears unsupported `probe-fingerprint` / `probe-timeout-class` expectations instead of advertising files the Rust child does not currently write
    - the Rust child now honors `log_kmsg` / `log_pmsg` toggles and restores `orange_gpu_timeout_action=panic` instead of treating it like a reboot timeout
  - Rust-bridge builder truth on 2026-04-22:
    - `pixel_boot_build_orange_gpu.sh --hello-init-mode rust-bridge` now stages the final image directly instead of recursively building a direct/C image first and then mutating it
    - the final image now stages `/system/bin/init` as the Rust no_std shim and `/hello-init-child` as the full Rust child in one pass
    - the direct builder now also supports `--rust-shim-mode exec` for that same full Rust child
    - direct orange-gpu rust-bridge images still require the real Rust child; probe-child variants stay on `pixel_boot_build_rust_bridge.sh`
    - the orange-gpu smoke now has a positive rust-bridge assertion for that final staged shape and for the companion metadata fields (`hello_init_impl=rust-bridge`, `hello_init_child_path=/hello-init-child`)
    - `pixel_boot_build_rust_bridge.sh` remains useful as a thin repack helper, but it is no longer the primary builder path for new rust-bridge orange-gpu images
  - Source-backed `std`-PID1 hypothesis on 2026-04-22:
    - the leading suspect is pre-`main` `std` runtime / TLS startup, not the `hello-init` logic itself
    - strongest evidence: tiny direct `std` PID1 probes still panic, while direct `no_std` PID1 and `no_std PID1 -> std child` both work
    - next smallest hardware discriminator: keep the working `no_std` exact-path PID1 shim, but replace `fork()+exec()` with a straight `execv()` into the tiny `std` probe
    - if that works, the bad seam is kernel-launched initial startup; if it still panics, `std` as PID1 remains the failing contract even after `exec`
    - the build surface is now ready for that discriminator:
      - `pixel_boot_build_rust_bridge.sh --shim-mode exec --child-profile std-probe` stages a dedicated no_std direct-exec shim plus the tiny `std` probe child
      - the bridge helper now fails closed on custom child-entry paths; the current shims always exec `/hello-init-child`
      - the smoke covers both `fork` and `exec` shim modes plus the fixed child-path contract
  - Raw-argv Rust bridge split on 2026-04-22:
    - [`build/pixel/boot/rust-bridge-run/20260422T155220Z-11151JEC200472_`](../../build/pixel/boot/rust-bridge-run/20260422T155220Z-11151JEC200472_) proves `std-minimal-probe` still returns `kernel_panic`
    - [`build/pixel/boot/rust-bridge-run/20260422T155403Z-09051JEC202061_`](../../build/pixel/boot/rust-bridge-run/20260422T155403Z-09051JEC202061_) and [`build/pixel/boot/rust-bridge-run/20260422T155539Z-11151JEC200472_`](../../build/pixel/boot/rust-bridge-run/20260422T155539Z-11151JEC200472_) prove `std-nomain-probe` returns cleanly to bootloader on both devices
    - [`build/pixel/boot/rust-bridge-run/20260422T160853Z-09051JEC202061_`](../../build/pixel/boot/rust-bridge-run/20260422T160853Z-09051JEC202061_) and [`build/pixel/boot/rust-bridge-run/20260422T161040Z-11151JEC200472_`](../../build/pixel/boot/rust-bridge-run/20260422T161040Z-11151JEC200472_) prove the full Rust `hello-init` child also returns cleanly once it enters through raw `argc/argv`
    - that makes `lang_start` / normal Rust `main` the live Rust blocker, not general `std` linkage
  - Raw-argv exec GPU proofs on 2026-04-22:
    - [`build/pixel/boot/oneshot/20260422T162509Z-09051JEC202061_`](../../build/pixel/boot/oneshot/20260422T162509Z-09051JEC202061_) proves `vulkan-offscreen` on the `exec + raw-argv + hello-init` seam with recovered `probe-report.txt` showing `child_completed=true`, `child_timed_out=false`, `exit_status=0`
    - [`build/pixel/boot/oneshot/20260422T162711Z-09051JEC202061_`](../../build/pixel/boot/oneshot/20260422T162711Z-09051JEC202061_) and [`build/pixel/boot/oneshot/20260422T162858Z-11151JEC200472_`](../../build/pixel/boot/oneshot/20260422T162858Z-11151JEC200472_) prove `gpu-render` on that same seam with the same recovered `probe-report.txt` truth surface

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

1. Promote the `exec + raw-argv + hello-init-rust` bridge as the primary Rust seam.
   - `no_std` exact-path Rust PID 1 shim
   - full Rust `hello-init` launched as a child
   - `exec` shim, not `fork`, as the architectural target
2. Update the direct rust-bridge builder and docs to use that seam first.
   - `hello`
   - `vulkan-offscreen`
   - `gpu-render`
   - keep `pixel_boot_build_rust_bridge.sh` as the fallback/helper path for probe-child variants
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

Run the next Rust bridge discriminator as one boot-lab command:

```sh
scripts/shadowctl lease acquire 09051JEC202061 --lane stream-a --owner boot --agent Codex --note 'rust-bridge std-probe exec discriminator'
SHADOW_DEVICE_LEASE_FORCE=1 scripts/shadowctl -t 09051JEC202061 debug boot-lab-rust-bridge-run \
  --input build/pixel/boot/shadow-boot-hello-init-rust-minimal-v2.img \
  --shim-mode exec \
  --child-profile std-probe \
  --adb-timeout 120 \
  --boot-timeout 180 \
  --skip-collect \
  --recover-traces-after \
  --no-wait-boot-completed
scripts/shadowctl lease release 09051JEC202061 --agent Codex
```

Re-run the promoted exec/raw-argv GPU lane:

```sh
scripts/shadowctl lease acquire 09051JEC202061 --lane stream-a --owner boot --agent Codex --note 'rust-bridge exec gpu-render raw-argv'
SHADOW_DEVICE_LEASE_FORCE=1 scripts/shadowctl -t 09051JEC202061 debug boot-lab-oneshot \
  --image build/pixel/boot/shadow-boot-orange-gpu-rust-bridge-exec-gpurender-fw-helper-rawargv-v1.img \
  --adb-timeout 120 \
  --boot-timeout 180 \
  --skip-collect \
  --recover-traces-after \
  --no-wait-boot-completed
scripts/shadowctl lease release 09051JEC202061 --agent Codex
```
