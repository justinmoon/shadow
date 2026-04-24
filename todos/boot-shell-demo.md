# Boot Shell Demo

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Intent

- Build one aggressive feature branch that boots the rust-owned Pixel path into the real Shadow shell/app experience.
- Optimize for a working demo over small master rungs: compositor shell home, TypeScript app launch, Rust app path, and usable input/control.
- Keep the existing recovered proof discipline so failures identify the next blocker instead of becoming guesswork.

## Scope

- In scope:
  - rust boot seam to `shadow-session`
  - real shell startup config, not dummy shell client
  - GPU shell frame, TypeScript counter/timeline launch, Rust app regression path
  - session lifetime/control and touch/manual input when it unblocks the demo
  - payload staging fixes when ramdisk size becomes the blocker
- Out of scope for this branch unless they block the shell/app loop:
  - sound
  - camera
  - direct `std` PID1
  - stock-init/imported-rc fallback paths

## Approach

- Start from current `master` on branch `boot-shell-demo` in `worker-1`.
- Reuse the proven app-direct-present bundle machinery, but add a product shell-session boot mode.
- Prefer `counter` for the first shell-launched TypeScript app because it avoids network/service dependencies.
- Preserve the metadata/recover-traces truth surface and add shell-specific readiness fields.

## Steps

- [x] Define boot-owned shell startup artifact and staging shape.
- [x] Add shell-session boot mode and host smoke coverage.
- [x] Build and run first shell-home frame proof on a Pixel.
- [x] Add shell-start-app proof for TypeScript `counter`.
- [~] Fold in manual/real touch plumbing from `worker-2` if it helps interaction.
- [ ] Add persistent/held shell mode with a clear recovery path.
- [ ] Confirm on a second Pixel and record proof artifacts.

## Implementation Notes

- `worker-2` has useful manual touch work: `/dev/input/event2` bootstrap and non-synthetic touch config.
- The branch should not add more isolated app-direct rungs unless they directly unblock shell/app launch.
- Static musl `shadow-compositor-guest` could not load the Vulkan/ICD stack on device; shell-session now stages the dynamic `aarch64-linux-gnu` compositor and launches it through the staged loader.
- Build/reproduce the ARM GNU artifacts through the current linux-builder path (`PIXEL_GUEST_BUILD_SYSTEM=aarch64-linux` / `aarch64-linux` flake packages).
- First dynamic shell run proved a GPU shell/home frame, but app-frame exit initially stopped on the home frame. The compositor now defers `exitOnFirstFrame` until the shell-started app has produced the presented frame.
- `/metadata` filled up with old boot-token artifacts and Android root could not delete the boot-created unlabeled directories under SELinux. The boot image builder now has an explicit lab option, `--orange-gpu-metadata-prune-token-root true`, so owned PID1 can reclaim the proof area before writing a fresh token.
- Hardware proof on `06241JEC200520`: `build/pixel/runs/boot-shell-session/ss-appframe-metrics-r1-20260424014239/device-run/recover-traces-rerun/status.json` proved the shell log path for `counter`; recovery now also requires the captured frame to match the app-specific frame fingerprint before `proof_ok=true`.
- Hardware proof on `06241JEC200520`: `build/pixel/runs/boot-shell-session/ss-touch-counter-r4-20260424033300/device-run/recover-traces/status.json` proved `shell-session-runtime-touch-counter` with GPU shell, shell-launched TypeScript `counter`, synthetic compositor tap gated on the counter app frame, runtime counter increment, successful post-touch present, and a recovered post-touch shell frame fingerprint. Physical-touch hardware proof is still pending.
- `payload-partition-first-probe` is worker-2-owned for now. Do not duplicate that lane here; consume it once it lands if ramdisk/payload size or staging fragility returns.
