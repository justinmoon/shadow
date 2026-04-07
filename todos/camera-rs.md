# Camera RS

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Prove rooted Pixel 4a can capture one rear-camera JPEG from Rust by talking below `media.camera` / `cameraserver`.
- Target current live device boundary: `android.hardware.camera.provider.ICameraProvider/internal/0`.
- Run as standalone Android-native helper first; integrate with the runtime/app layer only after proof.
- Out of scope for first pass: preview, video, front camera, generic multi-device support, non-root path, polished API.

## Approach

- Add a new Android-target Rust crate, working name `rust/shadow-camera-provider-host`.
- Build, push, and run it through Nix plus Pixel scripts, not through the existing GNU `shadow-runtime-host` lane.
- Vendor or generate Rust AIDL bindings for camera `provider`, `device`, `common`, `metadata`, and `common.fmq`.
- Prefer pure Rust binder/nativewindow plumbing; use the smallest possible local FFI where crates are thin.
- Keep the first request shape tiny: camera `0`, one JPEG BLOB stream, one capture, write file, exit.
- Run in the rooted `su` domain on device; plain `shell` is not the policy target.
- Keep takeover changes conservative until capture works; do not assume display allocator services can be killed.

## Milestones

- [x] M0: Bootstrap crate and Android build path.
  - Added `rust/shadow-camera-provider-host` as a minimal Android-friendly Rust helper with deterministic JSON output.
  - Added an `android` dev shell in `flake.nix` using `android-nixpkgs` + `rust-overlay` + `cargo-ndk` instead of `pkgsCross`.
  - Added `scripts/pixel_camera_rs_run.sh` and `just pixel-camera-rs-run` to build with `cargo ndk`, push to the phone, and run under `su`.
  - Proven on-device on `0B191JEC203253`: `ping` runs as root and returns structured JSON.

- [x] M1: Service discovery proof.
  - Added a Rust `list` command plus hand-written camera AIDL slices for `provider`, `device`, and `common`.
  - Added Android-only binder service-manager/thread-pool shims that `dlopen` extra `libbinder_ndk.so` entrypoints not exposed by the Cargo NDK crate surface.
  - Pinned the helper build to Android API level 31 in `scripts/pixel_camera_rs_run.sh` because the public binder NDK stub needs API 31 for the symbols used by `android-binder`.
  - Proven on-device on `0B191JEC203253`: `just pixel-camera-rs-run list` reaches `android.hardware.camera.provider.ICameraProvider/internal/0`, enumerates `device@1.1/internal/0` and `device@1.1/internal/1`, reads rear-camera resource cost `33`, and reads `21312` bytes of static metadata.
  - Saved structured artifacts under `build/pixel/camera-rs/20260407T210041Z/`.

- [~] M2: Minimal open/configure path.
  - Added provider/device callback stubs plus `notifyDeviceStateChange`, `open`, session `close`, and session `constructDefaultRequestSettings`.
  - Proven on-device on `0B191JEC203253`: provider notify works, rear camera open works, session-level `STILL_CAPTURE` default settings return `2528` bytes, and session close works.
  - Remaining work: configure one JPEG output stream; no preview stream.

- [ ] M3: Buffer plus still-capture proof outside takeover.
  - Allocate/import buffers, submit one request, receive result callback, write one JPEG on device.
  - Pull JPEG plus logs back to host.

- [ ] M4: Takeover proof.
  - Rerun the same helper during the current display-stop takeover.
  - Record whether the provider-level path survives `surfaceflinger` / `system_server` instability.
  - Only adjust takeover once the no-takeover baseline exists.

- [ ] M5: Operator integration.
  - Add `just` / script entrypoints for build, push, list, capture, and restore.
  - Make logs and checkpoints easy to diff against existing Pixel runs.
  - Run `just pre-commit`.

- [ ] M6: Runtime integration decision.
  - If standalone capture works, decide whether to expose camera through Shadow runtime OS APIs.
  - Do not couple the first proof to app-runtime changes.

## Near-Term Steps

- [x] Decide the binding path.
  - Current path: hand-written minimal AIDL Rust modules plus `android-binder`, with thin Android-only `dlopen` shims for non-NDK service-manager/process helpers.
  - Reason: plain Cargo/NDK builds force the binder crate into `android_ndk` mode, which hides the richer in-tree service-manager helpers.
- [x] Add crate scaffold under `rust/`.
- [x] Add Android-target build path to `flake.nix`.
  - Implemented as a dedicated `android` dev shell rather than a `pkgsCross` package path.
- [x] Add first Pixel script to run the helper under `su`.
- [x] Implement a `list` command: declared instances, provider wait/open, rear camera name dump.
- [x] Verify whether request/result metadata can stay inline before investing in FMQ helpers.
  - Current open/default-settings probe stays on the inline Binder path. FMQ is still deferred until `configureStreams` / `processCaptureRequest` force it.

## Implementation Notes

- Live Pixel service manager registers `android.hardware.camera.provider.ICameraProvider/internal/0`; the on-device VINTF camera manifest is `format="aidl"` even though the process name still contains `@2.7-service-google`.
- Current framework Camera2 path fails under takeover because stopping `surfaceflinger` wedges `WindowManagerService`, which kills `system_server`; that is the reason to spike below `cameraserver`.
- This tree does not contain the earlier Java/native camera-helper branch. First deliverable here is a standalone Rust helper, not a migration of existing camera code.
- `rust/shadow-runtime-host` is the Deno stdio host and should stay separate. Camera work should land as a sibling crate unless later integration forces a merge.
- AOSP enables Rust backends for the camera AIDL interfaces; codegen is not the blocker. Runtime integration, service access, native handles, and fences are the hard parts.
- Policy note: AOSP sepolicy marks `su` as `hal_camera_client` and `hal_graphics_allocator_client`; plain `shell` does not appear to have equivalent direct HAL access.
- Buffer note: `StreamBuffer` carries native handles plus acquire/release fences. Keep the first implementation synchronous and JPEG-only.
- FMQ note: session AIDL exposes request/result metadata queues. Defer queue support until the device forces it; first spike should try inline metadata paths.
- Apple Silicon note: `pkgsCross.*android*` was the wrong tool here. `android-nixpkgs` + `cargo-ndk` works on this host; the helper now builds through `nix develop .#android`.
- Binder note: the Android NDK stub contains the `android-binder` crate’s required symbols only at API level 31+, while newer service-manager/process helpers still need runtime lookup from the device’s `libbinder_ndk.so`.
- Live Pixel note: `ICameraDevice.constructDefaultRequestSettings` is not implemented on the `device@1.1/internal/*` handles returned by this Pixel 4a. That method was added in later frozen camera-device AIDL versions, so the working path here is `device.open()` followed by session-level `constructDefaultRequestSettings`.
- Current proof artifacts for the open/session-default seam live under `build/pixel/camera-rs/20260407T211917Z/`.
- Next seam after M2: hand-write the minimum `StreamConfiguration` / `HalStream` / buffer-handle parcelables needed to configure one JPEG BLOB stream and see whether capture can still avoid FMQ for the first request.
