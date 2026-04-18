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
- Keep experimental boot tooling private until it proves itself on-device. Do not wire it into `shadowctl` or the public `just` surface early.
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
- [ ] Pick the first automatic takeover trigger.
- [ ] Pick the first phase-1 payload layout:
  - boot-critical pieces in ramdisk
  - large runtime bundles still allowed on `/data`
- [ ] Add a device-side log capture path for wrapper, init, and Shadow boot markers.
- [ ] Prove one tiny Shadow-at-boot lane before reintroducing timeline, camera, or network-heavy cases.
- [ ] Keep the next chunks separately landable:
  - guardrails and rollback polish
  - log capture and inspection
  - init import / boot helper trigger
  - automatic takeover

## Implementation Notes

- `sunfish` boots from `boot.img`, boot header v2, with recovery-as-boot. The old Cuttlefish `init_boot` work is a reference, not the real device path.
- The repo already has a usable host-side `bootimg` shell with `unpack_bootimg`, `mkbootimg`, and `avbtool`.
- The new private boot helpers live under `scripts/pixel/`: `pixel_boot_unpack.sh`, `pixel_boot_build.sh`, `pixel_boot_flash.sh`, `pixel_boot_restore.sh`, and `pixel_build_init_wrapper.sh`.
- The ramdisk patch step is back in repo-local form via `scripts/lib/cpio_edit.py`, and the minimal wrapper is a static aarch64 Rust binary at `rust/init-wrapper`.
- The cached stock `boot.img` can now be unpacked, wrapped, and reflashed locally. Live device validation still remains before the flash-loop milestone can flip fully green.
- The current rooted takeover path is already close to the desired runtime surface: it waits for DRM, stops Android display services, and launches `shadow-session`.
- Phase 1 should build on stock `boot.img`, not the Magisk-patched image. Magisk already rewrites init flow and adds avoidable complexity.
- Stock init still owns the hardest early responsibilities: first-stage mounts, `ueventd`, kernel modules, `/data` decryption, and service labelling.
- The new flash and rollback scripts intentionally target stock-init images, not Magisk-patched ones. After those scripts reboot successfully, ADB should come back but Magisk root should not.
- `pixel_boot_flash.sh` now requires `--experimental`, defaults to `--slot inactive`, refuses to touch the running slot unless `--allow-active-slot` is also passed, and supports `--dry-run` plus optional target-slot activation.
- `pixel_boot_restore.sh` now requires an explicit `--slot current|inactive|a|b` so recovery never silently overwrites whichever slot happens to be convenient.
- `scripts/ci/pixel_boot_safety_smoke.sh` locks the current safety contract into `just pre-commit`.
- Because stock-init experimental flashes can disrupt the working rooted lane on the same slot, future chunks should bias toward safety rails before convenience or public surfacing.
- Landing rule for this project: each chunk should be truthful, green, and mergeable on its own, so other worktrees can keep rebasing on `master` instead of waiting for a giant boot branch to finish.
- Camera remains Android-bound today. Wi-Fi likely does too. Do not make them blockers for the first Shadow-at-boot milestone.
- Next seam: use the guarded inactive-slot flow on a real device, prove the current Magisk lane survives the staging path, then add the first `init` import / boot helper trigger after stock init has mounted `/data`.
