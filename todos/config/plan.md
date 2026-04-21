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
- 2026-04-20: the supported VM session now exports `SHADOW_RUNTIME_SESSION_CONFIG` into the compositor/app process tree so runtime services can read the mounted `session-config.json` directly instead of depending only on reprojected env.
- 2026-04-20: VM nostr and cashu service path resolution is now config-first through `session-config.json`, with `SHADOW_RUNTIME_NOSTR_*` / `SHADOW_RUNTIME_CASHU_*` env preserved as compatibility fallback for non-VM and host-smoke lanes.
- 2026-04-20: `scripts/ci/ui_vm_smoke.sh` now injects conflicting runtime Nostr/Cashu path env overrides and proves the live VM session still uses the config-backed Nostr DB/socket, signer policy, and cashu data paths.
- 2026-04-20: `shadow-system` audio backend selection is now config-first through `services.audioBackend` in `session-config.json`, with `SHADOW_RUNTIME_AUDIO_BACKEND` kept as compatibility fallback for non-session and explicit override lanes.
- 2026-04-20: `scripts/ci/runtime_app_sound_smoke.sh` now injects a conflicting `SHADOW_RUNTIME_AUDIO_BACKEND=linux_spike` override alongside `SHADOW_RUNTIME_SESSION_CONFIG` and proves the host runtime still uses the config-backed `memory` backend.
- 2026-04-20: rooted Pixel shell/runtime launch now stages a typed `guest-startup.json` artifact on-device instead of shipping startup state through sourced shell export blobs.
- 2026-04-20: `shadow-compositor-guest` now requires `schemaVersion` in the typed guest config and treats direct env as a compatibility/debug overlay that merges onto file-provided client env.
- 2026-04-20: the supported rooted-Pixel path now keeps env projection only for process-boundary values and compatibility holdouts such as app bundle envs, profile selection, socket modes, and explicit debug overrides.
- 2026-04-20: `scripts/ci/pixel_guest_startup_config_smoke.sh` and `just pre-commit` now cover rooted-Pixel startup-config generation plus env projection filtering.
- 2026-04-20: rooted Pixel shell/runtime launch now compiles a typed host-side `guest-run-config.json` superset and passes that artifact into `pixel_guest_ui_drm.sh` instead of multiline `PIXEL_GUEST_CONFIG_*` payloads.
- 2026-04-20: the same rooted-Pixel `guest-run-config.json` now serves as both the host takeover/verification session description and the on-device `SHADOW_GUEST_SESSION_CONFIG`, with host-driver staging controls intentionally left outside the file.

## Implementation Notes

- Current repo reality:
  - `runtime/apps.json` is already the strongest config seam in the repo.
  - VM is now artifact-driven through a generated session config, and the supported runtime service slice now reads that config directly through `SHADOW_RUNTIME_SESSION_CONFIG` while env remains as a compatibility/debug overlay.
  - rooted Pixel guest startup is now typed and artifact-driven, and the supported shell/runtime-app host lane now compiles a single `guest-run-config.json` artifact instead of cross-script multiline env payloads.
  - guest startup config parsing is now file-first in Rust with explicit schema/version checks; env remains an overlay seam rather than the primary transport, and host-driver-only concerns still stay env-based for now.
- Working migration rule:
  - do not start by normalizing every `PIXEL_*` boot/debug/test knob.
  - first fix the supported session surface where config crosses multiple layers and multiple languages.
- Planned companion specs:
  - `spec-scope.md` fixes taxonomy and policy.
  - `spec-target-config-shape.md` defines the desired config model.
  - `spec-migration.md` defines the phased path from current env-heavy wiring to typed config artifacts.
