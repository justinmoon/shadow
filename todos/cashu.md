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

## Milestones

- [x] Land host-only `Shadow.os.cashu` backed by CDK with durable seed and wallet state.
- [x] Ship the first runtime Cashu wallet app.
- [x] Add trusted mint, balance, token receive, token send, Lightning funding, and Lightning payment flows.
- [x] Add deterministic host smoke coverage against a local `cdk-mintd` fakewallet mint.
- [ ] Prove wallet restart persistence through a real host-session relaunch.
- [ ] Prove wallet restart/shelve behavior through the VM shell lane.
- [ ] Prove the wallet through the rooted-Pixel shell lane.
- [ ] Add QR scanning for Cashu tokens, mint URLs, and Lightning invoices.
- [ ] Add explicit UX for scan failures, unsupported QR payloads, and duplicate/replayed tokens.

## Near-Term Steps

- [ ] Decide the QR decode path: TypeScript bundle dependency, Rust runtime op, or camera-host-side helper.
- [ ] Add a Scan action to the wallet app that captures from `Shadow.os.camera` and routes decoded payloads into existing receive/pay/trust flows.
- [ ] Add host-level QR decode tests with fixed image fixtures.
- [ ] Add VM shell persistence coverage before Pixel, so failures are easier to debug.
- [ ] Add `just pixel-ci cashu` coverage once the shell lane can prove a useful wallet flow without manual QA.

## Implementation Notes

- `todos/app-runtime.md` now tracks the cross-app runtime platform. This file tracks Cashu wallet product work.
- QR scanning probably crosses the camera runtime seam, so coordinate with `todos/camera-rs.md` instead of creating a separate camera path.
- The wallet is still pre-alpha. Optimize for fast iteration and clear failures before polishing broad compatibility.

