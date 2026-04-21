Living plan. Revise it as we learn. Do not treat this as a fixed contract.

# OCI Builder

## Intent

Make the OCI ARM builder fast, well-utilized, and cheap to operate.

## Scope

- Improve builder throughput and single-build latency where it matters.
- Make idle shutdown authoritative, observable, and fail-closed enough that we do not pay for long idle uptime.
- Add enough observability to explain low CPU utilization and to evaluate scheduler, linker, and package-structure experiments.
- Keep the initial work focused on builder control-plane, scheduling, and high-leverage Rust/Nix changes.
- Do not start broad Rust crate refactors before shutdown and measurement are trustworthy.

## Approach

- Fix cost control first.
- Improve observability so we can distinguish Cargo graph limits, link bottlenecks, Crane artifact overhead, and idle/queueing effects.
- Tune Nix scheduling for aggregate throughput across worktrees before chasing "one build uses 72 cores".
- Run narrow A/B experiments for Crane artifact mode, linker choice, and release profile tweaks.
- Only then decide whether Rust package splitting or feature-gating is worth the complexity.

## Steps

- [x] Project 1: Make idle shutdown authoritative and visible.
  A durable API-key path now exists on macOS, and the builder now runs a local `oci-builder-idle-check` timer that issues `SOFTSTOP` after 20 idle minutes without depending on the laptop session token.
- [x] Project 2: Upgrade builder observability.
  A first useful slice is live: stop-relevant activity, CPU breakdown including iowait, PSI, and idle decision records are now captured well enough to judge shutdown behavior and builder underutilization.
- [x] Project 3: Evaluate scheduler policy.
  April 20-21 data says keep `max-jobs = 3` and `cores = 24` for now; revisit `4x16` only if queue pressure or sustained `active_build_count = 3` becomes common.
- [x] Project 4: Move the hot UI app package lane onto Crane.
  `shadow-rust-demo` and `shadow-rust-timeline` now use dedicated per-app source helpers plus per-app Crane `buildDepsOnly` / `buildPackage` pairs, which keeps the packages independent while reusing each app's dependency artifacts.
- [x] Project 5: Reduce Nix/Crane overhead.
  `use-symlink` was a dead end, but two real wins landed: skip redundant `buildDepsOnly` checks on the hot runtime/package lanes, and narrow the runtime Rust source filter so `shadow-sdk/src/ui/**` edits no longer invalidate `shadow-system` or the runtime test derivations.
- [ ] Project 6: Target final-build bottlenecks.
  Measure `shadow-system-deps` versus final `shadow-system`, then A/B `lld` and `mold`, release `codegen-units`, and any other linker/profile levers on the real builder.
- [ ] Project 7: Reduce default Rust compile surface if still needed.
  Feature-gate or split heavy domains like Cashu, Nostr, clipboard, and camera backend only if earlier scheduling and artifact wins are insufficient.

## Implementation Notes

- The old laptop-only auto-stop path failed open when OCI CLI session auth expired on April 20, 2026. That is now replaced by a builder-side timer plus durable API-key auth.
- Script scaffolding now prefers a durable `OCI_BUILDER_AUTOMATION` API-key profile at `~/.oci/oci-builder-automation-config` when present, and otherwise falls back to the old session-token path.
- Builder-side OCI auth now uses a dedicated agenix-backed config under `/run/agenix` so the stop path does not depend on permissive `~/.oci` symlinks.
- A first observability slice is now live: `nix-build-observer` samples include SSH connection count, CPU breakdown with `iowait`, PSI, and the current idle timer age from `/var/lib/oci-builder-idle/last-active-builder`.
- The idle watchdog now writes structured decision records to `/var/lib/oci-builder-idle/events-YYYY-MM-DD.jsonl` so we can see `active`, `idle_waiting`, and `softstop` decisions without scraping free-form journal text.
- On April 20, 2026, the builder did in fact auto-stop at about 17:57 PDT; the next boot started at 18:11 PDT when it was brought back up manually.
- Observer data from April 20-21 shows `active_build_count = 3` only briefly, never above 3, and average host CPU at 3 active builds was still only about 41%, so `max-jobs` is not the first bottleneck for the current 1-2-builder workload.
- Crane `installCargoArtifactsMode = "use-symlink"` did not help `shadow-system`: the deps derivation grew from about 191s to about 202s and still produced a 1.7G output with zero symlinks.
- A naive `-fuse-ld=lld` experiment on the final `shadow-system` derivation also did not help: Cargo recompiled a wide set of crates, GNU `ld` still showed up in the process tree, and the final derivation ballooned from about 40s to about 156s.
- `shadow-system`'s default `buildDepsOnly` shape was doing both `cargo check` and `cargo build` for the package lane even though the final derivation only needs build artifacts.
  An April 21, 2026 builder A/B that replaced the deps build phase with just `cargoWithProfile build ${commonArgs.cargoExtraArgs}` cut the whole `shadow-system` package build from about `276s` to about `224s` and cut the deps derivation build phase from about `3m16s` to about `2m07s`.
- April 21, 2026 runtime-check follow-on: `runtimeRustCargoArtifacts` had the same default Crane double-work pattern (`cargo check --release --locked` then `cargo build --release --locked`).
  On `aarch64-darwin`, a fresh rebuild of `shadow-runtime-workspace-deps` took about `279.94s`, with the build phase itself taking `4m38s` and archiving about `1.41 GiB` down to about `401 MiB`.
  Overriding that deps derivation to run only `cargoWithProfile build ${runtimeRustCommonArgs.cargoExtraArgs}` cut the same derivation to about `144.34s`, with the build phase dropping to `2m22s` and the archived target shrinking to about `1.21 GiB / 343 MiB`.
  The dependent `runtimeShadowSdkNostrTests` and `runtimeShadowSystemTests` still passed, though each test derivation spent a few more seconds compiling after unpacking the slimmer artifacts.
- April 21, 2026 source-invalidation follow-on: `shadow-system` and the runtime checks no longer need the full `rust/shadow-sdk` tree.
  Narrowing `shadowSystemSrc` to `shadow-sdk`'s `Cargo.toml`, `src/lib.rs`, `src/app.rs`, `src/services.rs`, and `src/services/**` keeps the full runtime support surface but excludes `src/ui/**`.
  In a path-flake A/B, a one-line edit to `rust/shadow-sdk/src/ui/theme.rs` changed the old `shadow-system` package and `runtimeShadowSystemTests` derivation hashes, but it left the narrowed-source derivation hashes unchanged.
  The narrowed-source builds still passed for `runtimeShadowSdkNostrTests`, `runtimeShadowSystemTests`, and `packages.aarch64-linux.shadow-system`.
- Next seam: either integrate an actually effective linker path that does not invalidate most of the final derivation, or do structural compile-surface work such as splitting heavy `shadow-system` domains behind optional features or separate binaries.
- The builder was still up on April 20, 2026 after starting on April 18, 2026, with multi-hour idle windows that exceed the configured 20 minute threshold.
- `shadow-system` currently follows a coarse Crane split: vendoring, one `buildDepsOnly`, one `buildPackage`.
- The deps derivation spends meaningful wall time after Cargo finishes compressing cargo artifacts, so CPU underutilization is not only a Rust graph problem.
- Single-build CPU usage is low enough that aggregate throughput is likely a better first optimization target than raising per-build cores to 72.
- Working default hypothesis: the end-state scheduler will be closer to `16x4` or `12x6` than `24x3` or `72x1`.
- Small April 20, 2026 landable slice: point `mkShadowRustUiAppFor` at the existing `shadowUiAppsSrc` subset so `shadow-rust-demo` and `shadow-rust-timeline` package builds stop hashing the broader `shadowUiSrc`; this targets frequent rebuild churn without taking on the larger Crane shared-artifacts refactor in the same seam.
- Follow-on slice: split `mkShadowRustUiAppFor` onto a new per-app `shadowUiAppSrcFor` helper so demo and timeline stop invalidating each other while keeping the larger shared-Crane migration as the next project.
- Shared-family Crane experiment result: one common `buildDepsOnly` lane for demo+timeline made cold builds slower and coupled demo to timeline-only `shadow-sdk` features like `nostr`/`ui`, so it was rejected.
- Accepted shape: per-app Crane for demo and timeline, with `shadowUiAppSrcFor` carrying the app path plus the needed Rust workspace patch inputs (`xilem`, `temporal_rs`) so each package remains independently buildable.
- Builder measurements on April 20, 2026 using temp checkouts on `oci-builder`:
  baseline `buildRustPackage` warm build for both apps: `103.404s`
  baseline demo-only source edit rebuild for both attrs: `35.019s`
  baseline shared `rust/shadow-sdk/src/app.rs` edit rebuild for both attrs: `102.963s`
  rejected shared-family Crane warm build for both apps: `143.388s`
  rejected shared-family Crane demo-only edit rebuild: `32.955s`
  rejected shared-family Crane shared-sdk edit rebuild: `101.022s`
  accepted per-app Crane warm build for both apps: `157.643s`
  accepted per-app Crane demo-only edit rebuild: `10.580s`
  accepted per-app Crane shared-sdk edit rebuild: `26.758s`
- Interpretation: cold-ish package builds got slower, but the rebuilds that matter for active iteration got much faster, especially when one app changes or a shared local Rust crate changes.
- Observer build counts from April 18-21, 2026 show the next hottest builder outputs after the demo/timeline app lane were:
  `shadow-rust-demo` `98`
  `shadow-ui-vm-session` `86`
  `shadow-compositor-guest` `76`
  `shadow-rust-timeline` `69`
  `shadow-blitz-demo` `53`
  `shadow-compositor` `48`
  `shadow-system` `6`
- Follow-on experiment result: `shadow-compositor-guest` looked like the next best package candidate by frequency, but a per-package Crane split was rejected.
  Both the `mkDummySrc` version and the `dummySrc = real-src` version failed in `buildDepsOnly` on the static-musl guest package with missing `target/release/build/.../build-script-build` executables (for example `parking_lot_core` and `quote`), even after narrowing the source filter to only the guest workspace members.
- Interpretation: not every hot Rust package should be forced onto the same Crane pattern.
  The guest/compositor static-musl package lane likely needs deeper source or crate reshaping before `buildDepsOnly` is viable, so the next optimization seam should move back to `shadow-system` compile-surface / linker work or another package family rather than pushing harder on guest-compositor Crane.
- Project 3 conclusion changed after looking at real utilization instead of the original heuristic: keep the current `3x24` default until the observer shows actual queue pressure rather than theoretical headroom.
- The next high-leverage seam is likely in the UI app package graph, not `shadow-system`: `shadow-rust-demo`, `shadow-rust-timeline`, and `shadow-ui-vm-session` are frequent builder outputs, and those packages still build as standalone `buildRustPackage` derivations rather than sharing a Cargo artifact lane.
- Crane is already the dominant pattern for shared Rust check/test lanes and for `shadow-system`, but not for every package output. The right standardization target is hot Rust package lanes where rebuilds matter, not every isolated Rust crate.
- The local Crane checkout (`~/code/crane`) reinforces that intended shape: one shared `buildDepsOnly` derivation feeding multiple `buildPackage` outputs, with separate artifact families when `-p` or feature sets diverge.
- April 21, 2026 app-level compile-surface experiment: `shadow-sdk` now exposes `camera` and `clipboard` as opt-in features, with `shadow-rust-demo` enabling only `camera`, `shadow-rust-timeline` enabling `clipboard + nostr + ui`, and `shadow-system` explicitly enabling `camera + clipboard + nostr`.
  This is the safe "feature-gate" shape: same crates, narrower per-package compile surfaces, no runtime/package split yet.
- Measured result for the app-level feature-gate slice:
  `shadow-rust-timeline` unique crate graph dropped from `209` to `198` crates, removing camera/QR/image-only crates such as `base64`, `image`, `qrcodegen`, `rqrr`, `g2*`, and `zune-*`.
  `shadow-rust-demo` unique crate graph dropped from `73` to `71` crates, removing `copypasta` and `objc-sys`.
  Cold local `cargo check --locked` with isolated target dirs improved from `12.13s` to `11.49s` for timeline and from `4.08s` to `3.95s` for demo.
- Interpretation: app-level feature-gating is worth keeping because it removes real compile surface for one-app iteration, but it is not the main `shadow-system` win.
  The aggregate `ui-check apps` lane still builds a shared demo+timeline deps derivation, so that gate intentionally collapses most of this benefit by unifying the app feature sets.
- Decision after the feature-gate experiment: do not start by splitting Nostr or Cashu out of the default `shadow-system` package.
  Current VM/runtime lanes and smokes actively use both, so a split there would mostly create package-matrix complexity before it produces a meaningful default-build win.
- April 21, 2026 `shadow-system` local-crate boundary experiment: a plain internal crate split was not enough on its own.
  Moving Cashu into a new `shadow-cashu-host` workspace crate compiled cleanly, but Crane still rebuilt it in the final derivations because `buildDepsOnly` had compiled dummy versions of all local workspace crates.
- The actual win came from combining the split with a `mkDummySrc` override in both `shadow-system` package lanes (`mkShadowSystemFor` and `runtimeRustCargoArtifacts`).
  Those deps derivations now replace the dummy copies of `shadow-runtime-protocol`, `shadow-sdk`, and `shadow-cashu-host` with their real filtered sources while keeping `shadow-system` itself dummy.
- Measured result for `checks.aarch64-darwin.runtimeShadowSystemTests`:
  before this dummy-src override, the final test derivation compiled `shadow-runtime-protocol`, `shadow-sdk`, `shadow-cashu-host`, and `shadow-system`, and the final compile phase took about `42.69s`.
  after the override, the final test derivation compiled only `shadow-system`, and the final compile phase dropped to about `17.98s`.
- Measured result for `packages.aarch64-linux.shadow-system` on `oci-builder`:
  the deps derivation still does the heavy work up front, but the final package phase now compiles only `shadow-system` and finished its compile step in about `15.59s`.
- Follow-on coverage fix:
  splitting Cashu out of `shadow-system` removed two Cashu path tests from `runtimeShadowSystemTests`, so the runtime gate now needs a dedicated `runtimeShadowCashuHostTests` leaf check to keep those tests inside `runtimeCheck` / `preMergeCheck`.
- April 21, 2026 Nostr follow-on: the same pattern also works for the Nostr host.
  `shadow-system` still carried about 1k lines of Nostr host code (`nostr.rs`, daemon, relay publish/sync, signer) plus the system-prompt helper that only signer used.
  Moving that logic into a new `shadow-nostr-host` workspace crate, then teaching both `shadow-system` deps derivations to replace the dummy `shadow-nostr-host` with the real filtered source, shrank the final derivations again without changing runtime behavior.
- Measured result for `checks.aarch64-darwin.runtimeShadowSystemTests` after the Nostr split:
  the final test derivation now compiles only `shadow-system` and finished its `release` compile step in about `10.52s`, down from about `17.98s` after the earlier Cashu split and dummy-src override.
  The moved Nostr + system-prompt tests now live in a dedicated `runtimeShadowNostrHostTests` leaf check, which compiled `shadow-nostr-host` itself and ran `11` tests in about `1m06s`.
- Measured result for `packages.aarch64-linux.shadow-system` on `oci-builder` after the Nostr split:
  the deps derivation still does the heavy compile up front, but the final package derivation compiled only `shadow-system` and finished its compile step in about `8.36s`, down from about `15.59s` after the Cashu split.
