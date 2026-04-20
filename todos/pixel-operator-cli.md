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

- [ ] Inventory the remaining `pixel_common.sh` clusters and label each one as low-level helper vs operator policy.
- [ ] Extract the generic device/transport helper cluster into a dedicated sourced lib: serial resolution, `adb` / `fastboot` wrappers, wait helpers, device property/process capture, and status JSON helpers.
- [ ] Move the next user-facing operator seam into `shadowctl` instead of adding more shell-wrapper logic. Likely candidates are shared Pixel state/doctor/frame flows or shared run/stage/stop delegation.
- [ ] Keep boot-lab and recovery flows private. If they need shared UX, hang them off `shadowctl debug` rather than new ad hoc shell entrypoints.
- [ ] Reduce `pixel_common.sh` to compatibility sourcing plus genuinely shared low-level helpers, then stop growing it.
- [ ] Re-run `scripts/ci/operator_cli_smoke.sh` and the narrow Pixel/boot smokes that cover the touched seam before landing.

## Implementation Notes

- This plan replaces the old `pixel_common.sh` / `shadowctl` follow-up that no longer belongs in the completed compositor refactor notebook.
- `pixel_common.sh` is still `1668` lines after the two landed extractions.
- Landed helper splits so far:
  - `pixel_runtime_session_common.sh`
  - `pixel_root_boot_common.sh`
- `shadowctl` already owns the public VM/Pixel `run`, `stop`, `ci`, `stage`, and `debug` surface.
- Many private Pixel scripts still source `pixel_common.sh` directly, so the remaining work is not “one more extraction”; it needs deliberate classification and migration.
- The next useful seam is probably the generic device/transport cluster around serial resolution, `adb` / `fastboot`, wait helpers, process/property capture, and status JSON, not another path-only split.
- Do not convert a low-level bash helper to Python just because `shadowctl` is Python. Migrate only when the behavior is user-facing or benefits from typed control flow.
