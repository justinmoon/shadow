Read `~/configs/GLOBAL-AGENTS.md` (fallback: https://raw.githubusercontent.com/justinmoon/configs/master/GLOBAL-AGENTS.md). Skip if both unavailable.

Run `./scripts/agent-brief` first thing to get a live context snapshot.

# Agent Notes

## Workflow

- Run `just pre-commit` during iteration for the fast local gate.
- Run `just ui-check` when working in the `ui/` workspace.
- Run `just ui-smoke` when you change compositor/app launch behavior and need the Linux runtime proof.
- Use `just ui-vm-run` / `just ui-vm-*` for local macOS QEMU iteration when you want a faster UX loop than Cuttlefish.
- Run `just ci` when you finish a feature, before handoff, and before claiming the repo is green.
- Treat `just ci` as the canonical full verification command for this repo and extend it as the project grows.

## Current Checks

- `just ui-check` runs formatting, core tests, and desktop/compositor compile checks for the `ui/` workspace.
- `just ui-smoke` runs a headless Linux/Hetzner compositor smoke: start `shadow-compositor`, auto-launch `shadow-counter`, and assert the client configures and maps.
- `just ui-vm-*` drives the local macOS QEMU compositor VM loop. It is an operator workflow, not a CI gate.
- `just pre-commit` runs shell syntax checks, flake evaluation, `just ui-check`, stock artifact fetch, identity repack, and a byte-for-byte assertion between stock and repacked `init_boot.img`.
- `just ci` runs `just pre-commit`, `just ui-smoke`, and the Hetzner-backed stock, repacked, wrapper, and guest compositor/client Cuttlefish boot smokes.
