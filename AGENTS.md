Read `~/configs/GLOBAL-AGENTS.md` (fallback: https://raw.githubusercontent.com/justinmoon/configs/master/GLOBAL-AGENTS.md). Skip if both unavailable.

Run `./scripts/agent-brief` first thing to get a live context snapshot.

# Agent Notes

## Workflow

- This repo uses git worktrees for implementation. Keep the root repo at `../..` on `master`, and do feature work from a worktree branch under `worktrees/`.
- Land changes to `master` only through the `land` skill or `scripts/land.sh`. Do not manually merge worktree branches into `master`.
- `scripts/land.sh` rebases the current worktree branch onto root `master`, runs `just pre-merge`, and only then fast-forwards the root `master` branch.
- Run `just pre-commit` during iteration for the fast local gate.
- Run `just ui-check` when working in the `ui/` workspace.
- Run `just ui-vm-smoke` or `just vm-smoke` when you want the same local VM shell/app smoke that backs `just pre-merge`.
- Run `just ui-smoke` only when you explicitly want the Linux-host proof outside the required CI gate.
- Use `just run target=vm` / `just stop target=vm` as the public VM session entry/exit path. `vm-*` and older `ui-vm-*` aliases still work.
- Use `just pixel-ci <suite>` for rooted-Pixel CI subsets (`quick`, `shell`, `timeline`, `camera`, `nostr`, `sound`, `podcast`, `runtime`, `full`).
- Use `just run target=pixel ...` / `just stop target=pixel` for the supported rooted-Pixel shell lane. Lower-level runtime/probe commands still exist for narrower debugging.
- Run `just pre-merge` before handoff and before claiming the repo is green.

## Current Checks

- `just ui-check` runs formatting, core tests, and compositor/runtime compile checks for the `ui/` workspace.
- `just ui-vm-smoke` / `just vm-smoke` run the required local VM shell/app smoke: timeline launch/home/reopen plus camera and podcast launch.
- `just ui-smoke` remains the manual Linux compositor smoke outside the required CI gate.
- `just run target=vm` / `just stop target=vm` are the public VM session entrypoints. `vm-*` drives the rest of the local macOS QEMU VM loop, and `ui-vm-*` remains as compatibility aliases.
- `scripts/shadowctl` is the target-aware operator CLI behind the public run/stop wrappers, VM diagnostics, and rooted-Pixel shell control recipes; use `-t vm`, `-t pixel`, or a specific Pixel serial as needed.
- `just pre-commit` runs shell syntax checks, flake evaluation, and `just ui-check`.
- `just pre-merge` runs `just pre-commit` and `just ui-vm-smoke`.
- `just pixel-ci full` runs the current rooted-Pixel CI lane: timeline lifecycle, camera capture, runtime sound, runtime podcast playback, and the runtime Nostr timeline against a host-local relay over USB on a connected rooted device.
- `just pixel-ci <subset>` is the preferred ad hoc hardware gate for invasive app- or device-specific changes before landing.
- `just land` wraps `scripts/land.sh` and is the only allowed path to merge a worktree branch into the root `master`.
