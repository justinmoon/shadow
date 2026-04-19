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
- [~] Bisect the current ramdisk/init mutations on flashed active-slot images:
  - stock boot, cmdline-only edits, and minimal repacks already boot on `11151JEC200472`
  - stock-init log-probe images now also boot on `11151JEC200472`, so the wrapper is the remaining hard-boot suspect
  - property-only stock-init rc-probe images now also boot on real hardware without surfacing the proof property
  - live-device inspection now shows the ramdisk-patched `system/etc/init/hw/init.rc` is masked by the mounted system partition during normal boot, and `/init.shadow.rc` is absent on the live rootfs
  - the next discriminating seam is a minimal `/init`-owned proof again, not more stock-init rc patch-target churn
- [ ] Prove one tiny Shadow-at-boot lane before reintroducing timeline, camera, or network-heavy cases.
- [ ] Keep the next chunks separately landable:
  - guarded on-device log-probe validation
  - automatic takeover using the same imported boot-helper seam
  - service-stop tightening and `shadow-session` launch

## Implementation Notes

- `sunfish` boots from `boot.img`, boot header v2, with recovery-as-boot. The old Cuttlefish `init_boot` work is a reference, not the real device path.
- The repo already has a usable host-side `bootimg` shell with `unpack_bootimg`, `mkbootimg`, and `avbtool`.
- The new private boot helpers live under `scripts/pixel/`: `pixel_boot_unpack.sh`, `pixel_boot_build.sh`, `pixel_boot_build_log_probe.sh`, `pixel_boot_collect_logs.sh`, `pixel_boot_flash.sh`, `pixel_boot_restore.sh`, and `pixel_build_init_wrapper.sh`.
- The wrapper seam now also has a separate static C build path: `scripts/pixel/pixel_build_init_wrapper_c.sh` builds a minimal `/init.stock` handoff binary that stays out of the default Rust wrapper cache and plugs into `pixel_boot_build.sh --wrapper`.
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
- Fundroid prior art is useful mainly as tooling guidance, not as a proof that Pixel 4a boot bring-up already worked there:
  - keep deriving mkbootimg arguments and AVB footer inputs from the stock image rather than copying hardcoded demo metadata
  - keep ramdisk mutation surgical through cpio entry editing so device nodes and other special archive entries survive unchanged
  - prefer direct `execv()` handoff to the stock init path, plus `/dev/kmsg` breadcrumbs, over extra shell or symlink indirection when probing a foreign first-stage wrapper
  - treat Fundroid's successful boot/init results as mostly Cuttlefish-host evidence; the Pixel 4a material there is a plan, not completed hardware proof
- `scripts/ci/pixel_boot_collect_logs_smoke.sh` now locks the collector's success-vs-wrapper-only fallback semantics into `pre-commit`.
- The shared cross-worktree cache is intentionally narrow: only the immutable stock `boot.img` falls back through the git common-dir at `build/shared/pixel/root/boot.img`. Custom boot images, run bundles, and `last-action.json` stay worktree-local.
- `sc -t <serial> debug boot-lab-oneshot` now stays as a thin private delegator into `scripts/pixel/pixel_boot_oneshot.sh` for the fast `fastboot boot` plus collect loop. It does not change the public `just` surface.
- `pixel_boot_oneshot.sh` writes a run bundle under `build/pixel/boot/oneshot/<timestamp>/` with a local `boot-action.json`, collector output, and a truthful `status.json`.
- `sc -t <serial> debug boot-lab-flash-run` now stays as the flashed-slot counterpart: it composes guarded flash, automatic target-slot activation, log collection, and optional inactive-slot recovery into one private run bundle.
- `pixel_boot_flash.sh` now accepts `PIXEL_BOOT_METADATA_PATH`, so higher-level private runners can keep flash metadata inside a per-run bundle instead of clobbering the worktree-local default.
- `scripts/ci/pixel_boot_tooling_smoke.sh` now locks the shared-stock-boot plus oneshot and flash-run dry-run contracts into `pre-commit`, and `scripts/ci/operator_cli_smoke.sh` covers both `shadowctl` delegation paths.
- Tooling rule for later seams: prefer operator-grade helpers when they remove repeated manual steps, but keep them private, narrow, and evidence-first. Avoid “tooling” that merely hides uncertainty or bundles unrelated experiments together.
- `rust/init-wrapper/Cargo.toml` is now standalone enough for `cargo check --manifest-path rust/init-wrapper/Cargo.toml`, and `just pre-commit` now compiles that crate directly instead of only relying on host-side boot-image builds.
- The private wrapper seam now has two build flavors: the default wrapper still writes markers and restores `/init`, while `pixel_boot_build.sh --wrapper-mode minimal` builds `shadow-boot-wrapper-minimal.img` with a wrapper that directly `execv`s `/init.stock` using `/init` as `argv[0]`.
- The minimal wrapper build path now enforces mode-tagged binaries, rejects cross-mode cache-path mistakes, and still leaves a `shadow-init` kmsg breadcrumb so later on-device collection can tell whether the wrapper reached userspace at all.
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
- New flashed active-slot matrix result on 2026-04-18 (`11151JEC200472`, slot `a`):
  - flashing the stock baseline image booted Android successfully
  - flashing a cmdline-only modified image booted Android successfully and surfaced `ro.boot.shadow_probe=flash-matrix-20260418T215506Z`
  - flashing a minimal repack with the stock ramdisk booted Android successfully
  - flashing the current `shadow-boot-log-probe.img` failed back into fastboot; restoring stock `boot_a` recovered the phone
- Working inference from that matrix: the flashed active-slot path itself is real on `sunfish`; the failing delta is now inside our ramdisk/init mutations, not generic repacking, AVB footer reapplication, or slot activation.
- The stock-init builder path is now real in repo-local tooling: `pixel_boot_build.sh --stock-init` keeps stock `/init` while still applying ramdisk `--add` / `--replace` overlays, and `pixel_boot_build_log_probe.sh --stock-init` reuses that seam for stock-init helper probes.
- The property-proof path is now real in repo-local tooling too: `pixel_boot_build_rc_probe.sh --stock-init` builds an imported-rc image that only sets a transient `shadow.boot.*` property, and the boot-lab runners / collector now accept `--proof-prop KEY=VALUE` so a live non-persistent property can count as success without `/data/local/tmp/shadow-boot`.
- New hardware result on 2026-04-18 from that stock-init seam:
  - flashing `shadow-boot-log-probe-stock-init.img` to active slot `a` on `11151JEC200472` booted Android successfully on slot `a`
  - a one-shot boot of the same stock-init log-probe image on `09051JEC202061` also reached Android on slot `b`
  - neither run produced `/data/local/tmp/shadow-boot` or helper-ready evidence, so the rc/import/helper seam still lacks a positive userspace signal
- Working inference from the stock-init result: replacing `/init` is the remaining suspect for the hard boot failure, but the imported rc/helper path is still not proven even when stock init boots the image.
- New hardware result on 2026-04-18 from the property-only stock-init seam (`09051JEC202061`, slot `b`):
  - one-shot boot of `shadow-boot-rc-probe-stock-init.img` reached Android on slot `b`, but `shadow.boot.rc_probe` never appeared
  - flashed active-slot boot of the same image also reached Android on slot `b`, but `shadow.boot.rc_probe` still never appeared
  - both runs now leave truthful property-mode bundles, so the negative result is about the rc/import seam itself rather than missing helper-log plumbing
- Working inference from the property-only result: stock-init images still boot, but the current imported rc fragment is not executing in a way that surfaces either helper logs or a transient property. The wrapper remains a separate hard-boot suspect, but the next bottleneck is now rc patch-target / trigger choice.
- Follow-up fact from the same line of work: `shadow.boot.rc_probe` is not a safe proof namespace on this device for shell-driven checks, while `debug.shadow.boot.rc_probe` is settable manually. That tightened the proof mechanism, but it did not change the boot result.
- New hardware result on 2026-04-18 from the forced `system/etc/init/hw/init.rc` debug-property seam (`09051JEC202061`, slot `b`):
  - flashing `shadow-boot-rc-probe-stock-init-system-initrc-debugprop.img` to active slot `b` still booted Android successfully on slot `b`
  - there was still no helper dir, no wrapper markers, and no `debug.shadow.boot.rc_probe`
  - the live booted device showed stock `/system/etc/init/hw/init.rc` contents with no `import /init.shadow.rc`
  - `/init.shadow.rc` was absent on the live rootfs after boot
- Working inference from that live-device check: ramdisk-side rc patching of `system/etc/init/hw/init.rc` and the recovery rc files is not in the normal `sunfish` boot init graph once the system partition is mounted. Continuing to vary stock-init rc patch targets is low-value churn.
- Follow-up hardware result on 2026-04-18 from the explicit `init.recovery.sunfish.rc` debug-property seam (`09051JEC202061`, slot `b`):
  - flashing `shadow-boot-rc-probe-stock-init-recovery-debugprop.img` to active slot `b` still booted Android successfully on slot `b`
  - there was still no helper dir, no wrapper markers, and no `debug.shadow.boot.rc_probe`
  - so both current ramdisk rc import anchors now fail to surface any live proof on flashed normal boots
- Tightened inference after both rc-anchor checks: the imported stock-init rc strategy is effectively exhausted for normal `sunfish` boots. Further rc-target or trigger churn is unlikely to teach us more than a direct `/init` seam.
- New hardware result on 2026-04-19 from the minimal wrapper seam (`09051JEC202061`, inactive slot `a`):
  - flashing `shadow-boot-wrapper-minimal.img` to inactive slot `a` and activating it did not produce a successful boot on `a`
  - the device recovered back to Android on slot `b`, with `sys.boot_completed=1` on the known-good slot
  - the minimal wrapper removed the old marker/rename choreography, so the failure now points at the wrapper seam itself rather than the extra bookkeeping layered on top of it
- Follow-up hardware result on 2026-04-19 from the tiny static C wrapper seam (`09051JEC202061`, inactive slot `a`):
  - flashing `shadow-boot-wrapper-c-minimal.img` to inactive slot `a` triggered the yellow corrupt-device warning instead of reaching Android
  - the guarded runner did not see `adb` or `fastboot` on its own after the failure, so host-side recovery needed manual fastboot entry before it could restore stock `boot_a`
  - after recovery, the device booted Android successfully on slot `b`, with `sys.boot_completed=1`
- Tightened inference after both minimal wrapper tests: the failure is not Rust-specific and likely not about wrapper bookkeeping. On this device, a foreign PID 1 that later `execv()`s `/init.stock` is probably not a valid stand-in for stock `/init`.
- Next discriminating seam: keep stock Android init as the kernel-launched `/init` path and test a path-preserving ramdisk mutation instead of another foreign-PID1 wrapper variant.
- Candidate landable tool seam for that probe: add a dedicated private builder that renames the stock ramdisk `init` to `init.stock`, reintroduces `init` as a symlink or equivalent path-preserving shim to `init.stock`, and reuses the existing guarded flash/collect tooling on `09051JEC202061`.
- Follow-up fact from the same line of work on 2026-04-19:
  - the stock ramdisk already ships `init` as a symlink to `/system/bin/init`
  - the ramdisk also contains the real `system/bin/init` ELF, so the device does not boot a root-level regular-file `/init` today
- New hardware result on 2026-04-19 from the path-preserving symlink probe (`09051JEC202061`, inactive slot `a`):
  - flashing `shadow-boot-init-symlink-probe.img` to inactive slot `a` and activating it did not reach Android on `a`
  - after the yellow corrupt-device warning was acknowledged, the phone hung at the `Google` screen with no `adb` or `fastboot` visibility
  - forcing fastboot and restoring stock `boot_a` recovered the device; it booted Android successfully again on slot `b`, with `sys.boot_completed=1`
- Tightened inference after unpacking the stock ramdisk and running the symlink probe: changing `/init` from the stock one-hop symlink (`/init -> /system/bin/init`) into a two-hop chain (`/init -> /init.stock -> /system/bin/init`) is already enough to break `sunfish` boot. So the next seam should preserve the stock `/init` link itself and move one level deeper, likely around `system/bin/init` rather than root-path aliasing.
- Current probe plan after that result: keep `/init -> /system/bin/init` exactly as stock, then test whether a deeper `system/bin/init -> init.stock` hop is tolerated before trying any new foreign-PID1 handoff at that path.
- New hardware result on 2026-04-19 from the deeper `system/bin/init` symlink probe (`09051JEC202061`, inactive slot `a`):
  - flashing `shadow-boot-system-init-symlink-probe.img` to inactive slot `a` and activating it also failed to reach Android on `a`
  - the guarded runner again saw no `adb` or `fastboot` on its own before timing out
  - once the phone was pushed into fastboot, the host restored stock `boot_a`, switched back to slot `b`, and the device booted Android successfully again with `sys.boot_completed=1`
- Tightened inference after the deeper probe: preserving the stock root `/init -> /system/bin/init` link is still not enough if `system/bin/init` itself becomes a symlink hop to `system/bin/init.stock`. So the current device constraint is stricter than “keep `/init` special”; even a symlink indirection at the real first-stage init path appears to break `sunfish` boot.
- Truthfulness rule for the new boot-lab runners: top-level `status.json` and process exit codes must stay aligned with the underlying flash/collect result; false-success wrapper statuses are not acceptable evidence.
- Because stock-init experimental flashes can disrupt the working rooted lane on the same slot, future chunks should bias toward safety rails before convenience or public surfacing.
- Landing rule for this project: each chunk should be truthful, green, and mergeable on its own, so other worktrees can keep rebasing on `master` instead of waiting for a giant boot branch to finish.
- Camera remains Android-bound today. Wi-Fi likely does too. Do not make them blockers for the first Shadow-at-boot milestone.
- New hardware result on 2026-04-19 from the exact-path `system/bin/init` wrapper seam (`09051JEC202061`, inactive slot `a`):
  - flashing `shadow-boot-system-init-wrapper-probe.img` to inactive slot `a` and activating it did not return to Android on `a`
  - the guarded flash-run saw the slot flash and reboot succeed, but no `adb` or `fastboot` visibility came back before timeout, so automatic recovery did not complete on its own
  - manual recovery back to stock `boot_a` restored the device, and it booted Android successfully again on slot `_b` with `sys.boot_completed=1`
- Tightened inference after the exact-path wrapper probe: even when both visible init paths stay exact (`/init -> /system/bin/init`, real wrapper binary installed at `system/bin/init`, stock binary moved to `system/bin/init.stock`), a foreign first-stage PID 1 that later `execv()`s the stock init path still appears to break normal `sunfish` boot. That pushes the next seam away from wrapper handoff variants and toward mechanisms that leave stock first-stage init itself in control.
- Next seam: stop replacing init binaries entirely and probe a stock-init-owned hook point such as bootconfig/cmdline-triggered behavior, first-stage-visible imported config that stock init already consumes, or an even narrower binary patch that preserves the stock init image shape instead of swapping in a new ELF.
