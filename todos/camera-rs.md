# Camera RS

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Land one supported live-camera path in Shadow that is good enough to unblock other projects.
- Keep the public platform seam narrow: `listCameras()`, `captureStill()`, and `decodeQrCode()`.
- Support the real user flow: open Camera in the shell, see a live preview, switch between front/back cameras, take a photo, render the photo in-app.
- Keep Pixel behavior live-or-fail. Do not silently fall back to mock on device.
- Out of scope for now: video recording, non-root support, generic multi-device portability, full HAL/provider productization.

## Approach

- Current stack:
  `app-camera` TS app -> `Shadow.os.camera` -> `runtime-camera-host` -> loopback broker -> `shadow-camera-provider-host` -> Pixel camera provider/device/session
- Keep the provider-level Rust helper as the device-facing seam.
- Keep the runtime/app layer above that seam small and stable.
- Treat the rooted Pixel shell lane as the real product path for now.
- Prefer current upstream launch scripts and only carry camera-specific logic where necessary.

## Milestones

- [x] Rust provider helper can discover cameras and capture a rear JPEG on rooted Pixel.
- [x] Shadow runtime exposes camera OS APIs and the TS camera app can take and render a photo.
- [x] Pixel shell path can launch Camera by default and use the live broker path.
- [x] Pixel renderer policy is explicit enough: GPU is the default path; CPU is opt-in.
- [x] Orientation/rendering bug is fixed for the current portrait shell lane.
- [x] Camera validation was tightened from “camera touched something” to “live capture completed and rerendered”.
- [~] Pixel operator hygiene is better: per-serial host lock, less broker leakage, less false green.
- [x] Camera app can show a live preview in the supported rooted Pixel lane.
- [ ] Camera app can enumerate and switch between front/back cameras without breaking capture correctness.
- [ ] Camera support is boring enough to stop working on and build other projects on top of.

## Near-Term Steps

- [~] Stabilize one supported rooted Pixel lane and document it as the canonical camera path.
- [~] Re-run live validation on the supported phone until `pixel-shell-camera-smoke` is repeatable.
- [x] Keep the smoke strict: require auto-click, live capture completion, and a rerender after completion.
- [~] Make Pixel runtime/device errors surface clearly to the app and scripts instead of timing out or looking like transport flakes.
- [ ] Add a rooted-Pixel QR proof path that validates real camera capture plus QR decode end to end, not just app launch or broker activity.
- [ ] Add a cleaner camera error taxonomy so apps can distinguish broker unavailable, no camera, capture timeout, invalid image data, and QR-not-found without string matching.
- [ ] Decide whether QR-oriented capture needs first-class controls such as torch, higher-resolution stills, or scan-specific capture defaults before more apps depend on it.
- [x] Define the smallest truthful preview contract: one live stream in the rooted Pixel shell lane, no video recording or background session complexity yet.
- [~] Thread camera enumeration metadata through the existing `listCameras()` seam so the app can distinguish front/back cameras without adding a new public platform API.
- [~] Design the runtime/provider path for preview frames so the app can render a low-latency live view without regressing still capture correctness.
- [~] Add one deterministic manual/operator path for switching cameras and confirming the selected camera actually changes before trying to automate it.
- [ ] Reduce perceived capture latency enough that the feature feels usable.
- [ ] Wire the truthful camera smoke into the branch gate once it is reliable.

## Implementation Notes

- Supported path today is the rooted Pixel shell/runtime lane, not a generic Android app path.
- The working takeover model preserves allocator/gralloc availability. Full display-stop takeover is not the supported camera mode today.
- The provider helper is already below `cameraserver`; we do not need a new architecture before other projects can use camera.
- The camera app is already a valid platform integration example: it exercises the OS API from TS and renders the result.
- Mock capture is explicit-only (`SHADOW_RUNTIME_CAMERA_ALLOW_MOCK=1`). There is no implicit camera fallback.
- The main remaining risk is operational reliability and latency, not basic access to the camera stack.
- Cashu QR integration proved the current seam is useful on host/VM, but the live rooted-Pixel lane still does not prove that real captures are reliable enough for QR-heavy product flows.
- `listCameras()` still infers `label` and `lensFacing` from id suffixes rather than provider metadata, so camera selection remains somewhat heuristic and device-specific.
- The QR path currently round-trips a full captured still as a base64 image data URL before decode. That kept integration simple, but it is still a poor fit for repeated scans, low-latency scanning, or larger images.
- Suite-aware shell app staging landed at `da68380`; the camera suite now stages only `selectedAppIds: ["camera"]`.
- The next warm-stage bottleneck turned out to be the full runtime helper push to `/data/local/tmp/shadow-runtime-gnu`, about 1.23 GB even on cache-hit host bundles.
- `fac53c8` landed the runtime-helper delta sync in `scripts/pixel/pixel_push.sh`: the first run after the manifest format change still does a one-time full sync; later warm runs hit `Runtime helper dir cacheHit`.
- Validated on Pixel `09051JEC202061`: one migration run did `prep_shell_runtime=98s`; the warm rerun dropped to `prep_shell_runtime=38s` and still returned `pixel-shell-camera-ok`.
- Remaining warm-stage time is now mostly host artifact prep (`shadow-session`, `shadow-compositor-guest`) plus the live camera smoke itself, not unrelated runtime-helper upload.
- Preview and camera switching should stay inside the current camera seam if possible: enrich `listCameras()` with truthful metadata, keep `captureStill()` intact, and only add more platform surface if the preview path proves it is necessary.
- The next product-value seam after landing is not deeper still-capture plumbing; it is “can a user see what camera is live, switch cameras, and then capture confidently”.
- The app already has a working camera picker. The immediate gap is that provider metadata is still too heuristic, so front/back switching is not yet a truthful operator contract.
- The next implementation slice is: provider returns per-camera facing/orientation metadata, runtime preserves it through `listCameras()`, app uses it for stable front/back selection, then preview work can build on that without widening the public API yet.
- Local WIP now does that metadata plumbing: provider `list` returns structured `cameras[]`, runtime preserves `lensFacing` and `sensorOrientationDegrees`, and the app exposes stable `camera-front` / `camera-rear` selectors when the facing is unique. Device validation still needs to confirm the Pixel reports the expected facing metadata.
- The current preview path uses a dedicated broker/runtime `preview` command while keeping `captureStill()` as the explicit photo action, so preview and still capture no longer trample each other in the UI.
- Rooted-Pixel validation now proves both behaviors in one smoke: preview dispatch must produce a live provider frame plus a changed composed frame checksum, then explicit capture must still complete and rerender. Validated on `0B191JEC203253` via `just pixel-ci --target 0B191JEC203253 camera` in run `20260418T164112Z`.
- Tightening that smoke exposed two real Pixel staging bugs in `scripts/pixel/pixel_push.sh`: missing/empty device manifests crashed the sync planner, and full-replace cleanup failed on root-owned runtime cache dirs. Both are now fixed locally.
- The next seam is no longer “prove preview exists”; it is “prove front/back switching is truthful on rooted Pixel and wire that into the smoke/operator path”.
