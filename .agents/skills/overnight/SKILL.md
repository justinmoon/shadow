---
name: overnight
description: Run or prepare an overnight multi-agent session for this repo. Use when the user asks to launch, resume, monitor, or design an overnight/cron-style worker run that uses the plan-backed `/groom` and `/next` dispatch workflow.
---

# Overnight

Use this skill from the planner/orchestrator pane.

The orchestrator keeps the run moving. It does not become an implementation
worker, does not create hidden backlog state, and does not bypass `todos/` as the
source of task truth.

## Core Model

- `/groom` owns plan truth in `todos/`.
- `/next` owns worker task selection and claiming from a specific worktree.
- `land` / `scripts/land.sh` owns merging and post-merge dispatch plan sync.
- `overnight` owns launch, resume, monitoring, and light course correction.

Runtime dispatch JSON is assignment state only. Do not add task definitions to
runtime queue files; add or update plan-backed task cards in `todos/`, lint, and
import from the checked-in plan.

## Default Behavior

- `/overnight plan` or discussion-only requests:
  - inspect status, worktrees, plans, and claims
  - propose a launch/resume map
  - do not start agents or mutate task state unless the user explicitly asks
- `/overnight launch`, `/overnight resume`, or explicit start requests:
  - run the preflight
  - groom only as needed to keep `todos/` truthful
  - map tasks to existing or new worktrees
  - launch or resume workers with the standard worker prompt
  - monitor until the requested stop condition or until the run needs human input
- `/overnight monitor`:
  - inspect claims, worktree state, recent commits, and task blockers
  - nudge or reassign only when it is clearly safe

## Preflight

1. Run repo context:
   - `./scripts/agent-brief`
   - `dis interactive-status --project <project> --json`
   - `git status --short --branch`
   - inspect relevant worker worktrees with `git status`, ahead/behind counts, and recent logs
2. Read the configured `plan_path` and any lane docs referenced by active tasks.
3. Check the plan has enough real work:
   - task cards use `task_id`
   - owned paths are narrow enough to avoid unnecessary collisions
   - validation is explicit
   - blockers encode true sequencing
4. If the plan is stale, use the `groom` skill:
   - edit `todos/` task cards
   - run `dis plan-lint --project <project>`
   - run `dis queue-import-plan --project <project>` only from landed/root truth
5. Confirm launch safety:
   - root `master` clean unless the user explicitly wants to launch from a planner branch
   - workers clean or intentionally resumable
   - no stale claims for missing/abandoned worktrees
   - hardware/device constraints are visible in task notes when relevant

## Worktree And Session Choice

Prefer resuming an existing worker/session when it has useful context and is
still pointed at the same lane.

Resume when:

- the worktree already owns the claim
- the next available task directly continues the lane the worker just landed
- local notes, session history, or hardware setup would materially reduce ramp-up
- the worktree is clean or has coherent in-progress changes for the same claim

Create a new worktree/session when:

- starting an unrelated task or independent hypothesis
- the old worker's context is likely to bias the new task in the wrong direction
- the existing worktree is dirty, conflicted, stale, or tied to a different live claim
- parallel work needs disjoint write scopes and independent logs

Fast-forward clean worker worktrees before launch so `/next` sees the landed
plan. Do not overwrite or revert unrecognized local changes.

## Launch Prompt

Use a concise worker prompt shaped like this:

```text
Run /next for project <project>. Inspect all available tasks, prefer the one that
best fits this worktree's recent context, claim it explicitly, then implement it.

You are not alone in the codebase. Do not revert unrelated edits. Keep changes
inside the claimed task's owned paths unless you find a clear dependency and
explain it.

Before landing: run the task validation, use at least one blocking gpt-5.4 xhigh
review subagent for substantive changes, update the relevant todos plan with
result/proof/blocker notes and sane next task cards if material work remains,
then use the land skill. After landing, mark the claim done and run /next again
only if the next available task is a good continuity fit.

Stop and leave a clear note if blocked, validation cannot run, hardware is not
available, the plan lacks the right successor, or the best next task is unrelated
to this worker's context.
```

When launching into a specific worker, add any user instruction about continuity,
hardware, or lane ownership. Do not hide important instructions in the
orchestrator thread only.

## Monitoring Loop

On each interval:

1. Run `dis interactive-status --project <project> --json`.
2. Check each claimed worktree:
   - clean/dirty state
   - ahead/behind relative to `master`
   - whether its claim is still coherent with its branch changes
   - recent commit or log activity if available
3. If a worker landed:
   - ensure `scripts/land.sh` completed and dispatch plans synced
   - fast-forward clean workers that need the new plan
   - release landed-clean claims as `done` if `/next` has not done it yet
4. If a worker is blocked:
   - make sure the task card or lane doc records the blocker and artifacts
   - mark the claim `blocked` only when the blocker is real and preserved
   - groom a concrete follow-up or alternate task if the run should continue
5. If a worker is idle:
   - prefer a related successor task
   - otherwise leave it idle rather than assigning unrelated work that wastes context

## Stop Conditions

Stop the run, or pause for the user, when:

- all suitable tasks are done, blocked, or waiting
- `master` is red after a landed change and the fix is not obvious
- a worker has destructive/conflicting local changes
- hardware/device state is unsafe or ambiguous
- the plan needs a product decision rather than more implementation
- the only available work is unrelated to every available worker's useful context

## Reporting

Keep the summary operational:

- current claims and worker/session mapping
- commits landed
- tasks done, blocked, waiting, and still available
- proof artifact paths or validation commands
- any planner decisions made during the run
- exact next recommended action
