Read `~/configs/GLOBAL-AGENTS.md` (fallback: https://raw.githubusercontent.com/justinmoon/configs/master/GLOBAL-AGENTS.md). Skip if both unavailable.

Run `./scripts/agent-brief` first thing to get a live context snapshot.

# Agent Notes

## Workflow

- This repo uses git worktrees for implementation. Keep the root repo at `../..` on `master`, and do feature work from a worktree branch under `worktrees/`.
- Land changes to `master` only through the `land` skill or `scripts/land.sh`. Do not manually merge worktree branches into `master`.
- `scripts/land.sh` rebases the current worktree branch onto root `master`, runs `just pre-merge`, and only then fast-forwards the root `master` branch.
- Run `just pre-commit` during iteration for the fast local structural gate.
- Run `just nightly` for the slow superset lane that adds `ui-check` plus the real Pixel boot artifact cross-builds on top of `pre-merge`.
- Run `just ui-check` when working in the `ui/` workspace.
- Run `just smoke target=vm` when you want the same local VM shell/app smoke that backs `just pre-merge`.
- Use `just run target=vm` / `just stop target=vm` as the public VM session entry/exit path.
- Use `sc -t vm <subcommand>` for VM diagnostics, logs, screenshots, app open/home, SSH, and other VM control actions. Use `just shadowctl ...` only when the devshell `sc` alias is unavailable.
- Use `just pixel-ci <suite>` for rooted-Pixel CI subsets (`quick`, `shell`, `timeline`, `camera`, `nostr`, `sound`, `audio`, `podcast`, `runtime`, `full`).
- Use `sc -t pixel ci <suite>` / `sc -t pixel stage <suite>` for the underlying rooted-Pixel CI and artifact staging CLI. `just pixel-ci`, `just pixel-stage`, and `just pixel-run` are convenience wrappers.
- Use `sc root-prep` for host-side rooting assets and `sc -t pixel root-check`, `sc -t pixel root-patch`, `sc -t pixel root-flash`, or `sc -t pixel ota-sideload` for rooted-Pixel setup/recovery.
- Use `just run target=pixel ...` / `just stop target=pixel` for the supported rooted-Pixel shell lane. Explicit debug tooling should be reached through `sc -t pixel debug ...`, not ad hoc one-off scripts.

## Current Checks

- `just ui-check` runs formatting, core tests, and compositor/runtime compile checks for the `ui/` workspace.
- `just smoke target=vm` runs the required local VM shell/app smoke: timeline launch/home/reopen plus camera and podcast launch.
- `just smoke target=vm` keeps the VM lane local-only, artifact-driven, and free of guest-side Cargo/Rust while still resetting the runtime state image each run.
- `just run target=vm` / `just stop target=vm` are the public VM session entrypoints. VM inspection/control goes through `sc -t vm <subcommand>`.
- `scripts/shadowctl` is the target-aware operator CLI behind the public run/stop wrappers, VM diagnostics, and rooted-Pixel shell control recipes; use `-t vm`, `-t pixel`, or a specific Pixel serial as needed.
- `just pre-commit` runs script inventory, app metadata checks, recursive shell syntax checks, and lightweight operator/docs/justfile checks.
- `just pre-merge` runs `just pre-commit`, flake evaluation, runtime compile-and-test checks, lightweight rooted-Pixel init/tooling validation, and `just smoke target=vm`.
- `just nightly` runs `just pre-merge`, `just ui-check`, and the real `hello-init` / `orange-init` cross-builds.
- `just pixel-ci full` runs the current rooted-Pixel CI lane: timeline lifecycle, camera capture, runtime sound, runtime podcast playback, and the runtime Nostr timeline against a host-local relay over USB on a connected rooted device.
- `sc -t pixel ci <subset>` is the preferred ad hoc hardware gate for invasive app- or device-specific changes before landing; use a specific serial from `sc devices` when multiple Pixels are attached.
- `just pixel-ci <subset>` remains a convenience wrapper over that canonical CLI shape.
- `sc root-prep` prepares host-side Pixel rooting assets. Device-specific setup/recovery commands use `sc -t pixel ...` or a concrete serial.
- `scripts/ci/script_inventory.tsv` classifies every file under `scripts/`; update it when adding, moving, or deleting script-layer files.
- `just land` wraps `scripts/land.sh` and is the only allowed path to merge a worktree branch into the root `master`.
