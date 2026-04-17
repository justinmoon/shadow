# Camera RS

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Scope

- Land one supported live-camera path in Shadow that is good enough to unblock other projects.
- Keep the public platform seam narrow: `listCameras()` and `captureStill()`.
- Support the real user flow: open Camera in the shell, take a photo, render the photo in-app.
- Keep Pixel behavior live-or-fail. Do not silently fall back to mock on device.
- Out of scope for now: preview/video, non-root support, generic multi-device portability, full HAL/provider productization.

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
- [~] Camera validation is being tightened from “camera touched something” to “live capture completed and rerendered”.
- [~] Pixel operator hygiene is better: per-serial host lock, less broker leakage, less false green.
- [ ] Camera support is boring enough to stop working on and build other projects on top of.

## Near-Term Steps

- [ ] Stabilize one supported rooted Pixel lane and document it as the canonical camera path.
- [ ] Re-run live validation on the supported phone until `pixel-shell-camera-smoke` is repeatable.
- [ ] Keep the smoke strict: require auto-click, live capture completion, and a rerender after completion.
- [~] Make Pixel runtime/device errors surface clearly to the app and scripts instead of timing out or looking like transport flakes.
- [ ] Reduce perceived capture latency enough that the feature feels usable.
- [ ] Wire the truthful camera smoke into the branch gate once it is reliable.

## Implementation Notes

- Supported path today is the rooted Pixel shell/runtime lane, not a generic Android app path.
- The working takeover model preserves allocator/gralloc availability. Full display-stop takeover is not the supported camera mode today.
- The provider helper is already below `cameraserver`; we do not need a new architecture before other projects can use camera.
- The camera app is already a valid platform integration example: it exercises the OS API from TS and renders the result.
- Mock capture is explicit-only (`SHADOW_RUNTIME_CAMERA_ALLOW_MOCK=1`). There is no implicit camera fallback.
- The main remaining risk is operational reliability and latency, not basic access to the camera stack.
- Next seam: make one supported Pixel smoke lane trustworthy and repeatable, then stop deepening camera internals.
