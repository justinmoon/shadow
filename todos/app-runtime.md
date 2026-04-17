# App Runtime Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Keep the runtime app platform usable for real apps.
- Track cross-app runtime seams only: app lifecycle, viewport, input, app-host protocol, OS API shape, and validation lanes.
- Do not track individual app feature work here. Cashu wallet work lives in `todos/cashu.md`; camera integration lives in `todos/camera-rs.md`; GPU/device rendering lives in `todos/gpu.md`.
- Current platform posture: good enough for real app iteration, but still pre-alpha.

## Approach

- Keep TS/TSX app modules, Solid-style authoring, and `{ html, css }` render snapshots for now.
- Keep Rust in charge of the outer frame, app lifecycle, native integration, and runtime-host extensions.
- Prefer concrete domain APIs under `Shadow.os.<domain>` until multiple domains force a shared capability convention.
- Validate the platform through the supported operator lanes:
  - `just runtime-app-host-smokes` for host runtime contracts.
  - `just smoke target=vm` for VM shell lifecycle.
  - `just pixel-ci <suite>` for rooted-Pixel hardware subsets.

## Milestones

- [x] Make the runtime operator and docs surface truthful.
- [x] Unify runtime viewport sizing across host, VM, compositor launch, and Pixel.
- [x] Cover the main input gaps: keyboard, focus, selection metadata, wheel scroll, pan scroll, and synthetic-click cancellation.
- [x] Move Pixel runtime validation toward the real shell lane instead of direct one-off runtime probes.
- [x] Prove multiple real OS domains: `nostr`, `camera`, `cashu`, and `audio`.
- [x] Consolidate host runtime smokes behind `just runtime-app-host-smokes`.
- [ ] Move app/runtime metadata to one manifest so adding an app is not a Rust + TS + shell + Pixel staging edit.
- [ ] Revisit shared capability conventions after more app code uses the current concrete domains.

## Near-Term Steps

- [ ] Implement the app metadata manifest described in `todos/app-metadata.md`.
- [ ] Keep `just runtime-app-host-smokes`, `just smoke target=vm`, and relevant `just pixel-ci <suite>` coverage updated as apps become real.
- [ ] Close this plan when app metadata is single-source and the current runtime platform no longer has cross-app drift.

## Implementation Notes

- `deno_core` remains the pragmatic runtime helper. `deno_runtime` is proven but not promoted.
- The current JS app contract is still `{ html, css? }` snapshots plus app-owned event target ids.
- Host wheel and pan scrolling currently live in the Blitz document layer rather than the JS runtime event schema.
- The old direct rooted-Pixel runtime-app probes were pruned. Current device validation should use the shell lane or `just pixel-ci <suite>`.
- Cashu remaining work moved to `todos/cashu.md` because it is app/product work now, not platform bring-up.
- App metadata duplication is now the main platform cleanup seam.

## Related Plans

- `todos/app-metadata.md`: single-source app/runtime metadata.
- `todos/cashu.md`: Cashu wallet product hardening.
- `todos/camera-rs.md`: rooted-Pixel camera provider and runtime camera app.
- `todos/gpu.md`: rooted-Pixel GPU rendering and interaction quality.
- `todos/compositor.md`: guest compositor decomposition.
