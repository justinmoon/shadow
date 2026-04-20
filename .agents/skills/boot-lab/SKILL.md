---
name: boot-lab
description: Run multi-device boot and rooted-Pixel experiments safely and concurrently, keeping allowed serials, root state, recovery paths, and subagent experiment ownership explicit. Use when coordinating boot, DRM, GPU, or display bring-up across dedicated lab phones.
---

# Boot Lab

This skill is for repeated hardware experiments on dedicated Pixel lab phones.

You are the boot-lab operator.

Your job is to keep devices usable, rooted, assigned, observable, and recoverable while the broader project moves. Treat device state as first-class execution state, not thread memory.

## First Minute

- Confirm which serials are in scope. Never touch other attached phones without explicit user approval.
- Snapshot the current lab state before planning experiments:
  - `adb devices`
  - per allowed serial: fingerprint, slot, `sc -t <serial> root-check`
  - if relevant: `sc -t <serial> doctor`
- Name a primary device and a confirmation device.
- If the task is broad, pair this skill with `orchestrate`.
- If the task has multiple landable seams, keep the living plan current in `todos/`.

## Device Ownership

- One device, one active experiment lane, one responsible owner at a time.
- Do not let two workers flash, boot, or recover the same serial concurrently.
- The main agent owns:
  - device assignment
  - rooting state
  - flashing / oneshot / recovery commands
  - interpretation of hardware outcomes
- Subagents may own an experiment only after:
  - the artifact path is explicit
  - the target serial is explicit
  - the recovery contract is explicit
  - the write scope is explicit

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

## Concurrency Rules

- Use the primary device for the newest hypothesis.
- Use the confirmation device for repro, comparison, or a clearly different hypothesis.
- Prefer concurrent runs only when they probe different seams or different recovery assumptions.
- Do not run the same fragile, low-observability experiment on multiple devices at once just to create more confusion faster.
- Keep a small live ledger in the thread or plan:
  - serial
  - current role
  - rooted or not
  - current slot
  - active hypothesis
  - last known resting state

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
- whether a non-primary device is allowed to be touched

Ask for hardware help early when the blocker is physical. Do not keep iterating in software while the phone is waiting for a human.

## Subagent Use

- Use workers for bounded artifact work, runner scripts, and analysis.
- Use reviewers for risk review and seam integrity.
- For true concurrent hardware work, give each worker:
  - one device
  - one worktree
  - one hypothesis
  - one recovery command
- The orchestrator keeps the global lab map and decides when a device is free for reassignment.
- If a worker owns a device experiment, wait for that worker's result instead of duplicating the same run locally.

## Boot-Lab Defaults

- Primary goal: truthful evidence, not maximum flashes per hour.
- Keep the current working lane recoverable while iterating on the new lane.
- Favor small, landable bring-up rungs over broad “boot the whole product” pushes.
- Keep the lab ready for the next experiment before ending the turn.
