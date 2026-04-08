Read `~/configs/GLOBAL-AGENTS.md` (fallback: https://raw.githubusercontent.com/justinmoon/configs/master/GLOBAL-AGENTS.md). Skip if both unavailable.

Run `./scripts/agent-brief` first thing to get a live context snapshot.

# Agent Notes

## Workflow

- This repo uses git worktrees for implementation. Keep the root repo at `../..` on `master`, and do feature work from a worktree branch under `worktrees/`.
- Land changes to `master` only through the `land` skill or `scripts/land.sh`. Do not manually merge worktree branches into `master`.
- `scripts/land.sh` rebases the current worktree branch onto root `master`, runs `just pre-merge`, and only then fast-forwards the root `master` branch.
- Run `just pre-commit` during iteration for the fast local gate.
- Run `just ui-check` when working in the `ui/` workspace.
- Run `just ui-smoke` when you change compositor/app launch behavior and need the Linux runtime proof.
- Use `just ui-vm-run` / `just ui-vm-*` for local macOS QEMU iteration.
- Use `just pixel-runtime-app-drm` / `just pixel-runtime-app-drm-hold` / `just pixel-restore-android` for the rooted Pixel path.
- Run `just pre-merge` before handoff and before claiming the repo is green.

## Current Checks

- `just ui-check` runs formatting, core tests, and compositor/runtime compile checks for the `ui/` workspace.
- `just ui-smoke` runs a headless Linux compositor smoke with the Blitz runtime app.
- `just ui-vm-*` drives the local macOS QEMU VM loop. It is an operator workflow, not a CI gate.
- `scripts/shadowctl` is the flat operator CLI behind the VM diagnostics and rooted-Pixel shell control recipes; use `-t vm` or a Pixel serial as needed.
- `just pre-commit` runs shell syntax checks, flake evaluation, and `just ui-check`.
- `just pre-merge` runs `just pre-commit` and `just ui-smoke`.
- `just nightly` currently mirrors `just pre-merge` until heavier lanes land.
- `just land` wraps `scripts/land.sh` and is the only allowed path to merge a worktree branch into the root `master`.
