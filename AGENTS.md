Read `~/configs/GLOBAL-AGENTS.md` (fallback: https://raw.githubusercontent.com/justinmoon/configs/master/GLOBAL-AGENTS.md). Skip if both unavailable.

Run `./scripts/agent-brief` first thing to get a live context snapshot.

# Agent Notes

## Workflow

- Run `just pre-commit` during iteration for the fast local gate.
- Run `just ci` when you finish a feature, before handoff, and before claiming the repo is green.
- Treat `just ci` as the canonical full verification command for this repo and extend it as the project grows.

## Current Checks

- `just pre-commit` runs shell syntax checks, flake evaluation, stock artifact fetch, identity repack, and a byte-for-byte assertion between stock and repacked `init_boot.img`.
- `just ci` runs `just pre-commit` plus the Hetzner-backed stock and repacked Cuttlefish boot smokes.
