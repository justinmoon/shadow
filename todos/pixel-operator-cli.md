# Pixel Operator CLI Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Intent

- Finish the remaining private helper cleanup behind the rooted-Pixel operator surface.
- Make `scripts/shadowctl` the home for public/operator behavior and shrink `scripts/lib/pixel_common.sh` into a compatibility shim plus low-level helper libraries.

## Scope

- In scope:
  - `scripts/shadowctl`
  - `scripts/lib/pixel_common.sh` and extracted Pixel helper libs
  - private Pixel scripts under `scripts/pixel/`, `scripts/ci/`, and `scripts/debug/` when their operator flow is being migrated
- Out of scope:
  - compositor architecture work
  - broad UX changes to the supported `just` / `shadowctl` surface
  - rewriting Pixel automation out of bash wholesale

## Approach

- Keep `pixel_common.sh` source-compatible while migration is in flight.
- Move user-facing routing, validation, and orchestration into `shadowctl`.
- Keep low-level `adb` / `fastboot` / root-shell / path helpers in smaller sourced libs.
- Split by cohesive behavior clusters, not by arbitrary line ranges.
- Validate public-surface changes with `scripts/ci/operator_cli_smoke.sh`; add boot-lab or Pixel shell smokes only when the touched flow needs them.

## Steps

- [x] Inventory the remaining `pixel_common.sh` clusters and label each one as low-level helper vs operator policy.
- [x] Extract the generic device/transport helper cluster into a dedicated sourced lib: serial resolution, `adb` / `fastboot` wrappers, wait helpers, device property/process capture, and status JSON helpers.
- [x] Move the next user-facing operator seam into `shadowctl` instead of adding more shell-wrapper logic. `prep-settings` now lives in `shadowctl`, and the public `just` wrappers for prep/restore route through it.
- [ ] Keep boot-lab and recovery flows private. If they need shared UX, hang them off `shadowctl debug` rather than new ad hoc shell entrypoints.
- [ ] Reduce `pixel_common.sh` to compatibility sourcing plus genuinely shared low-level helpers, then stop growing it.
- [x] Re-run `scripts/ci/operator_cli_smoke.sh` and the narrow Pixel/boot smokes that cover the touched seam before landing.

## Implementation Notes

- This plan replaces the old `pixel_common.sh` / `shadowctl` follow-up that no longer belongs in the completed compositor refactor notebook.
- `pixel_common.sh` is now `1231` lines after the third landed extraction.
- Landed helper splits so far:
  - `pixel_device_transport_common.sh`
  - `pixel_runtime_session_common.sh`
  - `pixel_root_boot_common.sh`
- `shadowctl` already owns the public VM/Pixel `run`, `stop`, `ci`, `stage`, and `debug` surface.
- Many private Pixel scripts still source `pixel_common.sh` directly, so the remaining work is not “one more extraction”; it needs deliberate classification and migration.
- Current cluster labels:
  - root/boot asset helpers: low-level helper, already split into `pixel_root_boot_common.sh`
  - runtime/session path and env helpers: low-level helper, already split into `pixel_runtime_session_common.sh`
  - device transport, root-shell, wait, and status capture helpers: low-level helper, now split into `pixel_device_transport_common.sh`
  - display-takeover/session orchestration and boot-lab recovery: operator/private policy, keep out of the public CLI unless a specific flow benefits from typed routing
- `shadowctl` already owns the public `run`, `stop`, `status`, `doctor`, `state`, `frame`, `ci`, `stage`, and rooted setup/recovery entrypoints, so the next public migration seam is narrower than the first draft of this plan assumed.
- Pixel diagnostics/log capture (`logs`, `status`, `doctor`, `frame`) were already in `shadowctl`; the actual missing public seam was `prep-settings`.
- `just pixel-prep-settings` and `just pixel-restore-android` now behave like the rest of the thin public wrappers and route through `shadowctl`.
- This seam only touched public routing plus a non-root settings helper, so `operator_cli_smoke` plus `pre-commit` were the right pre-land gates; no extra Pixel hardware smoke was needed.
- Rooted-Pixel direct-runtime/GPU probe recipes now belong under `shadowctl debug` instead of bypassing it.
- That probe-routing seam also stayed at the wrapper/dispatch layer, so `operator_cli_smoke` plus `pre-commit` remained the right verification depth.
- The next useful operator-cli slice is likely retiring more compatibility shell wrappers or one more honest `pixel_common.sh` extraction around display/session takeover helpers, not another low-level path-only split.
- Do not convert a low-level bash helper to Python just because `shadowctl` is Python. Migrate only when the behavior is user-facing or benefits from typed control flow.
