---
name: groom
description: Groom the repo-local interactive dispatch queue for boot or shadow-ui. Use when Codex is acting as the planner in a user-managed tmux/worktree setup and the user says `/groom` or asks to discuss, refresh, split, reorder, or clean up the queue.
---

# Groom

Use this skill from the planner pane or planner worktree.

The human owns tmux and worktrees. Your job is only to keep the queue truthful so workers can run `/next`.

Treat the user's text after `/groom` as the primary instruction. `/groom` is a conversational planner mode, not a fire-and-forget command.

## Default Behavior

- `/groom` alone:
  - inspect current state and summarize
  - do not mutate queue or claims yet
- `/groom ... don't mutate yet` or similar:
  - inspect, discuss, and propose
  - do not run queue-changing commands
- `/groom ... go ahead`, `/groom ... make those changes`, or any explicit mutation request:
  - inspect first if needed
  - then run the queue-changing commands required to carry out the request

## Loop

1. Read current state.
   - `dis interactive-status --json`
   - If project inference is ambiguous, rerun with `--project boot` or `--project shadow-ui`.

2. Read the plan.
   - Open the configured `plan_path`.
   - Treat `todos/` task cards with `task_id` as the canonical work definition.
   - Re-import plan task cards only when the user explicitly wants queue mutation or asks for reimport:
     - `dis plan-lint --project <project>`
     - `dis queue-import-plan --project <project>`

3. Clean up stale claims.
   - `landed_clean`: release as `done`
   - missing or abandoned worktree: release as `ready` or `blocked`
   - use, but only when the user asked you to clean state or mutate queue truth:
     - `dis interactive-finish --project <project> --worktree <path> --state <state>`

4. Groom the queue.
   - when discussing only:
     - propose concrete tasks, blockers, and sequencing in plain language
     - do not edit `todos/` or run queue-changing commands
   - when explicitly asked to mutate:
     - add or update small concrete task cards in the configured `todos/` plan
     - run `dis plan-lint --project <project>` before importing
     - run `dis queue-import-plan --project <project>` to refresh assignment state
     - change queue truth with `task-state`
     - encode dependency order with `blocked_by`

5. End with a short summary:
   - current claims
   - available tasks
   - waiting tasks and blockers

## Blockage Handling

When the user asks how to break a blocker into parallel work, prefer explicit parallel attempts over vague duplicate effort.

- Keep the blocker visible.
- Propose 2-3 child tasks with distinct approaches.
- Good approach labels:
  - `mainline`
  - `instrumentation`
  - `falsification`
  - `alternate-contract`
- Downstream tasks can keep depending on the original blocker while workers attack the child tasks.
- Do not mutate queue state unless the user explicitly asks you to create those attempts.

## Rules

- Do not create tmux panes or worktrees.
- Do not auto-launch hidden workers.
- Keep the queue small.
- Use `task-add` only for old live claims that cannot yet be represented in `todos/`.
- Prefer narrow write scopes and one clear validation shape per task.
- For boot, keep the Stream A critical path explicit; do not pretend parallelism exists when it does not.
