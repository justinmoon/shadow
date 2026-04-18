# Phase 1: Shadow At Boot

Status: draft

This spec defines the first shippable boot milestone. It is intentionally narrower than "replace Android."

## Objective

Boot a physical Pixel 4a from a custom `boot.img` and reach the existing Shadow shell/home automatically, with no manual rooted takeover after boot.

## Definition Of Done

- a custom `boot.img` flashes and boots on `sunfish`
- a custom ramdisk `/init` wrapper runs first and leaves a clear boot marker in `kmsg`
- stock Android init still completes enough early bring-up for `/data`, DRM, input, audio, and required vendor services
- a Shadow boot helper runs automatically during boot and performs the display takeover with no operator `adb` or `su` step
- `shadow-session` starts automatically and `shadow-compositor-guest` reaches:
  - `mode GuestUi`
  - `[shadow-guest-compositor] touch-ready`
  - `[shadow-guest-compositor] presented-frame`
- the device lands in Shadow shell/home by default
- recovery remains straightforward: flash a known-good boot image and reboot

## Explicit Non-Requirements

- no camera requirement
- no Wi-Fi requirement
- no attempt to suppress every Android service from the first boot
- no requirement to remove all `/data` dependencies yet
- no SELinux-enforcing requirement

## Allowed Simplifications

- SELinux may remain permissive if that is the shortest route to a stable boot
- runtime bundles may stay pre-staged under `/data/local/tmp/...` in phase 1
- brief Android framebuffer activity before takeover is acceptable
- the boot helper may reuse shell-based takeover logic before it is rewritten in Rust or cleaner init services

## Phase 1 Boot Flow

1. Bootloader loads a custom `boot.img`.
2. The custom ramdisk `/init` wrapper runs first.
3. The wrapper logs early boot markers, preserves a rollback path, restores `/init.stock`, and execs stock init.
4. Stock first-stage and second-stage init perform mounts, `ueventd` coldboot, module loading, and encrypted `/data` bring-up.
5. A Shadow init fragment launches a boot helper after the prerequisites for takeover are ready.
6. The boot helper performs the current rooted takeover steps automatically:
   - stop `surfaceflinger`
   - stop `bootanim`
   - stop hwcomposer and display allocator services as needed
   - relax SELinux if still required
   - ensure required runtime directories and env are present
7. The boot helper launches `shadow-session`.
8. `shadow-session` launches `shadow-compositor-guest` and the default shell app.

## Required Phase 1 Components

- a custom `sunfish` boot unpack/repack script
- a ramdisk patch step that can:
  - rename stock `/init`
  - add custom `/init`
  - add one or more Shadow init fragments
  - add any boot helper binaries or scripts
- known-good flash and rollback scripts
- a boot helper that can run without manual `adb` intervention
- a log capture path for early wrapper logs and takeover logs

## Artifact Placement

Boot-critical artifacts must not depend on `/data`:

- init wrapper
- Shadow init fragment(s)
- boot helper
- minimal config needed to decide whether to launch Shadow

Phase 1 may still rely on `/data` for larger runtime payloads:

- `shadow-session`
- `shadow-compositor-guest`
- runtime host bundle
- app bundles
- fonts, xkb, and audio helper assets

If `/data`-staged assets are missing, the boot helper must fail loudly and leave a readable recovery or log path instead of black-box hanging.

## Trigger Strategy

Start conservative. The first trigger should prefer reliability over purity.

- acceptable first trigger: after `/data` is available and core vendor init work has completed
- not acceptable: waiting for `sys.boot_completed=1`, because that depends on the full Android framework path we are trying to remove from the operator loop

The first implementation may still allow some Android display services to start and then stop them automatically. Preventing those services from starting at all is a later tightening step.

## Validation

Minimum validation lane:

- flash the custom boot image
- collect early `kmsg` markers from the wrapper
- verify automatic takeover ran
- verify Shadow shell/home appeared
- verify touch input works
- verify Android can be restored by flashing the known-good boot image

Nice-to-have phase 1 validations:

- one app open from shell
- one audio smoke
- one bounded reboot-loop test across two or three boots

## Recovery

Always keep:

- cached stock `boot.img`
- cached last-known-good custom `boot.img`
- one documented fastboot flash path for the active slot
- one operator note on how to confirm the current slot before flashing

## Open Questions

- should the first boot helper be a shell script, a tiny Rust binary, or a hybrid?
- which takeover code should remain script-driven versus move into the boot helper immediately?
- what is the smallest reliable service denylist for automatic boot takeover?
