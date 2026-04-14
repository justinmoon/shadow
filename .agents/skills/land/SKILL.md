---
name: land
description: Land the current implementation worktree branch into the root repo's master branch by running the repo's canonical landing script. Use when the user asks to merge, land, or promote the current worktree branch.
---

# Land

This repo uses git worktrees for implementation and keeps the root repo at `../..` on `master`.

When the user asks to land the current worktree branch:

1. Ensure the current worktree changes are committed.
2. Run `scripts/land.sh` from the implementation worktree root.
3. If the script stops on a rebase conflict, resolve the conflicts carefully, ask the user when the resolution is ambiguous, then continue the rebase and keep going with the landing flow.
4. Do not abandon the landing flow just because the happy path script stopped at a conflict.

`scripts/land.sh` is the source of truth. It:

- verifies the current worktree and root repo are clean
- rebases the current branch onto root `master`
- runs `just pre-merge`
- fast-forwards the root repo's `master` branch only if the gate passes

When a rooted Pixel is available and the diff clearly touches device-specific lanes, recommend a matching `just pixel-ci <subset>` run before landing, but do not make it a hard requirement. Examples:

- shell / compositor / launch-control changes: `just pixel-ci shell`
- camera app or camera host changes: `just pixel-ci camera`
- runtime audio changes: `just pixel-ci sound`
- podcast player changes: `just pixel-ci podcast`
- broad rooted-Pixel or takeover changes: `just pixel-ci full`

If the script fails, report the exact failing step and stop before merging.
