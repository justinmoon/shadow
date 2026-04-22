# Boot History

Keep this file short. It is the checkpoint ledger, not the frontier.

## Proven Rungs

- `hello-init`: boot-owned PID 1 works.
- `orange-kms`: boot-owned panel takeover works.
- rooted `gpu-smoke`: strict offscreen GPU render works.
- rooted `gpu-kms-bridge`: rooted GPU render plus KMS present works.
- rooted `kgsl-cold-root-ready`: after a cold reboot, readonly KGSL open succeeds as early as `root-ready`, before the tracked Android/vendor service props become nonblank.
- `boot-bundle-exec`: boot-owned bundle exec and return works.
- `firmware-probe-only`: boot-owned staged GPU firmware preflight now visibly succeeds.
- `boot-vulkan-instance-smoke`: boot-owned strict Vulkan instance creation works.
- `boot-raw-vulkan-instance-smoke`: boot-owned raw Vulkan loader plus `vkCreateInstance` / `vkDestroyInstance` works.
- firmware helper breakthrough:
  - boot-owned readonly KGSL open now works
  - boot-owned raw KGSL getproperties now works
- helper-backed raw Vulkan ladder now works:
  - `boot-raw-vulkan-physical-device-count-query-exit-smoke`
  - `boot-raw-vulkan-physical-device-count-query-no-destroy-smoke`
  - `boot-raw-vulkan-physical-device-count-query-smoke`
  - `boot-raw-vulkan-physical-device-count-smoke`
- helper-backed wgpu ladder now works:
  - `boot-vulkan-enumerate-adapters-count-smoke`
  - `boot-vulkan-enumerate-adapters-smoke`
  - `boot-vulkan-adapter-smoke`
  - `boot-vulkan-device-request-smoke`
  - `boot-vulkan-device-smoke`
  - `boot-vulkan-offscreen`
- first truthful boot-owned GPU frame now works:
  - helper-backed `gpu-render` on `09051JEC202061`
  - recovered `probe-report.txt` shows `child_completed=true`, `child_timed_out=false`, `exit_status=0`
  - this is the Rust cutoff trigger

## Ruled-Out Explanations

- generic `/dev` topology mismatch
- staged Rust bundle bug
- dynamic loader bug
- write access as the first KGSL problem
- SurfaceFlinger / hwcomposer / allocator as the obvious prerequisite for readonly KGSL open in rooted controls
- late vendor-init / Android milestones (`pd_mapper`, `qseecom-service`, `gpu`, `boot_completed`) as required prerequisites for rooted readonly KGSL open

## Tooling Milestones

- auto-recovery from oneshot fastboot returns
- late `wait-adb` recovery and transport timeline capture
- rooted `kgsl-holder-scan` in recover-traces and tmpfs control runs
- timeout-bounded holder scans via `pixel_root_shell_timeout()`
- reusable child watchdog / timeout reporting in `hello-init`
- durable `probe-report.txt` recovery
- `code-orange-*` stage visuals for watched runs
- checkpoint visibility fix for non-postlude diagnostics:
  - firmware probe visuals now render for the C KGSL rungs instead of being silently gated behind the success-postlude modes
- firmware-only rung:
  - `orange -> checkerboard -> black -> fastboot` on `09051JEC202061`
  - same watched sequence on `0B191JEC203253`
  - this is the first two-device proof that the staged `a630_sqe.fw`, `a618_gmu.bin`, and `a615_zap.*` blobs are readable in owned userspace
- rooted KGSL batch runner:
  - [`scripts/pixel/pixel_kgsl_matrix.sh`](../../scripts/pixel/pixel_kgsl_matrix.sh)
  - [`scripts/pixel/pixel_kgsl_cold_matrix.sh`](../../scripts/pixel/pixel_kgsl_cold_matrix.sh)
- reusable userspace firmware helper for `/sys/class/firmware`
- bounded recover-traces root-shell collection:
  - hung privileged collection no longer pins the oneshot wrapper forever
- `probe-report.txt` proof promotion:
  - recovery now credits `child_completed=true` plus `exit_status=0` as a successful rung even with no shadow-tag matches
