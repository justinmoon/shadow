# Config Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

Related docs:

- [spec-scope.md](./spec-scope.md)
- [spec-target-config-shape.md](./spec-target-config-shape.md)
- [spec-migration.md](./spec-migration.md)

## Intent

- Replace the current ad hoc env-var sprawl with a small, explicit, typed config system.
- Keep the full repo in scope, including `PIXEL_*`, but prioritize the supported VM and rooted-Pixel shell/app-launch paths first.
- Preserve the repo's operator model: `just` and `shadowctl` stay thin entrypoints, while config becomes a first-class artifact instead of a pile of shell exports.

## Scope

- Cover all active configuration surfaces:
  - checked-in app metadata
  - generated host/session config
  - VM launch/session wiring
  - rooted-Pixel shell/runtime app/session wiring
  - runtime service config
  - build and dev-shell overrides
  - boot-lab and CI/debug knobs
- Define which inputs remain env vars, which move to config files, which should become CLI flags, and which should stay private/internal.
- Keep legacy compatibility only where it protects active workflows; do not preserve every historical env name forever.

## Approach

- Start by treating config as data with typed schemas and ownership, not as shell text.
- Keep `runtime/apps.json` as the checked-in catalog for static app metadata, but stop asking it to carry every run-time/session concern.
- Introduce generated per-run target/session config artifacts for the supported VM and Pixel lanes.
- Make host prep own config generation once, then let session binaries and compositors read typed config directly.
- Leave true process or OS boundary values as env vars where that remains the natural transport:
  - `WAYLAND_DISPLAY`
  - `XDG_RUNTIME_DIR`
  - dynamic loader and graphics-driver variables
  - one pointer to a generated config artifact when needed
- Split the migration into clear seams:
  - supported session paths first
  - runtime service config next
  - dev/build overrides next
  - boot-lab and CI/debug env cleanup after the supported surface is stable

## Steps

- [ ] Finish the repo-wide config taxonomy and freeze the new rules:
  - classify every active env family by role and owner
  - distinguish supported product config from debug, CI, and boot-lab knobs
  - publish one canonical policy for adding new config
- [ ] Define the canonical config artifacts and schemas:
  - app catalog schema
  - generated session config schema
  - service config sub-shapes
  - target override and debug overlay policy
- [ ] Make VM config artifact-driven end to end:
  - generate one canonical VM session config
  - stop reassembling the same values through multiple shell export files
  - keep the existing artifact manifest where it is already the right seam
- [ ] Make rooted-Pixel config artifact-driven end to end:
  - replace multiline `PIXEL_GUEST_*_ENV` payloads with structured config
  - stop using shell text blobs as the transport into guest startup
  - keep direct env only for true process-boundary values and low-level debug overrides
- [ ] Unify launcher-managed app/window/runtime wiring:
  - converge on one canonical app/window namespace
  - retire `SHADOW_BLITZ_*` compatibility shims on a controlled schedule
  - keep generated metadata and launchers in lockstep
- [ ] Move runtime service config behind typed session/service config:
  - camera
  - nostr
  - cashu
  - audio
  - clipboard/mock hooks
- [ ] Define the long-tail policy for `PIXEL_*`, `SHADOW_*`, and debug/test knobs:
  - keep private boot-lab and smoke-only overrides explicit and documented
  - reduce uncontrolled growth in `scripts/lib/pixel_common.sh`
  - move operator-grade config up into `shadowctl` or typed helpers where it belongs
- [ ] Add validation and observability:
  - schema validation for generated config
  - smoke coverage for config generation and consumption
  - one inventory/report command or doc entrypoint for discoverability

## Checkpoint Status

- 2026-04-20: VM host prep now stages a typed `session-config.json` next to `artifact-manifest.json`.
- 2026-04-20: VM guest startup validates the runtime manifest and session config together, then treats the session config as the primary source of runtime/service/startup state.
- 2026-04-20: the legacy VM env export file remains in place only as a compatibility/debug overlay while the compositor and launcher internals still expect env projection.
- 2026-04-20: `scripts/ci/app_metadata_manifest_smoke.sh` and `just smoke target=vm` cover generation and guest consumption of the new artifact.

## Implementation Notes

- Current repo reality:
  - `runtime/apps.json` is already the strongest config seam in the repo.
  - VM is now artifact-driven through a generated session config, but still retains an env projection layer for compositor/runtime compatibility.
  - rooted Pixel still relies heavily on shell-built env payloads and wrapper translation layers.
  - guest startup config parsing is typed once it reaches Rust, but the transport into it is still stringly.
- Working migration rule:
  - do not start by normalizing every `PIXEL_*` boot/debug/test knob.
  - first fix the supported session surface where config crosses multiple layers and multiple languages.
- Planned companion specs:
  - `spec-scope.md` fixes taxonomy and policy.
  - `spec-target-config-shape.md` defines the desired config model.
  - `spec-migration.md` defines the phased path from current env-heavy wiring to typed config artifacts.
