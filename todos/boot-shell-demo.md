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

- Continue from current `master` on branch `boot-full-shadow-demo` in `worker-1`.
- Reuse the proven app-direct-present bundle machinery, but add a product shell-session boot mode.
- Prefer `counter` for the first shell-launched TypeScript app because it avoids network/service dependencies.
- Preserve the metadata/recover-traces truth surface and add shell-specific readiness fields.
- Treat the landed `/metadata/shadow-payload/by-token/<run_token>` probe as a small control/proof surface only; it is not large enough for product shell/session payloads.
- Do not prototype runtime payload delivery on `/metadata`; it is about 10 MB and only useful for manifests, breadcrumbs, and recovered proof.
- Consume worker-2's larger payload partition once it lands; until then keep behavior work on the current ramdisk path and keep payload-size-sensitive changes isolated.

## Steps

- [x] Define boot-owned shell startup artifact and staging shape.
- [x] Add shell-session boot mode and host smoke coverage.
- [x] Build and run first shell-home frame proof on a Pixel.
- [x] Add shell-start-app proof for TypeScript `counter`.
- [x] Fold in synthetic runtime touch proof for shell-launched TypeScript `counter`.
- [x] Keep the current ramdisk shell-session bundle working while worker-2 brings up the larger payload partition.
- [x] Move the shell-session runtime bundle onto the larger payload partition once that lands; do not use `/metadata` as the intermediate payload store.
- [x] Add persistent/held shell mode with a clear recovery path.
- [x] Add broader app coverage from the shell: TypeScript `timeline` and Rust `rust-demo` both have hardware proof from the shell path.
- [ ] Fold in manual/real touch plumbing from `worker-2` if it helps interaction.
- [x] Confirm the larger-partition-backed shell/app path on hardware and record proof artifacts.

## Implementation Notes

- `worker-2` has useful manual touch work: `/dev/input/event2` bootstrap and non-synthetic touch config.
- The branch should not add more isolated app-direct rungs unless they directly unblock shell/app launch.
- Static musl `shadow-compositor-guest` could not load the Vulkan/ICD stack on device; shell-session now stages the dynamic `aarch64-linux-gnu` compositor and launches it through the staged loader.
- Build/reproduce the ARM GNU artifacts through the current linux-builder path (`PIXEL_GUEST_BUILD_SYSTEM=aarch64-linux` / `aarch64-linux` flake packages).
- First dynamic shell run proved a GPU shell/home frame, but app-frame exit initially stopped on the home frame. The compositor now defers `exitOnFirstFrame` until the shell-started app has produced the presented frame.
- `/metadata` filled up with old boot-token artifacts and Android root could not delete the boot-created unlabeled directories under SELinux. The boot image builder now has an explicit lab option, `--orange-gpu-metadata-prune-token-root true`, so owned PID1 can reclaim the proof area before writing a fresh token.
- Hardware proof on `06241JEC200520`: `build/pixel/runs/boot-shell-session/ss-appframe-metrics-r1-20260424014239/device-run/recover-traces-rerun/status.json` proved the shell log path for `counter`; recovery now also requires the captured frame to match the app-specific frame fingerprint before `proof_ok=true`.
- Hardware proof on `06241JEC200520`: `build/pixel/runs/boot-shell-session/ss-touch-counter-r4-20260424033300/device-run/recover-traces/status.json` proved `shell-session-runtime-touch-counter` with GPU shell, shell-launched TypeScript `counter`, synthetic compositor tap gated on the counter app frame, runtime counter increment, successful post-touch present, and a recovered post-touch shell frame fingerprint. Physical-touch hardware proof is still pending.
- `payload-partition-first-probe` landed on master as a metadata-backed manifest probe, but `/metadata` is only about 10 MB. Use it for breadcrumbs/manifests/proof, not for the real runtime/compositor/app bundle. Worker-2 owns the larger new-partition lane; consume that when available.
- `shell-session` can now stage and launch Rust `rust-demo` through the shell path. The touch-counter shell proof stays TypeScript-only because its evidence contract is tied to hosted runtime counter events.
- `shell-session` now has host/recovery proof coverage for non-counter TypeScript `timeline` as well as `counter`, so the shell app path is no longer counter-only at the script/proof-contract layer.
- Hardware proof on `06241JEC200520`: `build/pixel/runs/boot-shell-session/ss-held-r1-20260424042557/device-run/recover-traces/status.json` proved `shell-session-held` with GPU shell, shell-launched TypeScript `counter`, durable app-frame metadata, `probe_report_proves_child_timeout=true`, `probe_summary_proves_shell_session_held=true`, and `metadata_compositor_frame_proves_shell_session_app=true`. The generic one-shot helper collection timed out, but recovered metadata proof was `proof_ok=true` and the device returned to rooted Android.
- Hardware proof on `06241JEC200520`: `build/pixel/runs/boot-shell-session/ss-timeline-r3-20260424050459/device-run/recover-traces-rerun/status.json` proved `shell-session` with GPU shell, shell-launched TypeScript `timeline`, GPU TypeScript renderer, durable app-frame metadata, shell session summary, and app-specific frame colors. The timeline app now includes simple hex background fallbacks so the boot renderer does not fall through transparent when it ignores gradient backgrounds.
- Earlier Rust finding on `06241JEC200520`: `build/pixel/runs/boot-shell-session/ss-rust-demo-r1-20260424043704/device-run/recover-traces/status.json` launched Rust `rust-demo`, mapped and tracked the surface, and observed a committed app frame, but strict GPU-resident mode rejected the SHM app composition path at `VelloImageRenderer::render_to_vec`.
- The Rust app strict-GPU blocker is now cleared for the shell path: SHM app frames are imported as GPU image brushes and composited into the scanout dmabuf by Vello, so the shell no longer falls back to CPU readback/composition for Rust `rust-demo`.
- The shell/session builder now supports `--orange-gpu-bundle-archive-source shadow-logical-partition`: it keeps the Rust PID1 shim/config/firmware in the boot ramdisk, writes a sibling `orange-gpu.tar.xz` for host staging, points `orange_gpu_bundle_archive_path` at `/shadow-payload/extra-payloads/orange-gpu.tar.xz`, and Rust PID1 mounts the logical payload partition before expanding the compositor/runtime/app bundle into `/orange-gpu`.
- Hardware proof on `06241JEC200520`: `build/pixel/runs/boot-shell-session/ss-timeline-logical-r1-20260424052405/device-run/recover-traces/status.json` proved `shell-session` with GPU shell, shell-launched TypeScript `timeline`, GPU TypeScript renderer, and the compositor/runtime/app archive staged from `shadow_payload_a` instead of the ramdisk. Recovered proof was `proof_ok=true`, `probe_summary_proves_shell_session=true`, `metadata_compositor_frame_proves_shell_session_app=true`, and the archive staging output recorded `Payload source: shadow-logical-partition`, `Remote payload root: /shadow-payload`.
- Staging note: `scripts/pixel/pixel_boot_stage_metadata_payload.sh` now preserves its original argv across the host-lock re-exec. Without that, parsed `--source shadow-logical-partition` / `--extra-payload ...` options silently fell back to metadata defaults after taking the lock.
- Hardware proof on `06241JEC200520`: `build/pixel/runs/boot-shell-session/ss-rust-demo-logical-r2-20260424055521/device-run/recover-traces-after-proof-rule/status.json` proved `shell-session` with GPU shell, shell-launched Rust `rust-demo`, and the compositor/runtime/app archive staged from `shadow_payload_a`. Recovered proof was `proof_ok=true`, `probe_summary_proves_shell_session=true`, `metadata_probe_summary_shell_session_mapped_window=true`, `metadata_probe_summary_shell_session_app_frame_captured=true`, and `metadata_compositor_frame_proves_shell_session_app=true`. The report includes `shadow-rust-demo: frame_committed`, `buffer-observed type=shm`, `app_composite_ms=0`, and `presented-shell-dmabuf`; exact app-direct color samples are intentionally not required for this Rust shell-session proof because GPU image filtering can shift sampled colors.
- Hardware proof on `06241JEC200520`: `build/pixel/runs/boot-shell-session/ss-held-rust-logical-r1-20260424061149/device-run/recover-traces/status.json` proved the same logical-payload Rust shell app path in `shell-session-held` mode. The session stayed in boot-owned userspace until the 120s watchdog returned through fastboot after about 139s, then recovered `proof_ok=true`, `probe_summary_proves_shell_session_held=true`, `probe_report_proves_child_timeout=true`, `metadata_probe_timeout_class_bucket=generic-watchdog`, and `metadata_probe_stage_value=orange-gpu-payload:shell-session-held-watchdog-proved`.
- `--orange-gpu-timeout-action hold` is now supported for Rust PID1 held shell sessions. On watchdog proof it records the same held-session metadata but leaves the compositor/app child running for the configured `--hold-secs` observation window before the normal recovery reboot.
- Hardware proof on `06241JEC200520`: `build/pixel/runs/boot-shell-session/ss-held-rust-hold-logical-r1-20260424062746/device-run/recover-traces/status.json` proved the logical-payload Rust shell app with a 60s watchdog plus 60s live observation window. The device returned through fastboot after 138s, recovered `proof_ok=true`, `probe_summary_proves_shell_session_held=true`, `probe_report_proves_child_timeout=true`, and `metadata_probe_stage_value=orange-gpu-payload:shell-session-held-watchdog-proved`; recovered logs show `shadow-rust-demo: frame_committed`, `buffer-observed type=shm`, `app_composite_ms=0`, and `presented-shell-dmabuf`.
- Hardware proof on `06241JEC200520`: `build/pixel/runs/boot-shell-session/ss-touch-counter-logical-r1-20260424063926/device-run/recover-traces/status.json` proved logical-payload TypeScript interaction in `shell-session-runtime-touch-counter`: shell-launched `counter`, GPU TypeScript renderer, synthetic compositor touch dispatched, counter incremented, post-touch frame committed and captured, touch latency present, `metadata_compositor_frame_proves_shell_session_app=true`, and `proof_ok=true`.
- Hardware proof on `06241JEC200520`: `build/pixel/runs/boot-shell-session/ss-touch-input-logical-r1-20260424064945/device-run/recover-traces/status.json` repeated the logical-payload TypeScript interaction proof with sunfish touch bootstrapped from worker-2's touch modules and combined GPU/touch firmware. Rust PID1 created `/dev/input/event2`; the compositor logged `touch-ready device=/dev/input/event2 name=fts range=0..=1079x0..=2339`; recovered proof remained `proof_ok=true` with counter increment, post-touch frame capture, touch latency, and GPU dmabuf presentation.
