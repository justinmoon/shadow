Read `~/configs/GLOBAL-AGENTS.md` (fallback: https://raw.githubusercontent.com/justinmoon/configs/master/GLOBAL-AGENTS.md). Skip if both unavailable.

Run `./scripts/agent-brief` first thing to get a live context snapshot.

# Agent Notes

## Workflow

- Run `just pre-commit` during iteration for the fast local gate.
- Run `just ui-check` when working in the `ui/` workspace.
- Run `just ui-smoke` when you change compositor/app launch behavior and need the Linux runtime proof.
- Use `just ui-vm-run` / `just ui-vm-*` for local macOS QEMU iteration.
- Use `just pixel-runtime-app-drm` / `just pixel-runtime-app-drm-hold` / `just pixel-restore-android` for the rooted Pixel path.
- Run `just ci` before handoff and before claiming the repo is green.

## Current Checks

- `just ui-check` runs formatting, core tests, and compositor/runtime compile checks for the `ui/` workspace.
- `just ui-smoke` runs a headless Linux compositor smoke with the Blitz runtime app.
- `just ui-vm-*` drives the local macOS QEMU VM loop. It is an operator workflow, not a CI gate.
- `scripts/shadowctl` is the operator CLI behind the `just ui-vm-*` diagnostics and control recipes.
- `just pre-commit` runs shell syntax checks, flake evaluation, and `just ui-check`.
- `just ci` runs `just pre-commit` and `just ui-smoke`.
