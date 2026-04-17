# App Metadata Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Make app/runtime metadata single-source.
- Adding or renaming an app should not require coordinated edits across Rust app registry, TypeScript bundle prep, shell helpers, Pixel staging scripts, and `shadowctl`.
- Cover supported shell apps first: `counter`, `camera`, `timeline`, `podcast`, and `cashu`.

## Approach

- Introduce one repo-owned manifest, likely `runtime/apps.toml` or `runtime/apps.json`.
- Store app id, title, icon label, subtitle, Wayland app id, window title, TSX entrypoint, default cache dirs, bundle env name, bundle filename, default config, and profile membership in that manifest.
- Generate or load derived metadata for Rust and scripts instead of maintaining parallel tables.
- Keep the first version boring: static metadata only, no plugin system.

## Milestones

- [ ] Inventory every current metadata copy site.
- [ ] Choose manifest format and schema.
- [ ] Teach `shadow-ui-core` to consume generated Rust metadata or generated Rust constants from the manifest.
- [ ] Teach `scripts/runtime/runtime_build_artifacts.ts` to build app specs from the manifest.
- [ ] Teach Pixel shell artifact prep to copy/fingerprint bundles by manifest entries instead of one hardcoded block per app.
- [ ] Replace `scripts/lib/session_apps.txt` and `shadowctl` app allowlists with manifest-derived data.
- [ ] Add a pre-commit drift check so app metadata cannot diverge again.

## Near-Term Steps

- [ ] Start with a read-only manifest that mirrors today’s app data.
- [ ] Generate a checked or ephemeral Rust module and prove `ui-check` still passes.
- [ ] Convert `runtime_build_artifacts.ts` next; it is the best staging nucleus because VM and Pixel both already pass through it.
- [ ] Convert Pixel shell artifact prep last, after the generated manifest includes bundle filenames and guest/device paths.

## Implementation Notes

- Current duplicated metadata lives in `ui/crates/shadow-ui-core/src/app.rs`, `scripts/runtime/runtime_build_artifacts.ts`, `scripts/pixel/pixel_prepare_shell_runtime_artifacts.sh`, `scripts/lib/session_apps.txt`, and `scripts/shadowctl`.
- This is an iteration-speed project. The goal is fewer coordinated edits when adding apps, not a general app packaging framework.
- Keep app-specific product behavior out of the metadata manifest unless multiple apps need the same field.

