# Boot Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

Related docs:

- [spec-scope.md](./spec-scope.md)
- [spec-phase1-shadow-at-boot.md](./spec-phase1-shadow-at-boot.md)

## Scope

- Boot a Pixel 4a (`sunfish`) into Shadow from a custom `boot.img`.
- Treat ownership as "from `boot.img` and ramdisk upward" on unlocked hardware.
- Keep the current shell/home/app experience as the first product target.
- Use stock kernel and vendor pieces at first. Do not start by replacing the whole Android distro.
- Keep the current Magisk/rooted takeover lane usable for normal development while the new boot lane iterates in parallel.

## Approach

- Keep the physical Pixel 4a as the truth environment for boot work.
- Use host-side `bootimg` tooling for the inner loop: unpack, patch, repack, inspect, sign.
- Use Cuttlefish only for Android-generic `init` or `rc` experiments, not as the primary model for `sunfish`.
- Keep Android `init` in the loop for phase 1 so mounts, `ueventd`, module loading, and encrypted `/data` keep working.
- Reuse the current rooted takeover/runtime path first, then tighten the boot graph later.
- Land boot work in small seams that can merge to `master` independently; do not stack the whole project on one long-lived boot branch.
- Use a dedicated worktree branch per risky seam, then land or checkpoint before starting the next one.
- Keep experimental boot tooling private until it proves itself on-device. Private delegators may live under `shadowctl debug`, but do not promote boot-lab flows into the public `just` surface early.
- When a boot experiment loop repeats or burns operator time twice, bias toward small private tools that capture the loop truthfully: shared immutable inputs, structured run bundles, explicit safety rails, and thin `shadowctl debug` delegation instead of more handwritten terminal choreography.
- Prefer chunks that are inert for the current Magisk path: helper libraries, private scripts, log capture, guardrails, and wrapper-only boot images before automatic takeover changes.

## Milestones

- [x] Confirm the real `sunfish` boot seam and round-trip the stock `boot.img` with repo-local tooling.
- [~] Recreate a safe custom `boot.img` flash loop on-device with clear rollback steps.
- [~] Restore a minimal `/init` wrapper that logs, preserves `/init.stock`, and chainloads stock init.
- [ ] Inject a Shadow init fragment that launches automatic boot takeover with no manual `adb` or `su` step.
- [ ] Boot directly into Shadow shell/home on a physical Pixel with no manual rooted takeover after boot.
- [ ] Reduce or eliminate the first-boot dependence on pre-staged `/data/local/tmp` runtime artifacts.
- [ ] Decide the long-lived subsystem strategy for camera, Wi-Fi, and update/recovery.

## Near-Term Steps

- [x] Add repo-local scripts for `sunfish` boot unpack/repack and ramdisk patching.
- [x] Restore or rewrite the old deleted `init-wrapper` flow from `08b0b1b^` for `boot.img` instead of `init_boot.img`.
- [x] Add explicit flash guardrails so experimental boot images do not accidentally clobber the working Magisk development lane.
- [~] Add a safe on-device validation shape:
  - prefer inactive-slot or otherwise isolated flashing when possible
  - keep rollback obvious and scripted
- [x] Pick the first automatic takeover trigger.
- [ ] Pick the first phase-1 payload layout:
  - boot-critical pieces in ramdisk
  - large runtime bundles still allowed on `/data`
- [x] Add a device-side log capture path for wrapper, init, and Shadow boot markers.
- [x] Add worktree-friendly boot-lab tooling:
  - shared stock `boot.img` fallback across worktrees
  - one-shot `fastboot boot` orchestration with structured host-side evidence capture
- [~] Validate the log-probe boot helper on-device through the guarded inactive-slot flow and pull the first collected logs.
- [ ] Prove one tiny Shadow-at-boot lane before reintroducing timeline, camera, or network-heavy cases.
- [ ] Keep the next chunks separately landable:
  - guarded on-device log-probe validation
  - automatic takeover using the same imported boot-helper seam
  - service-stop tightening and `shadow-session` launch

## Implementation Notes

- `sunfish` boots from `boot.img`, boot header v2, with recovery-as-boot. The old Cuttlefish `init_boot` work is a reference, not the real device path.
- The repo already has a usable host-side `bootimg` shell with `unpack_bootimg`, `mkbootimg`, and `avbtool`.
- The new private boot helpers live under `scripts/pixel/`: `pixel_boot_unpack.sh`, `pixel_boot_build.sh`, `pixel_boot_build_log_probe.sh`, `pixel_boot_collect_logs.sh`, `pixel_boot_flash.sh`, `pixel_boot_restore.sh`, and `pixel_build_init_wrapper.sh`.
- `pixel_boot_build.sh` now accepts additive ramdisk `--add` and `--replace` overlays so later boot seams can reuse one wrapper/repack path instead of cloning it.
- `pixel_boot_build_log_probe.sh` now injects `/init.shadow.rc`, patches `system/etc/init/hw/init.rc`, and adds a log-only `/shadow-boot-helper` triggered from `post-fs-data`.
- `pixel_boot_collect_logs.sh` now pulls `/data/local/tmp/shadow-boot` plus host-visible `logcat`/`getprop` snapshots into `build/pixel/boot/logs/<timestamp>/`.
- The log-probe seam now prefers a root recovery rc import anchor when one exists in the ramdisk, falling back to `system/etc/init/hw/init.rc` only when recovery rc is unavailable. On current `sunfish` stock images that resolves to `init.recovery.sunfish.rc`.
- The init wrapper now drops persistent stage markers under `/.shadow-init-wrapper/` so later userspace collection can prove whether the wrapper ran even if early stdout or `/dev/kmsg` logs are lost.
- `pixel_boot_collect_logs.sh` now gathers those wrapper markers best-effort and records wrapper-only evidence in `status.json` without treating that as a full helper success.
- Collector success now also requires a successful pull of the helper log root; partial helper pulls and wrapper-only evidence stay non-successful by design.
- The collector's timeout path now keeps writing `status.json` even if later `adb shell getprop` / `logcat` / `ps` calls fail, so slow or degraded boots still leave a truthful artifact bundle behind.
- The ramdisk patch step is back in repo-local form via `scripts/lib/cpio_edit.py`, and the minimal wrapper is a static aarch64 Rust binary at `rust/init-wrapper`.
- `scripts/lib/cpio_edit.py` now supports entry extraction as well as add/replace/rename, and `scripts/ci/cpio_edit_smoke.sh` keeps those semantics covered in `pre-commit`.
- `scripts/ci/pixel_boot_collect_logs_smoke.sh` now locks the collector's success-vs-wrapper-only fallback semantics into `pre-commit`.
- The shared cross-worktree cache is intentionally narrow: only the immutable stock `boot.img` falls back through the git common-dir at `build/shared/pixel/root/boot.img`. Custom boot images, run bundles, and `last-action.json` stay worktree-local.
- `sc -t <serial> debug boot-lab-oneshot` now stays as a thin private delegator into `scripts/pixel/pixel_boot_oneshot.sh` for the fast `fastboot boot` plus collect loop. It does not change the public `just` surface.
- `pixel_boot_oneshot.sh` writes a run bundle under `build/pixel/boot/oneshot/<timestamp>/` with a local `boot-action.json`, collector output, and a truthful `status.json`.
- `scripts/ci/pixel_boot_tooling_smoke.sh` now locks the shared-stock-boot and oneshot dry-run contracts into `pre-commit`, and `scripts/ci/operator_cli_smoke.sh` covers the `shadowctl` delegation path.
- Tooling rule for later seams: prefer operator-grade helpers when they remove repeated manual steps, but keep them private, narrow, and evidence-first. Avoid “tooling” that merely hides uncertainty or bundles unrelated experiments together.
- `rust/init-wrapper/Cargo.toml` is now standalone enough for `cargo check --manifest-path rust/init-wrapper/Cargo.toml`, and `just pre-commit` now compiles that crate directly instead of only relying on host-side boot-image builds.
- The cached stock `boot.img` can now be unpacked, wrapped, and reflashed locally. Live device validation still remains before the flash-loop milestone can flip fully green.
- The first imported boot-helper trigger is `post-fs-data`, wired through `system/etc/init/hw/init.rc` in the recovery-as-boot ramdisk. This is intentionally a log-only probe before any automatic takeover steps.
- The current rooted takeover path is already close to the desired runtime surface: it waits for DRM, stops Android display services, and launches `shadow-session`.
- Phase 1 should build on stock `boot.img`, not the Magisk-patched image. Magisk already rewrites init flow and adds avoidable complexity.
- Stock init still owns the hardest early responsibilities: first-stage mounts, `ueventd`, kernel modules, `/data` decryption, and service labelling.
- The new flash and rollback scripts intentionally target stock-init images, not Magisk-patched ones. After those scripts reboot successfully, ADB should come back but Magisk root should not.
- `pixel_boot_flash.sh` now requires `--experimental`, defaults to `--slot inactive`, refuses to touch the running slot unless `--allow-active-slot` is also passed, and supports `--dry-run` plus optional target-slot activation.
- `pixel_boot_restore.sh` now requires an explicit `--slot current|inactive|a|b` so recovery never silently overwrites whichever slot happens to be convenient.
- `scripts/ci/pixel_boot_safety_smoke.sh` locks the current safety contract into `just pre-commit`.
- `bootimg_unpack_to_dir()` now resolves the input path before `cd` so host inspection scripts work with relative image paths too.
- Hardware result on 2026-04-18:
  - inactive-slot activation on `11151JEC200472` (`a -> b`) returned to slot `a` with no probe logs
  - inactive-slot activation on `09051JEC202061` (`b -> a`) returned to slot `b` with no probe logs
  - active-slot flash on `11151JEC200472` produced fastboot `Enter reason: no valid slot to boot` on slot `a`
  - restoring stock `boot_a` from fastboot recovered the phone, but Magisk/root on that slot is now gone until it is patched again
- Current conclusion: the host-side probe tooling and rollback path are real, but the current custom boot image is not yet a successful on-device boot path on physical `sunfish`.
- New probe result on 2026-04-18: a one-shot `fastboot boot` image with only an added `androidboot.shadow_probe=<tag>` cmdline token surfaced `ro.boot.shadow_probe=<tag>` on both `11151JEC200472` and `09051JEC202061`. So the passed boot image is definitely being used for header/cmdline state.
- But the same session also showed no signal from any ramdisk-side experiment on either phone:
  - no wrapper markers from the landed wrapper probe
  - no helper logs from the landed imported-rc probe
  - no `shadow.boot.rc_only_probe` property from an rc-only probe that left stock `/init` untouched
  - no `shadow.boot.rc_file` property even when directly prepending `setprop` to existing `init.recovery.sunfish.rc` or `system/etc/init/hw/init.rc`
- Working inference: on current `sunfish`, `fastboot boot` is a truthful loop for boot-image header/cmdline experiments, but not a trustworthy loop for our ramdisk-side validation. Treat negative ramdisk results from one-shot boots as non-decisive and shift the next seam back toward flashed-image validity / AVB-footer work.
- Because stock-init experimental flashes can disrupt the working rooted lane on the same slot, future chunks should bias toward safety rails before convenience or public surfacing.
- Landing rule for this project: each chunk should be truthful, green, and mergeable on its own, so other worktrees can keep rebasing on `master` instead of waiting for a giant boot branch to finish.
- Camera remains Android-bound today. Wi-Fi likely does too. Do not make them blockers for the first Shadow-at-boot milestone.
- Next seam: use the new cmdline-proof result to narrow the flashed-image validity path. The fast loop should now focus on why slot-flashed images are rejected or fall back even though `fastboot boot` clearly honors modified boot-image cmdline state.
