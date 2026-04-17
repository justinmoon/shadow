# Cashu Wallet Plan

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Make the runtime Cashu wallet useful enough to actually use.
- Keep one trusted-mint wallet as the first product target.
- Required useful flows: durable wallet state, add/trust mint, show balance, mint invoice, pay invoice, send/receive token, scan QR codes, and survive app/session restarts.
- Validate through normal host, VM, and Pixel shell lanes, not special direct-runtime probes.

## Approach

- Keep `Shadow.os.cashu` as the app-facing API seam.
- Keep CDK plus durable mnemonic and `redb` wallet state as the current backend until a real limitation appears.
- Add QR scanning as product work, not platform theory: use the existing runtime camera seam where possible, then decode QR payloads into wallet actions.
- Keep paste/manual entry as a fallback even after QR scanning works.

## Agent Handoff

- This is product/app work. Keep cross-app runtime changes narrow and move reusable platform decisions into the relevant platform plan or docs.
- First clarify the QR decode path: TypeScript bundle dependency, Rust runtime op, or camera-host-side helper.
- Prefer reusing `Shadow.os.camera` and the existing camera runtime seam. Do not create a separate camera capture path for Cashu unless the existing seam is proven insufficient.
- Likely write areas: `runtime/app-cashu-wallet/`, Cashu runtime-host code under `rust/`, shared runtime protocol/types, host smokes, and eventually Pixel CI suite wiring.
- Coordinate with app-metadata if adding or renaming bundle metadata, config keys, app ids, or profile membership.
- Keep manual paste/token entry working as a fallback while QR scanning lands.
- Do not make default CI depend on the public internet. Use local/fixed fixtures and local services for branch gates.
- Validate host behavior first with deterministic local mint/fakewallet smokes; then VM shell persistence; then targeted `just pixel-ci cashu` once the suite exists.

## Milestones

- [x] Land host-only `Shadow.os.cashu` backed by CDK with durable seed and wallet state.
- [x] Ship the first runtime Cashu wallet app.
- [x] Add trusted mint, balance, token receive, token send, Lightning funding, and Lightning payment flows.
- [x] Add deterministic host smoke coverage against a local `cdk-mintd` fakewallet mint.
- [x] Prove wallet restart persistence through a real host-session relaunch.
- [x] Prove wallet restart/shelve behavior through the VM shell lane.
- [ ] Prove the wallet through the rooted-Pixel shell lane.
- [x] Add QR scanning for Cashu tokens, mint URLs, and Lightning invoices.
- [x] Add explicit UX for scan failures, unsupported QR payloads, and duplicate/replayed tokens.

## Near-Term Steps

- [x] Decide the QR decode path: TypeScript bundle dependency, Rust runtime op, or camera-host-side helper.
- [x] Add fixed QR image fixtures for Cashu token, mint URL, Lightning invoice, unsupported payload, and duplicate/replay cases.
- [x] Add a Scan action to the wallet app that captures from `Shadow.os.camera` and routes decoded payloads into existing receive/pay/trust flows.
- [x] Add host-level QR decode tests with fixed image fixtures.
- [x] Add VM shell persistence coverage before Pixel, so failures are easier to debug.
- [x] Add `just pixel-ci cashu` coverage once the shell lane can prove a useful wallet flow without manual QA.

## Implementation Notes

- `todos/app-metadata.md` carries the remaining cross-app runtime cleanup context. This file tracks Cashu wallet product work.
- QR scanning probably crosses the camera runtime seam, so coordinate with `todos/camera-rs.md` instead of creating a separate camera path.
- The wallet is still pre-alpha. Optimize for fast iteration and clear failures before polishing broad compatibility.
- Pixel hardware is useful for final proof, but most Cashu behavior should be provable without requiring a plugged-in device.
- QR decode path decision: keep capture on `Shadow.os.camera`, add a Rust camera runtime QR decode op for image data URLs, and keep Cashu payload classification/routing in the wallet app.
- Host smoke now relaunches the runtime host against one wallet data dir and proves trusted mint persistence before scanning a generated Cashu token QR.
- Deterministic QR coverage uses camera-host PNG QR fixtures plus `SHADOW_RUNTIME_CAMERA_MOCK_QR_PAYLOAD` for end-to-end mock-camera scans.
- Host QR scan smoke covers scanned mint trust, scanned token receive, duplicate/replay token UX, scanned Lightning invoice payment, and unsupported payload UX.
- VM smoke now opens, homes, reopens, and re-shelves Cashu through the normal shell control path.
- `just pixel-ci cashu` is wired as a rooted-Pixel shell lifecycle suite for Cashu launch, shelve, and reopen. A real hardware run is still needed before marking the rooted-Pixel milestone complete.
- `just pre-merge` passes with the Cashu VM shell lifecycle included in `just smoke target=vm`.
