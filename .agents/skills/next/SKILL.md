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
  - resume an existing claim, or inspect all available tasks before claiming fresh work
  - choose the best available task for this worker's current context and claim it explicitly
  - start implementing the task
- `/next ... don't start coding yet`, `/next ... just tell me what I own`, or similar:
  - inspect first
  - summarize the current claim or the available task choices
  - do not start coding until the user says to proceed

## Loop

1. Inspect what this worktree should do.
   - start with:
     - `dis interactive-status --json`
   - If project inference is ambiguous, rerun with `--project <project>`.
   - if this worktree already owns an active claim, resume that task
   - if this worktree has a `landed_clean` claim, release it first:
     - `dis interactive-finish --project <project> --state done --json`
     - then inspect status again
   - for discussion-only / inspect-first requests, explain the current claim or available task choices without claiming a new one unless the user explicitly asked you to

2. Choose fresh work when there is no active claim.
   - review every task in `available`, not just the first one
   - prefer work that best uses this worktree's recent context, path knowledge, hardware setup, and previous lane
   - use priority, critical-path value, and user instructions as tie-breakers
   - if no available task fits and continuity matters, stop and say `/groom` should add or prioritize the related successor

3. Claim the chosen task explicitly.
   - run:
     - `dis interactive-next --task-id <task-id> --json`
   - if project inference is ambiguous, include `--project <project>`
   - if the claim races or the selected task is no longer available, inspect status again and choose from the remaining tasks

4. Handle the returned action.
   - `claimed`: this worktree owns a new task; start implementing it
   - `resume`: this worktree already owns a task; keep working
   - `idle`: nothing is currently available; tell the user and suggest `/groom`

5. Implement the task.
   - read `title`, `paths`, `validation`, `plan_ref`, and `blocked_by`
   - read the relevant plan/doc context
   - work only in the current worktree

6. Review before landing.
   - for any substantive code, script, hardware, or architecture/doc change, spawn at least one blocking review subagent before landing
   - use model `gpt-5.4` with reasoning effort `xhigh`
   - for complex or risky changes, use multiple reviewers with distinct perspectives, chosen by worker judgement:
     - correctness / edge cases
     - validation / test coverage
     - integration / hardware safety
     - docs / operator workflow
   - tell reviewers they are not alone in the codebase, must not revert unrelated work, and should focus only on this task's changed paths and validation contract
   - wait for blocking review results with minutes-scale timeouts, integrate relevant fixes, then rerun the affected validation
   - if a reviewer finds a real issue that should not be fixed in the current task, document it clearly and ask `/groom` to add or prioritize the follow-up

7. Finish honestly.
   - if the task is ready to land, use the `land` skill
   - after a successful land, make sure this worktree's claim is marked `done` before starting another task:
     - if `/next` later reports the old claim as `landed_clean`, run `dis interactive-finish --project <project> --state done --json`
     - if you are explicitly closing out after confirming the landed commit, run `dis interactive-finish --project <project> --state done --json`
   - when helpful for future workers, add concise completion notes before marking done:
     - update the relevant `todos/` task card with `result`, proof artifact paths, blocker details, or the next recommended slice
     - keep notes factual and short; do not duplicate full command logs when artifact paths are enough
   - if the task is blocked or should go back to queue, use:
     - `dis interactive-finish --project <project> --state blocked`
     - or:
     - `dis interactive-finish --project <project> --state ready`

## Continuity

- The dispatcher is queue-driven. It does not infer the best next task from this worktree's previous research, branch history, or local context.
- The planner must expose related follow-up tasks in the queue, with priority ahead of unrelated available work, when a specialized worker should continue the same lane.
- The worker supplies judgement by inspecting all available tasks and explicitly claiming the best fit.
- When the user asks to continue the previous lane and no related task is available, do not claim unrelated work just to stay busy; tell the user `/groom` should add or prioritize the related successor.
- At handoff, workers should write the concrete next slice in docs or their final summary, but should not self-expand the queue unless explicitly asked.

## Rules

- Do not claim a second task while this worktree still owns one.
- Do not create tmux panes or worktrees.
- Do not switch projects silently.
- Do not stop at queue churn; once you have a task, implement it.

If the current branch moved and landed cleanly on `master`, release the old claim as `done`, then inspect available tasks and choose deliberately.
