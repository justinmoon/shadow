# Boot Scope

Status: draft

This document fixes the system boundary for Pixel 4a boot work so the living plan can stay short.

## Problem

Today Shadow takes over a rooted Android phone after Android has already booted. The boot project moves Shadow earlier: custom boot image, automatic Shadow launch, and progressively smaller Android dependency.

## Definition Of Ownership

For this repo, "own the boot chain" means:

- own the `boot.img` contents for `sunfish`
- own the ramdisk entrypoint and added init imports
- decide how Shadow is launched during boot
- decide which Android services are allowed to continue after Shadow takes over

It does not initially mean:

- replacing boot ROM, XBL, ABL, TrustZone, or other immutable pre-kernel stages
- replacing the stock kernel on day one
- replacing vendor firmware or HAL blobs on day one
- shipping a full non-Android Linux distro as the first deliverable

## Real Target

- device: Pixel 4a (`sunfish`)
- build baseline: Android 13 `TQ3A.230805.001.S2`
- real boot seam: `boot.img`
- important layout fact: recovery-as-boot
- primary truth environment: physical rooted Pixel 4a
- sidecar environments: host boot-image tooling and narrow Cuttlefish init experiments

## Phase Boundaries

### Phase 0: Tooling And Inspection

- inspect stock and patched `boot.img`
- restore repo-local unpack, patch, repack, and flash scripts
- add early logging and safe rollback

### Phase 1: Shadow At Boot With Stock Init Retained

- custom boot image and init wrapper
- stock init still handles mounts, `ueventd`, modules, encrypted `/data`, and most service labelling
- Shadow boot path runs automatically, likely by reusing the current takeover logic
- success means no manual `adb` or `su` takeover after boot

### Phase 2: Reduce Android Runtime Dependency

- stop depending on pre-staged `/data` artifacts for the minimal boot lane
- trim services started before Shadow takeover
- keep only the vendor daemons actually needed for the Shadow runtime

### Phase 3: Deeper Replacement, Only If It Pays Off

- replace more init and service logic
- consider alternate rootfs shapes or stronger SELinux posture
- not a blocker for the first product milestone

## Subsystem Expectations

- display, input, audio, and GPU are already close to Linux-native; phase 1 should reuse the current runtime path
- `/data` likely stays Android-managed early because of encryption and checkpointing
- camera is expected to stay Android-native for longer
- Wi-Fi and broader networking likely stay Android-managed or are deferred after phase 1
- update and recovery must stay simple and reversible from the start

## Non-Goals For The First Delivery

- relocking the bootloader
- verified custom release keys
- full Android replacement
- telephony parity
- camera and Wi-Fi parity on day one

## Project Rules

- keep one known-good recovery path at all times
- prefer stock `boot.img` plus small ramdisk modifications over larger platform forks
- make the physical device the final truth for every milestone
- treat Cuttlefish as a boot-debug helper, not a proxy for `sunfish` hardware behavior
- do not make camera or Wi-Fi blockers for the first Shadow-at-boot milestone

## Open Questions

- what is the smallest safe trigger point for automatic takeover?
- which vendor services are actually required after Shadow owns the display?
- can phase 1 tolerate pre-staged runtime bundles under `/data`, or is a ramdisk-minimal bundle better?
- how much SELinux can remain enforcing before the bring-up cost spikes?
