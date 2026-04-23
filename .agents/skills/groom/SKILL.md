---
name: groom
description: Groom the repo-local interactive dispatch queue for boot or shadow-ui. Use when Codex is acting as the planner in a user-managed tmux/worktree setup and the user says `/groom` or asks to refresh, split, reorder, or clean up the queue.
---

# Groom

Use this skill from the planner pane or planner worktree.

The human owns tmux and worktrees. Your job is only to keep the queue truthful so workers can run `/next`.

## Loop

1. Read current state.
   - `dis interactive-status --json`
   - If project inference is ambiguous, rerun with `--project boot` or `--project shadow-ui`.

2. Read the plan.
   - Open the configured `plan_path`.
   - Re-import plan task cards when the plan changed:
     - `dis queue-import-plan --project <project>`

3. Clean up stale claims.
   - `landed_clean`: release as `done`
   - missing or abandoned worktree: release as `ready` or `blocked`
   - use:
     - `dis interactive-finish --project <project> --worktree <path> --state <state>`

4. Groom the queue.
   - add small concrete tasks with `task-add`
   - change queue truth with `task-state`
   - encode dependency order with `blocked_by`

5. End with a short summary:
   - current claims
   - available tasks
   - waiting tasks and blockers

## Rules

- Do not create tmux panes or worktrees.
- Do not auto-launch hidden workers.
- Keep the queue small.
- Prefer narrow write scopes and one clear validation shape per task.
- For boot, keep the Stream A critical path explicit; do not pretend parallelism exists when it does not.
