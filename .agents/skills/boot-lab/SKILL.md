---
name: boot-lab
description: Run multi-device boot and rooted-Pixel experiments safely and concurrently, keeping allowed serials, root state, recovery paths, and subagent experiment ownership explicit. Use when coordinating boot, DRM, GPU, or display bring-up across dedicated lab phones.
---

# Boot Lab

This skill is for repeated hardware experiments on dedicated Pixel lab phones.

You are the boot-lab operator.

Your job is to keep devices usable, rooted, assigned, observable, and recoverable while the broader project moves. Treat device state as first-class execution state, not thread memory.

## First Minute

- Treat attached lab Pixel devices reported by `sc devices` as in scope by default. Ask only before touching non-lab or unknown phones, or when a physical user action is needed.
- Snapshot the current lab state before planning experiments:
  - `adb devices`
  - per selected serial: fingerprint, slot, `sc -t <serial> root-check`
  - if relevant: `sc -t <serial> doctor`
- Name a primary device and a confirmation device.
- If the task is broad, pair this skill with `orchestrate`.
- If the task has multiple landable seams, keep the living plan current in `todos/`.

## Device Ownership

- One device, one active experiment lane, one responsible owner at a time.
- Do not let two workers flash, boot, or recover the same serial concurrently.
- The coordinator owns:
  - device assignment and reservation
  - lane selection
  - rooting state policy
  - interpretation of hardware outcomes
  - promotion of results into the critical path
- Exactly one boot-owned seam is the critical path at a time.
- Only the coordinator may reassign or promote the critical-path seam.
- Workers may own the full experiment loop only after:
  - the artifact path is explicit
  - the target serial is explicit
  - the recovery contract is explicit
  - the resting state is explicit
  - the write scope is explicit
  - the worker has its own worktree if it will edit code

## Reservation Protocol

- Reserve each device explicitly with:
  - serial
  - lane
  - owner
  - artifact or command
  - expected evidence surface
  - expected resting state
- Record reservation changes in the thread or living plan before launching the run.
- Release or reclaim the reservation explicitly before reassigning the device.
- If a worker exits, times out, or crashes, the coordinator must first re-establish the device's real resting state before reusing it.

## Root Readiness

- Use the repo's supported flow:
  - `sc root-prep`
  - `sc -t <serial> root-check`
  - `sc -t <serial> root-patch`
  - `sc -t <serial> root-flash`
- Prefer the automated Magisk patch path first. Fall back to manual Magisk-app patching only if the script fails.
- After `root-flash`, if `root-check` says to open Magisk once, do that or ask the user to do it immediately.
- Keep both primary and confirmation devices rooted whenever practical. Rooting is operator overhead; pay it once so concurrency stays available.

## Shared Artifact Hazards

- Before parallelizing, check whether build or staging paths are shared in the current worktree.
- If two experiments would share mutable artifacts, use separate worktrees or explicit per-run overrides.
- Do not assume script helpers are serial-scoped just because adb/fastboot calls are serial-scoped. Inspect local output paths too.
- Example hazard: a shared patched-boot output means patch once, then fan out the read-only artifact, or use separate worktrees.

## Experiment Loop

1. Pick one narrow seam and define the expected evidence before running.
2. Build or stage the artifact in the owning worktree.
3. Bind the artifact to a specific device and recovery path.
4. Run the experiment with a single explicit command.
5. Collect the best surviving evidence immediately after the run.
6. Recover the device to the agreed resting state.
7. Record the outcome plainly: pass, fail, ambiguous, or blocked.

## Lane Strategy

- Do not spend the whole lab on one blocked seam unless later rungs truly depend on it.
- Split the lab by lane, not by raw device count:
  - one critical-path boot-owned lane
  - one confirmation lane for the same seam
  - one or more independent rooted sidecar lanes
- Good sidecar seams:
  - sound
  - camera
  - touch or input
  - observability or recovery tooling
  - rooted prerequisite experiments for the blocked boot-owned seam
- Bad parallelism:
  - multiple devices repeating the same low-observability failing boot seam
  - later compositor or app rungs when the current boot-owned prerequisite is still unproven
- Promote a sidecar result into the critical path only after the coordinator judges the evidence strong enough.

## Concurrency Rules

- Use the primary device for the newest hypothesis.
- Use the confirmation device for repro, comparison, or a clearly different hypothesis.
- If you have four devices, prefer this shape:
  - primary boot-owned lane
  - confirmation boot-owned lane
  - rooted sidecar lane A
  - rooted sidecar lane B or cold spare
- Prefer concurrent runs only when they probe different seams or different recovery assumptions.
- Do not run the same fragile, low-observability experiment on multiple devices at once just to create more confusion faster.
- Keep one device cold when recovery risk is high or when a user may need to intervene physically.
- Keep a small live ledger in the thread or plan:
  - serial
  - current role
  - rooted or not
  - current slot
  - active hypothesis
  - last known resting state

## Coordinator Model

- Default to one coordinator for the boot lab.
- Add a second coordinator only for a truly separate lane, not as a peer on the same seam.
- If two coordinators exist:
  - split by lane, not by arbitrary device count
  - give each fixed serial ownership
  - use separate worktrees
  - avoid overlapping edits to the same script family
  - keep one coordinator responsible for the canonical plan and promotion decisions
- The boot-lab coordinator owns the critical path. Sidecar coordinators or workers should feed evidence back, not fork the plan.

## Observability

- No guessing. Visible, durable, or host-collected evidence beats inference.
- Every experiment should declare its evidence surface up front:
  - screen color or animation
  - JSON summary
  - pulled artifact
  - kernel breadcrumb
  - Android-side recovery trace
- If the evidence is weak, improve instrumentation before scaling out.
- After every disruptive run, collect traces before starting the next one.

## Recovery Discipline

- Always know how the device gets back to a usable state before starting the run.
- Prefer guarded helpers over ad hoc flashing commands.
- After hold-mode, takeover, or failed boot attempts, return the phone to a stable Android or fastboot resting state.
- If the device is in a physical-button recovery loop, stop software work and ask the user for the exact hardware action needed.

## When To Ask The User

- bootloader unlock confirmation on-device
- Magisk first-launch or environment-fix prompt
- manual button combos
- cable or port swaps
- what was physically visible on screen
- whether an attached non-lab or unknown device is allowed to be touched

Ask for hardware help early when the blocker is physical. Do not keep iterating in software while the phone is waiting for a human.

## Subagent Use

- Use workers for bounded artifact work, runner scripts, analysis, and independent sidecar lanes.
- Use reviewers for risk review and seam integrity.
- For true concurrent hardware work, give each worker:
  - one device
  - one worktree
  - one hypothesis
  - one recovery command
- Workers may own the full loop only on a sidecar lane with explicit bounds:
  - build or stage
  - run
  - recover
  - summarize evidence
- The orchestrator keeps the global lab map, approves moves onto the critical path, and decides when a device is free for reassignment.
- If a worker owns a device experiment, wait for that worker's result instead of duplicating the same run locally.
- Parallel sidecars are allowed only when device, artifact path, recovery contract, and evidence surface are independent.
- Check for hidden host collisions before parallel launch:
  - shared adb or fastboot assumptions
  - shared staging paths
  - shared output paths
  - shared USB assumptions

## Waiting Discipline

- Waiting is part of orchestration, not idle time.
- After flash, boot, takeover, or recovery, allow the device to converge and capture evidence before launching the next run.
- Do not busy-loop the same device while it is still converging or while a worker still owns the reservation.
- A timeout is not a result. Wait again, inspect the real device state, or explicitly abandon the seam.
- Use waiting time only for non-overlapping work:
  - plan updates
  - artifact review
  - a different device on a different seam
  - tooling or docs that do not collide with the active lane

## Boot-Lab Defaults

- Primary goal: truthful evidence, not maximum flashes per hour.
- Keep the current working lane recoverable while iterating on the new lane.
- Favor small, landable bring-up rungs over broad “boot the whole product” pushes.
- Keep the lab ready for the next experiment before ending the turn.
