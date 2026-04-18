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

## Approach

- Keep the physical Pixel 4a as the truth environment for boot work.
- Use host-side `bootimg` tooling for the inner loop: unpack, patch, repack, inspect, sign.
- Use Cuttlefish only for Android-generic `init` or `rc` experiments, not as the primary model for `sunfish`.
- Keep Android `init` in the loop for phase 1 so mounts, `ueventd`, module loading, and encrypted `/data` keep working.
- Reuse the current rooted takeover/runtime path first, then tighten the boot graph later.

## Milestones

- [x] Confirm the real `sunfish` boot seam and round-trip the stock `boot.img` with repo-local tooling.
- [ ] Recreate a safe custom `boot.img` flash loop on-device with clear rollback steps.
- [ ] Restore a minimal `/init` wrapper that logs, preserves `/init.stock`, and chainloads stock init.
- [ ] Inject a Shadow init fragment that launches automatic boot takeover with no manual `adb` or `su` step.
- [ ] Boot directly into Shadow shell/home on a physical Pixel with no manual rooted takeover after boot.
- [ ] Reduce or eliminate the first-boot dependence on pre-staged `/data/local/tmp` runtime artifacts.
- [ ] Decide the long-lived subsystem strategy for camera, Wi-Fi, and update/recovery.

## Near-Term Steps

- [ ] Add repo-local scripts for `sunfish` boot unpack/repack and ramdisk patching.
- [ ] Restore or rewrite the old deleted `init-wrapper` flow from `08b0b1b^` for `boot.img` instead of `init_boot.img`.
- [ ] Pick the first automatic takeover trigger.
- [ ] Pick the first phase-1 payload layout:
  - boot-critical pieces in ramdisk
  - large runtime bundles still allowed on `/data`
- [ ] Add a device-side log capture path for wrapper, init, and Shadow boot markers.
- [ ] Prove one tiny Shadow-at-boot lane before reintroducing timeline, camera, or network-heavy cases.

## Implementation Notes

- `sunfish` boots from `boot.img`, boot header v2, with recovery-as-boot. The old Cuttlefish `init_boot` work is a reference, not the real device path.
- The repo already has a usable host-side `bootimg` shell with `unpack_bootimg`, `mkbootimg`, and `avbtool`.
- The cached stock `boot.img` can be unpacked and repacked locally. This is a script gap now, not a toolchain gap.
- The current rooted takeover path is already close to the desired runtime surface: it waits for DRM, stops Android display services, and launches `shadow-session`.
- Phase 1 should build on stock `boot.img`, not the Magisk-patched image. Magisk already rewrites init flow and adds avoidable complexity.
- Stock init still owns the hardest early responsibilities: first-stage mounts, `ueventd`, kernel modules, `/data` decryption, and service labelling.
- Camera remains Android-bound today. Wi-Fi likely does too. Do not make them blockers for the first Shadow-at-boot milestone.
- Next seam: land repo-local `sunfish` boot-image scripts and a first wrapper that only logs and chainloads.
