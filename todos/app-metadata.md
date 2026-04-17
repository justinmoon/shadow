# App Metadata Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Make app/runtime metadata single-source.
- Adding or renaming an app should not require coordinated edits across Rust app registry, TypeScript bundle prep, shell helpers, Pixel staging scripts, and `shadowctl`.
- Cover supported shell apps first: `counter`, `camera`, `timeline`, `podcast`, and `cashu`.
- Carry the remaining cross-app runtime-platform cleanup context now that the old parent runtime plan is retired.

## Approach

- Introduce one repo-owned manifest: `runtime/apps.json`.
- Store app id, title, icon label, subtitle, Wayland app id, window title, TSX entrypoint, default cache dirs, bundle env name, bundle filename, default config, and profile membership in that manifest.
- Generate or load derived metadata for Rust and scripts instead of maintaining parallel tables.
- Check in generated Rust metadata and enforce drift in `just pre-commit`.
- Keep the first version boring: static metadata only, no plugin system.

## Runtime Platform Context

- Current runtime posture: usable for real app iteration, but still pre-alpha.
- Keep TS/TSX app modules, Solid-style authoring, and `{ html, css }` render snapshots for now.
- Keep Rust in charge of the outer frame, app lifecycle, native integration, and runtime-host extensions.
- Prefer concrete domain APIs under `Shadow.os.<domain>` until multiple domains force a shared capability convention.
- Cross-app runtime seams are app lifecycle, viewport, input, app-host protocol, OS API shape, metadata, and validation lanes.
- App product work belongs in the matching app plan: Cashu in `todos/cashu.md`, camera in `todos/camera-rs.md`, GPU/device rendering in `todos/gpu.md`, and sound in `todos/sound.md`.

## Agent Handoff

- This is the highest-leverage next cleanup and should have one primary owner because it is cross-cutting.
- First deliverable should be an explicit inventory plus chosen manifest schema before broad rewrites.
- Likely write areas: `runtime/`, `scripts/runtime/runtime_build_artifacts.ts`, `scripts/pixel/`, `scripts/lib/session_apps.txt`, `scripts/shadowctl`, and `ui/crates/shadow-ui-core/src/app.rs`.
- Treat `scripts/runtime/runtime_build_artifacts.ts` as the staging nucleus because VM and Pixel artifact prep both already flow through it.
- Do not create a plugin framework, dynamic app registry, or package manager. This is static repo metadata for known supported apps.
- Decide early whether generated Rust/script artifacts are checked in or generated during checks. Whichever choice lands must have a drift check.
- Avoid changing unrelated app behavior while moving metadata. The goal is fewer coordinated edits, not new runtime features.
- If adding generator scripts, classify them in the script inventory and keep `scripts/` organized.
- Validate with `just pre-commit`; use `just smoke target=vm` once shell app launch metadata changes; use a targeted `just pixel-ci <suite>` only if Pixel staging behavior changes.
- Keep `just runtime-app-host-smokes`, `just smoke target=vm`, and relevant `just pixel-ci <suite>` coverage updated as apps become real.

## Milestones

- [x] Inventory every current metadata copy site.
- [x] Choose manifest format and schema.
- [x] Teach `shadow-ui-core` to consume generated Rust metadata or generated Rust constants from the manifest.
- [x] Teach `scripts/runtime/runtime_build_artifacts.ts` to build app specs from the manifest.
- [x] Teach Pixel shell artifact prep to copy/fingerprint bundles by manifest entries instead of one hardcoded block per app.
- [x] Replace `scripts/lib/session_apps.txt` and `shadowctl` app allowlists with manifest-derived data.
- [x] Add a pre-commit drift check so app metadata cannot diverge again.

## Near-Term Steps

- [x] Start with a read-only manifest that mirrors today’s app data.
- [x] Add an inventory note listing every duplicate metadata site and the field names copied there.
- [x] Choose checked-in generation vs check-time generation and document why.
- [x] Generate a checked or ephemeral Rust module and prove `ui-check` still passes.
- [x] Convert `runtime_build_artifacts.ts` next; it is the best staging nucleus because VM and Pixel both already pass through it.
- [x] Convert Pixel shell artifact prep last, after the generated manifest includes bundle filenames and guest/device paths.

## Implementation Notes

- Current duplicated metadata lives in `ui/crates/shadow-ui-core/src/app.rs`, `scripts/runtime/runtime_build_artifacts.ts`, `scripts/pixel/pixel_prepare_shell_runtime_artifacts.sh`, `scripts/lib/session_apps.txt`, and `scripts/shadowctl`.
- The current supported shell app set is `counter`, `camera`, `timeline`, `podcast`, and `cashu`.
- Metadata changes can conflict with app agents. Coordinate app id, bundle filename, runtime config, and profile membership changes before landing.
- This is an iteration-speed project. The goal is fewer coordinated edits when adding apps, not a general app packaging framework.
- Keep app-specific product behavior out of the metadata manifest unless multiple apps need the same field.
- `deno_core` remains the pragmatic runtime helper. `deno_runtime` is proven but not promoted.
- The current JS app contract is still `{ html, css? }` snapshots plus app-owned event target ids.
- Host wheel and pan scrolling currently live in the Blitz document layer rather than the JS runtime event schema.
- The old direct rooted-Pixel runtime-app probes were pruned. Current device validation should use the shell lane or `just pixel-ci <suite>`.
- App metadata duplication is now the main platform cleanup seam.
- `runtime/apps.json` now owns shell app ids, titles, labels, Wayland ids, window titles, TSX entrypoints, VM/Pixel shell cache dirs, bundle env names, bundle filenames, profile membership, icon colors, timeline default config, and the podcast fixture asset resolver marker.
- `scripts/runtime/generate_app_metadata.py` writes `ui/crates/shadow-ui-core/src/generated_apps.rs`; `scripts/pre_commit.sh` runs it with `--check` to prevent Rust metadata drift.
- `scripts/runtime/runtime_build_artifacts.ts` now builds `vm-shell` and `pixel-shell` app specs from the manifest. Its single-app default picks the first manifest app that actually supports `vm-shell` and has a `vm-shell` cache dir instead of hardcoding counter.
- `scripts/lib/session_apps.sh` and `scripts/shadowctl` now derive supported shell apps from `runtime/apps.json`; `scripts/lib/session_apps.txt` was deleted. Both helpers now enforce profile membership per target instead of accepting the union of VM and Pixel apps.
- `scripts/lib/pixel_common.sh` derives Pixel shell bundle env lines, bundle filenames, and device destinations from the manifest and only enumerates `pixel-shell` apps for staging.
- `scripts/pixel/pixel_prepare_shell_runtime_artifacts.sh` now loops over manifest app entries for shell bundle copy, host bundle fingerprinting, cache checks, and summary output.
- `runtime/apps.json` remains the single source of truth for `shell.id`; VM and Pixel wrappers now load that id from manifest-derived helpers instead of hardcoding `"shell"`.
- Manifest validation now rejects duplicate app ids, Wayland ids, bundle env names, and bundle filenames in both `scripts/runtime/generate_app_metadata.py` and `scripts/runtime/runtime_build_artifacts.ts`.
- `ui/crates/shadow-ui-core/src/app.rs` now filters `home_apps()` and manifest-backed app lookups by `SHADOW_SESSION_APP_PROFILE`, with profile-specific generated arrays from `ui/crates/shadow-ui-core/src/generated_apps.rs` so the shell UI cannot advertise VM-only apps on Pixel or Pixel-only apps on VM.
- VM and Pixel session env export now carries `SHADOW_SESSION_APP_PROFILE` into the compositor process, so the shell and launch validation read the same active target profile.
- Direct non-shell runtime lanes still have app-specific test inputs and suite membership by design; those are validation wrappers rather than the shared shell app metadata registry.
- Validation passed: `scripts/ci/app_metadata_manifest_smoke.sh`, `scripts/ci/operator_cli_smoke.sh`, `just pre-commit`, and `just pre-merge` all completed successfully, including the VM smoke for timeline, camera, and podcast.
