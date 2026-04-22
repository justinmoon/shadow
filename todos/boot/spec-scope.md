# Boot Scope

Status: draft

This document fixes the system boundary for Pixel 4a boot work so the living plan can stay short.

## Problem

Today Shadow takes over a rooted Android phone after Android has already booted. The goal of the boot project is to replace Android's userspace entirely with a reproducible, minimal boot image that owns everything from PID 1 upward: no Android init, no JVM, no framework services.

## North Star

A reproducible Nix build that produces a boot image from auditable sources:

- **Kernel:** stock Pixel kernel from Google's published source tree (a specific tag)
- **PID 1 and boot graph:** Shadow-owned, written in Rust
- **GPU userspace:** Mesa/Turnip from upstream source
- **Compositor, runtime, shell:** Shadow's own code, built from this repo
- **Proprietary firmware:** only the specific blobs the hardware requires (GPU microcode, GMU, zap shader, and eventually touch/audio DSP), fetched from official upstreams where they actually exist, and otherwise from Google's published factory or vendor images, as fixed-output derivations with pinned hashes

Every byte in the output is either built from source we control or is a verified proprietary blob from a known upstream. The build produces a bill of materials: what is ours, what is open-source, and what is an opaque vendor blob — and why each blob is needed.

Nothing from Android's userspace — no init, no zygote, no system_server, no ART, no Play Services — is present in the target image. The stock Android system, vendor, and data partitions may still exist on-device but are not mounted or used by the boot path.

## Two-Track Strategy

### Track 1: Trailblaze (current)

Pull firmware and vendor artifacts directly off a rooted device. Experiment, discover what the hardware actually needs, and prove each subsystem on real hardware. This track is fast, messy, and exploratory. It produces the knowledge of exactly which vendor dependencies exist and why.

### Track 2: Reproduce

As each dependency is discovered and proven on hardware, reproduce it in a clean Nix derivation from an official upstream source. This forces verification: if we can't build or fetch it from known inputs, we don't actually understand what we're using. Track 2 turns trailblaze discoveries into reproducible, auditable build steps.

The two tracks run in parallel. Track 1 stays ahead, discovering the next hardware dependency. Track 2 follows behind, locking each proven dependency into a deterministic build.

## Definition Of Ownership

For this repo, "own the boot chain" means:

- own the `boot.img` contents for `sunfish`
- own PID 1 and the entire userspace process tree
- decide exactly which proprietary firmware blobs are included and why
- produce the boot image from a reproducible Nix build with a clear bill of materials

It does not initially mean:

- replacing boot ROM, XBL, ABL, TrustZone, or other immutable pre-kernel stages
- replacing the stock kernel on day one (but the build should be able to build one from Google's published source)
- building proprietary firmware from source (Qualcomm does not publish source for GPU/DSP microcode)

## Real Target

- device: Pixel 4a (`sunfish`)
- build baseline: Android 13 `TQ3A.230805.001.S2`
- real boot seam: `boot.img`
- important layout fact: recovery-as-boot
- primary truth environment: physical rooted Pixel 4a
- sidecar environments: host boot-image tooling and narrow Cuttlefish init experiments

## Phase Boundaries

### Phase 0: Tooling And Inspection (done)

- inspect stock and patched `boot.img`
- restore repo-local unpack, patch, repack, and flash scripts
- add early logging and safe rollback

### Phase 1: Shadow-Owned PID 1 With Full GPU (current)

- custom `boot.img` with Shadow-owned PID 1, no stock Android init
- Shadow owns `/dev` bootstrap, firmware serving, and GPU bring-up
- prove the full GPU render path: instance, adapter, device, offscreen render, KMS present
- port PID 1 to Rust once the C seam proves `boot-vulkan-offscreen`
- firmware pulled from device (track 1) with parallel Nix reproduction (track 2)
- success means Shadow renders to screen from boot with no Android code running

### Phase 2: Compositor And App Runtime From Boot

- bring up the compositor, app surfaces, and runtime from the boot-owned PID 1
- prove input, audio, and basic app lifecycle
- keep camera and Wi-Fi deferred
- the Nix build should produce this image end-to-end by the end of this phase

### Phase 3: Shell And Services

- boot into the full Shadow shell experience
- add narrow service spikes: audio, storage, networking as needed
- decide the long-lived strategy for camera, Wi-Fi, update/recovery

## Subsystem Expectations

- display and GPU use DRM/KMS and Mesa/Turnip (open-source userspace, proprietary firmware blobs)
- input is kernel-native, may need touchscreen firmware
- audio needs Qualcomm ADSP firmware; the userspace path is TBD
- camera is expected to stay the hardest Android dependency; defer it
- Wi-Fi and networking are deferred after the first boot milestone
- `/data` is not mounted or used by the boot path; runtime state lives in tmpfs or ramdisk

## Non-Goals For The First Delivery

- relocking the bootloader
- verified custom release keys
- telephony parity
- camera and Wi-Fi parity on day one
- building proprietary firmware from source (not possible; Qualcomm does not publish it)

## Project Rules

- keep one known-good recovery path at all times
- make the physical device the final truth for every milestone
- treat Cuttlefish as a boot-debug helper, not a proxy for `sunfish` hardware behavior
- do not make camera or Wi-Fi blockers for the first Shadow-at-boot milestone
- when a hardware dependency is discovered (track 1), reproduce it from an official upstream source in Nix (track 2) before treating it as permanently understood
- keep the bill of materials explicit: every proprietary blob should have a documented upstream, a pinned hash, and a reason it's needed

## Open Questions

- what is the minimal set of proprietary firmware blobs for GPU, touch, and audio?
- can the kernel be built from Google's published source with the same boot result, or does the stock pre-built kernel carry patches not in the published tree?
- what is the right Nix structure for the boot image build: one flake output, or separate derivations for kernel, firmware, ramdisk, and final image?
- how much SELinux can remain enforcing before the bring-up cost spikes?
- what is the long-lived strategy for camera and Wi-Fi?
