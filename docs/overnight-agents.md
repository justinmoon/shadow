---
summary: Minimal interactive dispatch queue for user-managed tmux/worktrees via `/groom` and `/next`
read_when:
  - using the private dispatch queue behind `/groom` and `/next`
  - seeding or resetting the boot or shadow-ui interactive task queue
---

# Interactive Dispatch

This doc covers the private dispatcher behind
[`scripts/debug/overnight_ctl.py`](../scripts/debug/overnight_ctl.py).

Inside the devshell, use `on` as the entrypoint. It is a thin wrapper over
`scripts/debug/overnight_ctl.py`.

The UX is intentionally small:

- planner pane/worktree: `/groom`
- worker pane/worktree: `/next`
- tmux and worktrees: managed by the human

There is no controller-owned tmux, slot, worktree, worker, or session layer.

## Files

Checked in:

- project definitions: `.agents/dispatch/projects/*.json`
- human plans: `todos/...`

Runtime state, shared across worktrees:

- `.agents/dispatch/state/projects/<project>/queue.json`
- `.agents/dispatch/state/projects/<project>/claims.json`

## Queue Shape

`queue.json` is intentionally small:

```json
{
  "project": "boot",
  "tasks": [
    {
      "id": "boot-finish-inflight-app-direct-present",
      "title": "finish-inflight-app-direct-present",
      "state": "ready",
      "priority": 11,
      "plan_ref": "todos/boot/plan.md:99",
      "paths": ["scripts/pixel/", "todos/boot/"],
      "validation": ["scripts/ci/pixel_boot_orange_gpu_smoke.sh"],
      "blocked_by": []
    }
  ]
}
```

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

## Markdown Task Cards

`queue-import-plan` only imports unchecked checklist items that are either:

- under `## Next Dispatch Batch`, or
- explicitly shaped like task cards with these subfields:
  - `owned paths:`
  - `validation:`
  - `blocked_by:`

Recommended task-card shape:

```md
- [ ] `finish-inflight-app-direct-present`
  - owned paths:
    - `scripts/pixel/`
    - `todos/boot/`
  - validation:
    - `scripts/ci/pixel_boot_orange_gpu_smoke.sh`
  - blocked_by: none
```

`blocked_by:` may name either task ids or human titles. Import resolves titles to ids.

## Commands

Seed or reset a project:

```sh
on project-init --project boot --plan todos/boot/plan.md
on queue-import-plan --project boot
```

Inspect queue and claims:

```sh
on interactive-status --project boot
on interactive-status --project boot --json
```

Claim or resume from the current worktree:

```sh
on interactive-next --project boot --json
```

Release the current claim explicitly when the branch did not land cleanly:

```sh
on interactive-finish --project boot --state done
on interactive-finish --project boot --state ready
on interactive-finish --project boot --state blocked
```

Adjust the queue directly:

```sh
on task-add --project boot --title 'new seam' --path scripts/pixel/ --validation 'just pre-commit'
on task-state --project boot --task-id boot-new-seam --state ready
```

## Behavior

- `/next` resumes the current worktree claim if one already exists.
- If that worktree's branch moved and landed cleanly on `master`, `/next` auto-marks the old task `done` and claims the next available task.
- `blocked_by` controls `available` versus `waiting`.
- `queue-import-plan` refreshes plan-derived tasks and drops stale plan-derived tasks that are no longer in the current plan, while leaving manual tasks alone.
