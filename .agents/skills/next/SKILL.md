---
name: next
description: Claim or resume the next interactive dispatch task for the current worktree. Use when Codex is acting as a worker in a user-managed tmux/worktree setup and the user says `/next`.
---

# Next

Use this skill from a worker pane or worker worktree.

The current worktree is the worker identity. There are no controller-managed slots.

Treat the user's text after `/next` as the primary instruction.

## Default Behavior

- `/next` alone:
  - claim or resume normally
  - start implementing the task
- `/next ... don't start coding yet`, `/next ... just tell me what I own`, or similar:
  - inspect first
  - summarize the current claim or the next likely task
  - do not start coding until the user says to proceed

## Loop

1. Ask what this worktree should do.
   - for normal claim/resume:
     - `dis interactive-next --json`
   - If project inference is ambiguous, rerun with `--project <project>`.
   - for discussion-only / inspect-first requests:
     - use `dis interactive-status --json`
     - explain the current claim or the next available task without claiming a new one unless the user explicitly asked you to

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
     - `dis interactive-finish --project <project> --state blocked`
     - or:
     - `dis interactive-finish --project <project> --state ready`

## Rules

- Do not claim a second task while this worktree still owns one.
- Do not create tmux panes or worktrees.
- Do not switch projects silently.
- Do not stop at queue churn; once you have a task, implement it.

If the current branch moved and landed cleanly on `master`, running `/next` again auto-marks the old claim `done` and advances to the next available task.
