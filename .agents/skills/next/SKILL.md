---
name: next
description: Claim or resume the next interactive dispatch task for the current worktree. Use when Codex is acting as a worker in a user-managed tmux/worktree setup and the user says `/next`.
---

# Next

Use this skill from a worker pane or worker worktree.

The current worktree is the worker identity. There are no controller-managed slots.

## Loop

1. Ask what this worktree should do.
   - `python3 scripts/debug/overnight_ctl.py interactive-next --json`
   - If project inference is ambiguous, rerun with `--project <project>`.

2. Handle the returned action.
   - `claimed`: this worktree owns a new task; start implementing it
   - `resume`: this worktree already owns a task; keep working
   - `idle`: nothing is currently available; tell the user and suggest `/groom`

3. Implement the task.
   - read `title`, `paths`, `validation`, `plan_ref`, and `blocked_by`
   - read the relevant plan/doc context
   - work only in the current worktree

4. Finish honestly.
   - if the task is ready to land, use the `land` skill
   - if the task is blocked or should go back to queue, use:
     - `python3 scripts/debug/overnight_ctl.py interactive-finish --project <project> --state blocked`
     - or:
     - `python3 scripts/debug/overnight_ctl.py interactive-finish --project <project> --state ready`

## Rules

- Do not claim a second task while this worktree still owns one.
- Do not create tmux panes or worktrees.
- Do not switch projects silently.
- Do not stop at queue churn; once you have a task, implement it.

If the current branch moved and landed cleanly on `master`, running `/next` again auto-marks the old claim `done` and advances to the next available task.
