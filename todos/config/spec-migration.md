# Config Migration

Status: in progress

This document stages the move from the current env-heavy system to the target config model.

## Phase 0: Inventory And Freeze

Goals:

- finish the taxonomy
- stop digging the hole deeper

Deliverables:

- one documented policy for new config fields
- one inventory of env families and their intended classification
- no new supported-surface config added as free-form shell text blobs

Exit criteria:

- the supported VM and Pixel session paths have an agreed target schema and owner map

## Phase 1: Canonical Session Config Generation

Goals:

- generate one canonical target/session config artifact for VM
- reuse the same generation model for Pixel

Deliverables:

- session config schema and validator
- config generation in host prep / `shadowctl`
- artifact manifest and session config clearly separated by purpose

Exit criteria:

- VM launch can be explained in terms of one generated config artifact plus a small env projection

Current checkpoint:

- VM host prep now generates `session-config.json` next to `artifact-manifest.json`.
- The generated config already carries startup app selection, runtime bundle mapping, service paths, and system binary wiring for the supported VM lane.

## Phase 2: VM Consumption Cleanup

Goals:

- stop reassembling VM session state through multiple export files

Deliverables:

- `shadow-compositor` reads typed launch/session config
- VM guest/session startup uses generated config instead of shell-derived duplication
- launcher-managed app/window fields come from one canonical source

Exit criteria:

- VM no longer depends on duplicated launch-time env assembly as the primary model

Current checkpoint:

- The VM guest now validates and consumes `session-config.json` as the primary startup source.
- The legacy VM env export file is still staged, but only as a compatibility/debug overlay while compositor/runtime internals are still env-based.
- The supported VM session now exports the mounted `session-config.json` path through `SHADOW_RUNTIME_SESSION_CONFIG` so runtime services can resolve typed service paths directly.
- VM nostr and cashu now resolve service paths from `services.*` in `session-config.json` before falling back to `SHADOW_RUNTIME_NOSTR_*` / `SHADOW_RUNTIME_CASHU_*`.
- `scripts/ci/ui_vm_smoke.sh` now stages conflicting runtime Nostr/Cashu path env overrides and proves the live VM still uses the config-backed DB/socket/signer-policy/data-dir paths.

## Phase 3: Pixel Supported-Surface Cleanup

Goals:

- remove shell text as the structured transport for guest startup

Current pain point:

- `pixel_shell_drm.sh` and `pixel_runtime_app_drm.sh` build multiline env payloads
- `pixel_guest_ui_drm.sh` mutates them further
- `shadow-session` and `shadow-compositor-guest` reconstruct typed state only after the string transport

Current checkpoint:

- `pixel_guest_ui_drm.sh` now stages a typed `guest-startup.json` artifact on-device for the supported shell/runtime-app path.
- `shadow-compositor-guest` now loads that file first through `SHADOW_GUEST_SESSION_CONFIG`, validates `schemaVersion`, and only then applies direct env as a compatibility/debug overlay.
- the supported rooted-Pixel launcher no longer pushes sourced startup export blobs or a device-side wrapper just to reconstruct guest startup state.
- the supported rooted-Pixel host launchers now compile a typed `guest-run-config.json` superset and pass that single artifact into `pixel_guest_ui_drm.sh` instead of multiline `PIXEL_GUEST_CONFIG_*` / overlay env payloads.
- `pixel_guest_ui_drm.sh` now treats that host-side file as the source of truth for guest startup plus takeover/verification session policy, then pushes the same file on-device as `SHADOW_GUEST_SESSION_CONFIG`.
- `pixel_guest_ui_drm.sh` now also exports that same staged file into the runtime tree through `SHADOW_RUNTIME_SESSION_CONFIG`, so Pixel runtime services can consume typed config directly instead of relying only on reprojected env.
- remaining env projection on the supported Pixel path is explicit:
  - process-boundary values such as `XKB_CONFIG_ROOT`, `SHADOW_RUNTIME_DIR`, `SHADOW_GUEST_COMPOSITOR_BIN`, `SHADOW_GUEST_COMPOSITOR_ENABLE_DRM`, and the config pointer
  - host-driver staging controls such as artifact directories, run-dir selection, skip-push, and optional runtime summary generation
  - app-profile and control-socket compatibility vars such as `SHADOW_SESSION_APP_PROFILE` and `SHADOW_COMPOSITOR_CONTROL_SOCKET_MODE`
  - shell app bundle envs that still exist until runtime bundle lookup is fully config-backed
  - deliberate debug overrides such as `SHADOW_GUEST_KEYBOARD_SEAT` and `SHADOW_GUEST_COMPOSITOR_GPU_PROFILE_TRACE`
  - compatibility runtime-service env such as `SHADOW_RUNTIME_CAMERA_*`, now derived from typed Pixel service config instead of authored as the primary transport

Deliverables:

- generated Pixel session config artifact
- `shadow-session` loads config directly
- `shadow-compositor-guest` loads typed guest startup config from that artifact
- `PIXEL_GUEST_CLIENT_ENV` / `PIXEL_GUEST_SESSION_ENV` reduced or removed from the supported path

Exit criteria:

- Pixel shell and runtime-app launch no longer require multiline env blobs to cross layers

## Phase 4: Service Config Consolidation

Goals:

- make service config an explicit sub-tree of session config

Deliverables:

- camera config projection
- nostr config projection
- cashu config projection
- audio config projection
- migration shims for current env readers where needed

Exit criteria:

- service paths and policies are visible in one config artifact instead of spread across independent env lookups

Current checkpoint:

- VM/runtime service config is now config-first for Nostr DB/socket, Cashu data dir, audio backend, and camera policy through `services.*` in `session-config.json`.
- `SHADOW_RUNTIME_NOSTR_*`, `SHADOW_RUNTIME_CASHU_*`, `SHADOW_RUNTIME_AUDIO_BACKEND`, and `SHADOW_RUNTIME_CAMERA_*` remain as compatibility fallbacks while non-VM and ad hoc host lanes finish migrating.
- `scripts/ci/runtime_app_sound_smoke.sh` now proves that `SHADOW_RUNTIME_SESSION_CONFIG` beats a conflicting `SHADOW_RUNTIME_AUDIO_BACKEND=linux_spike` override on the host runtime session path.
- `scripts/ci/runtime_app_camera_smoke.sh` now proves that `SHADOW_RUNTIME_SESSION_CONFIG` beats conflicting `SHADOW_RUNTIME_CAMERA_ALLOW_MOCK=0` and `SHADOW_RUNTIME_CAMERA_ENDPOINT=127.0.0.1:1` overrides on the host runtime session path.
- The supported rooted-Pixel shell/runtime-app path now carries service config in the staged guest-run/startup artifact, exports that file through `SHADOW_RUNTIME_SESSION_CONFIG`, and scrubs legacy Nostr/Cashu/Camera runtime-service env from generated client assignments instead of projecting it back into the supported path.

## Phase 5: Namespace And Compatibility Cleanup

Goals:

- collapse legacy duplication carefully

Deliverables:

- no new canonical `SHADOW_BLITZ_*` fields
- staged removal schedule for compatibility reads
- one canonical app/window namespace

Exit criteria:

- supported app/window/session fields exist in one namespace with compatibility only where still justified

## Phase 6: Long-Tail `PIXEL_*` Rationalization

Goals:

- reduce uncontrolled growth in Pixel/private/debug config

Deliverables:

- supported Pixel operator inputs separated from private boot/debug/test inputs
- `shadowctl` owns more operator-grade config explicitly
- `scripts/lib/pixel_common.sh` stops being the default place new config grows

Exit criteria:

- `PIXEL_*` still exists, but it is clearly segmented into supported operator config and private/debug/test config

## Non-Blocking Long Tail

These should follow the supported-surface cleanup, not block it:

- boot-lab `PIXEL_BOOT_*` normalization
- CI-only timing knobs
- test-only mock env cleanup
- Cuttlefish legacy cleanup

## Migration Rules

- Keep schema versioning from the first generated config artifact.
- Prefer additive compatibility shims first, then removal after the supported path is green.
- Do not require a repo-wide big bang.
- Every migration seam should leave the current supported VM and Pixel lanes runnable.
