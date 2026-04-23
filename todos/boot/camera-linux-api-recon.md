# Boot Camera Linux API Recon

Living plan. Revise it as the camera bring-up path changes.

## Decision

- The rooted-Android provider-service frame proof is useful reference evidence, but it is not the target architecture.
- The next real camera task is `boot-camera-rust-hal-frame-probe`: run a Rust-owned direct vendor HAL probe from the Shadow boot environment.
- Do not spend the next camera slice adding more Android provider-service capture features unless the result directly explains a direct-HAL boot blocker.
- Keep Linux media/V4L2/Qualcomm UAPI work as instrumentation unless direct HAL capture proves impossible or unbounded.

## Current Truth

- Supported product fallback:
  - `runtime/app-camera` uses `shadow-sdk` camera APIs through the Android camera provider helper.
  - `shadow-camera-provider-host` is a thin Android Binder/provider client, not a reusable Linux camera library.
- Linux surface recon:
  - Pixel 4a exposes real Qualcomm camera nodes: `/dev/media0`, `/dev/media1`, `/dev/video1` (`cam-req-mgr`), `/dev/video2` (`cam_sync`), and `/dev/v4l-subdev0..16`.
  - The nodes are not a simple UVC-style capture stream.
  - The first Linux-only probe succeeded as discovery: media/V4L2 topology plus Qualcomm `CAM_QUERY_CAP` on safe node families.
- HAL recon:
  - Direct loading `/vendor/lib64/hw/camera.sm6150.so` succeeded on rooted Android and exposed the `HMI` module record.
  - The exported `sphal` namespace failed on missing `libcamera_metadata.so`, which is useful linker evidence for a boot compatibility capsule.
  - Provider-service capture produced one real rear-camera JPEG. This proves the sensor/HAL path can produce a frame, but it relied on Android provider-service machinery.

## Evidence

- Linux inventory:
  - `/Users/justin/code/shadow/worktrees/worker-3/build/pixel/runs/camera-linux-api-recon/20260423T201839Z-0B191JEC203253/status.json`
  - `/Users/justin/code/shadow/worktrees/worker-3/build/pixel/runs/camera-linux-api-recon/20260423T201839Z-0B191JEC203253/device-inventory.txt`
- Android provider baseline:
  - `/Users/justin/code/shadow/worktrees/worker-3/build/pixel/camera-rs/20260423T201930Z-0B191JEC203253_/status.json`
- Linux query-cap probe:
  - `/Users/justin/code/shadow/worktrees/worker-3/build/pixel/camera-linux-api/20260423T205038Z-0B191JEC203253_/status.json`
  - `/Users/justin/code/shadow/worktrees/worker-3/build/pixel/camera-linux-api/20260423T205038Z-0B191JEC203253_/linux-probe.json`
- HAL containment probe:
  - `/Users/justin/code/shadow/worktrees/worker-3/build/pixel/camera-hal-api/20260423T213734Z-0B191JEC203253_/status.json`
  - `/Users/justin/code/shadow/worktrees/worker-3/build/pixel/camera-hal-api/20260423T213734Z-0B191JEC203253_/hal-probe.json`
- Provider-service frame proof:
  - `/Users/justin/code/shadow/worktrees/worker-3/build/pixel/camera-hal-api/20260423T220713Z-0B191JEC203253_/status.json`
  - `/Users/justin/code/shadow/worktrees/worker-3/build/pixel/camera-hal-api/20260423T220713Z-0B191JEC203253_/hal-probe.json`
  - `/Users/justin/code/shadow/worktrees/worker-3/build/pixel/camera-hal-api/20260423T220713Z-0B191JEC203253_/provider-frame.jpg`

## Target Architecture

- Rust owns the Shadow-facing camera trait, daemon/probe lifecycle, and artifact schema.
- Vendor HAL details stay behind one backend boundary.
- A small native shim may expose `hw_module_t`, `camera_module_t`, `camera3_device_t`, callback ops, stream configuration, native handles, fences, and request submission to Rust.
- Allowed compatibility pieces are measured, minimal, and HAL-facing: Bionic/linker behavior, vendor/system/APEX library roots, read-only Android properties, native handles, gralloc or dma-buf allocation, sync fences, and required device nodes.
- Target non-goals:
  - no Android `ICameraProvider`
  - no `cameraserver`
  - no Java Camera2 or Android app framework
  - no rooted-Android shell as the execution environment
  - no broad Android userspace import beyond an explicit allowlist required by the vendor HAL

## Next Task: `boot-camera-rust-hal-frame-probe`

- Goal: boot the Pixel into the Shadow/Rust boot setup and run a boot-owned Rust helper that talks directly to `/vendor/lib64/hw/camera.sm6150.so`.
- Minimum success:
  - the probe runs from Shadow boot userspace, not rooted Android
  - it reaches the deepest honest HAL stage and writes a precise blocker bundle if capture fails
  - the artifact proves `cameraserver` and `android.hardware.camera.provider*` were not the camera API for the run
- Target success:
  - one rear-camera frame captured through direct vendor HAL calls from the Rust boot environment
- Target command shape:
  - `SHADOW_DEVICE_LEASE_FORCE=1 PIXEL_SERIAL=<serial> scripts/pixel/pixel_boot_camera_hal_probe.sh`
- Owned implementation paths:
  - a narrow Rust boot probe binary under `rust/`, preferably `shadow-camera-hal-boot-probe` or equivalent
  - a tiny native shim for HAL structs, callbacks, native handles, fences, stream config, and request submission
  - a boot staging/recovery script under `scripts/pixel/`
  - proof artifacts under `build/pixel/camera-boot-hal/<timestamp>-<serial>/`

## Direct HAL Stage Gates

- `stage=link`: mount the required vendor/system/APEX library roots and direct-load the HAL with `android_dlopen_ext` or an equivalent boot linker strategy.
- `stage=hmi`: parse `HMI` and validate `id=camera`, module versions, methods pointer, and `camera_module_t` prefix.
- `stage=module`: call safe module-level entry points such as camera count/info through the C shim, while recording property/library/device/service access attempts.
- `stage=open`: open rear camera `0` through `module->methods->open` and classify the first missing dependency if it fails.
- `stage=configure`: configure one conservative output stream, initially JPEG BLOB if native-handle/gralloc is available; otherwise use the simplest HAL-supported output backed by evidence.
- `stage=request`: allocate or import one boot-owned output buffer, submit one capture request, wait on fences/callbacks, and recover `first-frame.jpg` or `first-frame.raw`.

## Direct HAL JSON Contract

- `schemaVersion`, `stage`, `ok`, `serial`, kernel release, boot mode, process credentials, mount roots, and dynamic linker mode.
- `halLoad` with namespace/path attempts, unresolved libraries/symbols, and loaded library delta.
- `module` with parsed `HMI`, camera count/info results, and exact HAL status codes.
- `compat` with property reads, file opens, device-node opens, service/binder attempts, gralloc/native-handle allocation, fence usage, and permission notes.
- `capture` with selected camera, stream config, buffer/native-handle shape, request metadata source, callbacks/fences, output path, and bytes written.
- `blocker` with one of `linker`, `missing-library`, `missing-symbol`, `property`, `device-node`, `permission`, `binder-service`, `gralloc-native-handle`, `sync-fence`, `hal-open`, `hal-configure`, `hal-request`, or `unknown`.

## Direct HAL Proof Artifacts

- `build/pixel/camera-boot-hal/<timestamp>-<serial>/status.json`
- `build/pixel/camera-boot-hal/<timestamp>-<serial>/boot-hal-probe.json`
- `build/pixel/camera-boot-hal/<timestamp>-<serial>/device-output.txt`
- `build/pixel/camera-boot-hal/<timestamp>-<serial>/dmesg.txt`
- `build/pixel/camera-boot-hal/<timestamp>-<serial>/ld-debug.txt` when linker diagnostics are available
- `build/pixel/camera-boot-hal/<timestamp>-<serial>/first-frame.jpg` or `first-frame.raw` only when a frame is actually produced

## Parked Linux UAPI Track

- Keep `camera-linux-surface-probe` as discovery and instrumentation:
  - media controller device info/topology
  - V4L2 node capabilities
  - V4L2 subdevice capabilities
  - Qualcomm `VIDIOC_CAM_CONTROL` plus `CAM_QUERY_CAP` where payload shape is known from public UAPI source
  - sysfs names, major/minor pairs, labels, owners, and modes
- Discovery success means `ok=true` even if capture remains blocked.
- Forbidden in the discovery probe:
  - `CAM_SENSOR_PROBE_CMD`
  - `CAM_ACQUIRE_DEV`
  - `CAM_START_DEV`
  - `CAM_CONFIG_DEV`
  - request-manager create/link/apply/flush controls
  - `CAM_SYNC_CREATE`, `CAM_SYNC_DESTROY`, `CAM_SYNC_WAIT`
  - buffer allocation/import/export
  - frame capture

## Source Notes

- AOSP `ICameraProvider.aidl` defines service names shaped like `android.hardware.camera.provider.ICameraProvider/<type>/<instance>` and device names shaped like `device@<major>.<minor>/<type>/<id>`.
- AOSP `ICameraDevice.open()`, `configureStreams()`, and `processCaptureRequest()` confirm that frame capture depends on stream configuration, metadata, native handles, fences, and buffers.
- Pixel 4a public source branch used for ABI recon: `android-msm-sunfish-4.14-android13-qpr3` at `c6d66c401d23a399a453b64824bb74945e4708d3`.
- The live device reported `4.14.302-g92e0d94b6cba`; on-device errno/results remain the truth source because the exact public commit was not matched.
- `include/uapi/media/cam_defs.h` defines `VIDIOC_CAM_CONTROL`, `CAM_QUERY_CAP`, `CAM_ACQUIRE_DEV`, `CAM_START_DEV`, `CAM_STOP_DEV`, `CAM_CONFIG_DEV`, and `struct cam_control`.
- `include/uapi/media/cam_req_mgr.h` defines the Qualcomm camera entity types seen in inventory.
- `cam_req_mgr_dev.c` makes `/dev/video1` (`cam-req-mgr`) an exclusive opener and its close path runs request-manager shutdown and memory-manager deinit.

## Steps

- [x] Inventory current Android camera path and Shadow camera abstractions.
- [x] Run rooted Pixel Linux camera surface inventory on `0B191JEC203253`.
- [x] Run existing Android provider `list` baseline on `0B191JEC203253`.
- [x] Read relevant AOSP camera HAL and Pixel 4a Qualcomm Linux camera source.
- [x] Define and implement first Linux-only read-only probe.
- [x] Validate `linux-probe` on a rooted Pixel and compare with Android provider camera IDs.
- [x] Run contained HAL inventory probe.
- [x] Run contained HAL/provider frame probe.
- [x] Correct project direction: provider capture is reference data, not target architecture.
- [ ] Implement `boot-camera-rust-hal-frame-probe` from Shadow boot userspace.
- [ ] Decide whether direct Linux capture deserves more work after direct-HAL blockers are known.

## References

- Android AIDL camera provider source: https://android.googlesource.com/platform/hardware/interfaces/+/refs/heads/main/camera/provider/aidl/android/hardware/camera/provider/ICameraProvider.aidl
- Android AIDL camera device source: https://android.googlesource.com/platform/hardware/interfaces/+/refs/heads/main/camera/device/aidl/android/hardware/camera/device/ICameraDevice.aidl
- Android AIDL camera session source: https://android.googlesource.com/platform/hardware/interfaces/+/refs/heads/main/camera/device/aidl/android/hardware/camera/device/ICameraDeviceSession.aidl
- Android HIDL provider 2.7 source: https://android.googlesource.com/platform/hardware/interfaces/+/refs/heads/main/camera/provider/2.7/ICameraProvider.hal
- Pixel 4a public kernel branch used for recon: https://android.googlesource.com/kernel/msm/+/refs/heads/android-msm-sunfish-4.14-android13-qpr3
- Qualcomm camera common UAPI: https://android.googlesource.com/kernel/msm/+/refs/heads/android-msm-sunfish-4.14-android13-qpr3/include/uapi/media/cam_defs.h
- Qualcomm camera request-manager UAPI: https://android.googlesource.com/kernel/msm/+/refs/heads/android-msm-sunfish-4.14-android13-qpr3/include/uapi/media/cam_req_mgr.h
- Qualcomm request-manager driver: https://android.googlesource.com/kernel/msm/+/refs/heads/android-msm-sunfish-4.14-android13-qpr3/drivers/media/platform/msm/camera/cam_req_mgr/cam_req_mgr_dev.c
- Linux Media Controller API: https://docs.kernel.org/userspace-api/media/mediactl/media-controller.html
- Linux `VIDIOC_QUERYCAP`: https://docs.kernel.org/userspace-api/media/v4l/vidioc-querycap.html
- Android Camera HAL overview: https://source.android.com/docs/core/camera/camera3
