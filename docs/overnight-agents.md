---
summary: Minimal interactive dispatch queue for user-managed tmux/worktrees via `/groom` and `/next`
read_when:
  - using the private dispatch queue behind `/groom` and `/next`
  - seeding or resetting the boot or shadow-ui interactive task queue
---

# Interactive Dispatch

This doc covers the private dispatcher behind
[`scripts/debug/dispatch.py`](../scripts/debug/dispatch.py).

Inside the devshell, use `dis` as the entrypoint. It is a thin wrapper over
`scripts/debug/dispatch.py`.

The UX is intentionally small:

- planner pane/worktree: `/groom`
- worker pane/worktree: `/next`
- tmux and worktrees: managed by the human

There is no controller-owned tmux, slot, worktree, worker, or session layer.

## Conversational Use

The skills are meant to be conversational.

Good planner examples:

```text
/groom let's discuss how to break down the blocking task into multiple concurrent experiments. don't mutate the queue yet.
```

```text
/groom we are blocked on boot-finish-inflight-app-direct-present. propose 3 parallel hypothesis tasks with different approaches.
```

```text
/groom go ahead and create two child tasks for this blocker.
```

Good worker examples:

```text
/next
```

```text
/next just tell me what this worktree owns; don't start coding yet.
```

Default intent:

- `/groom` alone: inspect and summarize first; do not mutate queue state yet
- `/next` alone: resume an existing claim, or inspect all available tasks, choose the best fit for this worker, claim it, and start work

## Files

Checked in:

- project definitions: `.agents/dispatch/projects/*.json`
- human plans: `todos/...`

Runtime state, shared across worktrees:

- `.agents/dispatch/state/projects/<project>/queue.json`
- `.agents/dispatch/state/projects/<project>/claims.json`

## Plan-Backed Tasks

Task definitions live in `todos/`, not in runtime JSON. Dispatch materializes task
definitions from the configured project plan on every status/claim operation.

Recommended task-card shape:

```md
- [ ] `finish-inflight-app-direct-present`
  - task_id: boot-finish-inflight-app-direct-present
  - priority: 11
  - owned paths:
    - `scripts/pixel/`
    - `todos/boot/`
  - validation:
    - `scripts/ci/pixel_boot_orange_gpu_smoke.sh`
  - blocked_by: none
```

`task_id` is the canonical identity that claims and dependencies point at. If a
legacy card does not have `task_id`, dispatch falls back to a generated slug,
but new task cards should always include `task_id`.

`blocked_by:` may name either task ids or human titles. Prefer task ids for
durability.

## Runtime State

`queue.json` is assignment state only. It does not duplicate plan-owned task
definitions, and it only stores plan-task states that differ from the current
plan default:

```json
{
  "project": "boot",
  "task_states": {
    "boot-finish-inflight-app-direct-present": "done",
    "boot-ts-app-minimal": "running"
  }
}
```

Entries omitted from `task_states` derive from the plan checkbox, section, or
explicit `state:` field. Older manually added tasks can temporarily appear under
`legacy_tasks` until they are moved into `todos/`. Do not add new work that way
unless you are preserving an old live claim.

`claims.json` maps worktree path to the one task that worktree currently owns:

```json
{
  "project": "boot",
  "claims": {
    "/abs/path/to/worktree": {
      "task_id": "boot-finish-inflight-app-direct-present",
      "branch": "dispatch/boot/app-direct-present",
      "claimed_head": "abc123..."
    }
  }
}
```

## Markdown Task Discovery

Dispatch discovers checklist items that are either under `## Next Dispatch Batch`
or explicitly shaped like task cards with `task_id:`, `owned paths:`,
`validation:`, or `blocked_by:`.

Unchecked cards default to `ready` under `## Next Dispatch Batch` and `backlog`
elsewhere. Checked cards default to `done`; `[~]` cards default to `blocked`.
Runtime state can override unchecked defaults, while checked, `[~]`, and
explicit `state:` cards reset stale runtime overrides except for active
`running` claims.

`just pre-commit` runs `dis plan-lint --all` to catch malformed task cards,
duplicate or invalid task ids, ambiguous title blockers, and unresolved
blockers before dispatch state depends on them.

## Commands

Seed or reset a project:

```sh
dis project-init --project boot --plan todos/boot/plan.md
dis plan-lint --project boot
dis queue-import-plan --project boot
```

`queue-import-plan` indexes the plan and persists assignment state only. It does
not copy task definitions into runtime JSON.

Workers should not run `queue-import-plan` from an unlanded implementation
branch. The landing flow lints and imports all checked-in dispatch plans from
the root `master` checkout after a successful fast-forward, so shared runtime
assignment state follows the landed `todos/` truth.

Inspect queue and claims:

```sh
dis interactive-status --project boot
dis interactive-status --project boot --json
```

Inspect available tasks before choosing work:

```sh
dis interactive-status --project boot --json
```

Claim a chosen task from the current worktree:

```sh
dis interactive-next --project boot --task-id boot-specific-task --json
```

For script compatibility, omitting `--task-id` still claims the highest-priority available task after any resumable or landed-clean existing claim is handled.

Release the current claim explicitly when the branch did not land cleanly:

```sh
dis interactive-finish --project boot --state done
dis interactive-finish --project boot --state ready
dis interactive-finish --project boot --state blocked
```

Adjust assignment state directly:

```sh
dis task-state --project boot --task-id boot-new-seam --state ready
```

To add new work, edit the relevant `todos/` file with a task card and run
`dis queue-import-plan --project <project>`. `task-add` remains only as a
compatibility path for old live tasks that have not yet moved into `todos/`.

## Behavior

- `/next` resumes the current worktree claim if one already exists.
- Workers should inspect all available tasks before claiming fresh work, then claim the chosen task explicitly with `interactive-next --task-id`.
- Task priority is the scheduler fallback and a planning signal, not a substitute for worker judgement about continuity, path overlap, or recently accumulated context.
- If direct `interactive-next` sees that the worktree's branch moved and landed cleanly on `master`, it auto-marks the old task `done`. With `--task-id`, it then claims that selected task; without `--task-id`, it falls back to the highest-priority available task.
- `blocked_by` controls `available` versus `waiting`.
- `queue-import-plan` refreshes plan-derived task definitions and persists assignment state only, while preserving legacy runtime-defined tasks until they are moved into `todos/`.
- `scripts/land.sh` runs post-merge dispatch plan lint/import from root `master`; workers still need to fast-forward their local worktree before `/next` can see newly landed task cards.
