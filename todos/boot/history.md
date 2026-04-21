# Boot History

Keep this file short. It is the checkpoint ledger, not the frontier.

## Proven Rungs

- `hello-init`: boot-owned PID 1 works.
- `orange-kms`: boot-owned panel takeover works.
- rooted `gpu-smoke`: strict offscreen GPU render works.
- rooted `gpu-kms-bridge`: rooted GPU render plus KMS present works.
- `boot-bundle-exec`: boot-owned bundle exec and return works.
- `boot-vulkan-instance-smoke`: boot-owned strict Vulkan instance creation works.
- `boot-raw-vulkan-instance-smoke`: boot-owned raw Vulkan loader plus `vkCreateInstance` / `vkDestroyInstance` works.
- The later raw Vulkan / wgpu splits moved the seam earlier until the blocker became KGSL open, not generic Vulkan setup.

## Ruled-Out Explanations

- generic `/dev` topology mismatch
- staged Rust bundle bug
- dynamic loader bug
- write access as the first KGSL problem
- SurfaceFlinger / hwcomposer / allocator as the obvious prerequisite for readonly KGSL open in rooted controls

## Tooling Milestones

- auto-recovery from oneshot fastboot returns
- late `wait-adb` recovery and transport timeline capture
- rooted `kgsl-holder-scan` in recover-traces and tmpfs control runs
- reusable child watchdog / timeout reporting in `hello-init`
- durable `probe-report.txt` recovery
- `code-orange-*` stage visuals for watched runs
- rooted KGSL batch runner:
  - [`scripts/pixel/pixel_kgsl_matrix.sh`](../../scripts/pixel/pixel_kgsl_matrix.sh)
