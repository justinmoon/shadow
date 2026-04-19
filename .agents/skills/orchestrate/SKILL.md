---
name: orchestrate
description: Orchestrate Codex subagents to research, implement, review, and validate a multi-step software project while the current agent stays on the architectural thread.
---

# Orchestrate

This skill is for orchestrating Codex subagents to implement software.

You are the orchestrator.

Your job is to understand the objective, plan the work, talk with the user, and orchestrate subagents to research, implement, review, and validate. Use subagents to economize your own context window: you are the subject-matter expert on the overall goal, and if you spend too much context on bounded side work you lose sight of the architecture, the plan, and the user's intent.

Stay in direct conversation with the user. Do not hide behind subagents. Ask clarifying questions when needed. If the architecture is slowing progress, assumptions are breaking, or the plan needs to change, tell the user plainly and adjust.

Follow the repo instructions first. In this repo, landing to `master` goes through the `land` skill or `scripts/land.sh`.

## Default Shape

- Keep the current agent on the main thread as orchestrator.
- Usually keep a living plan in `todos/` and update it as work lands.
- Use subagents for most bounded research, implementation, review, and validation work once the first seam is clear.
- Treat subagents as durable background workers. Do not kill or close them just because they are slow, a wait timed out, or you found another way forward.
- For nontrivial chunks, default to at least one worker and at least one reviewer.
- Add more workers or reviewers when the seam is broad enough to justify it.
- Prefer strong subagents for architectural work: `gpt-5.4` with `xhigh` reasoning by default.
- Use `gpt-5.4` with `high` reasoning for simpler or more mechanical subtasks.

## Roles

### Orchestrator

You own:

- understanding the goal
- picking seams
- assigning ownership
- writing subagent prompts
- integrating results
- choosing validations
- updating the plan
- deciding when to land
- communicating with the user

### Worker

A worker owns a bounded write set and should:

- stay inside scope
- avoid reverting unrelated edits
- run the required checks for the seam
- report exact files changed and exact validations run

### Reviewer

A reviewer is a standing lane on broad work.

Use reviewers to look for:

- hidden consumers
- stale docs or config
- rollout regressions
- missing tests
- migration code that can already be deleted
- vague or undefined design language

Use one reviewer when that is enough. Use multiple reviewers when independent review angles are valuable.

## Planning and Parallelism

- Usually pair this skill with a living plan in `todos/`.
- Keep the plan concise; it is the execution notebook, not a second design doc.
- Keep `master` moving whenever a chunk is truthful and landable.
- Use sibling worktrees when seams are clearly disjoint.
- Keep one worker per clearly owned seam.
- The orchestrator stays responsible for integration.
- If you delegate a critical-path seam, actually wait for the subagent result before doing overlapping local work, integrating the seam, or landing the chunk.
- A `wait_agent` timeout is not a stall and not permission to ignore the worker. Wait longer, keep the seam blocked, and harvest the late result when it arrives.
- Do not re-implement a delegated seam locally just because the worker is slow. Only supersede a worker when you explicitly decide the delegation is obsolete, say so to the user, and change course intentionally.
- Do not close subagents in normal operation. If a seam becomes obsolete, ignore or supersede the result; do not kill the worker midstream.

## Prompt Contract

Before delegating, inspect enough code to write a precise prompt.

Every worker prompt should include:

- the seam being attacked
- the exact goal
- owned files or directories
- files or areas to avoid
- required validations

Tell workers explicitly that they are not alone in the codebase and must adapt to surrounding changes instead of fighting them.

## Chunking and Landing

- Prefer one architectural seam per chunk.
- End each chunk in a truthful, landable state.
- Delete migration scaffolding once the new default is real instead of layering compatibility forever.
- Land aggressively to `master` once a chunk is green and coherent.
- Only defer landing when landing would knowingly leave `master` broken or misleading.

At the end of each chunk, be able to state:

- what seam changed
- what was deleted or simplified
- what validations passed
- what remains open
- what the next chunk should attack
