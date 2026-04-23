# Boot Camera Linux API Recon

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Intent

- Decide whether a boot-owned Linux camera library is plausible on Pixel 4a without depending on Android `cameraserver` or the Android camera provider service.
- Preserve the current Android camera path as the supported product path while this stays a boot-side reconnaissance lane.
- Evaluate both a direct Linux kernel-UAPI path and a contained vendor HAL path before attempting boot image integration.

## Scope

- In scope:
  - current Shadow Android-camera path and artifact contract
  - rooted Pixel 4a Linux media/V4L2 device inventory
  - AOSP camera HAL interface source relevant to the current Android provider path
  - Pixel 4a Qualcomm kernel camera UAPI and driver source relevant to Linux probing
  - a read-only Linux media/V4L2/Qualcomm-UAPI probe plan with exact nodes, ioctls, outputs, and artifact paths
  - a contained vendor HAL probe track that keeps Shadow's Rust API and daemon contract small while evaluating whether Pixel vendor camera code can provide capture without the Android app/framework stack
- Out of scope:
  - replacing the rooted Pixel shell camera path
  - frame capture, buffer queueing, ISP programming, or sensor controls
  - boot image integration before a read-only Linux probe is truthful
  - broad Android framework adoption or exposing Android camera architecture as Shadow's camera API
  - deep vendor-library reverse engineering before a minimal HAL containment probe proves useful

## Current Findings

- Current supported Shadow camera path is still Android-service based:
  `runtime/app-camera` -> `shadow-sdk` camera backend -> TCP broker -> `shadow-camera-provider-host` -> Android Camera provider/device/session Binder interfaces.
- The existing provider helper already proves the Android path on `0B191JEC203253`:
  - `/Users/justin/code/shadow/worktrees/worker-3/build/pixel/camera-rs/20260423T201930Z-0B191JEC203253_/status.json`
  - `list` returned rear `device@1.1/internal/0` at 90 degrees and front `device@1.1/internal/1` at 270 degrees.
- Rooted Pixel Linux inventory on `0B191JEC203253` found real camera-adjacent kernel nodes:
  - `/dev/media0`, `/dev/media1`
  - `/dev/video1` named `cam-req-mgr`
  - `/dev/video2` named `cam_sync`
  - `/dev/v4l-subdev0..16` under `soc:qcom,cam-req-mgr`
  - subdevice names include `cam-cpas`, `cam-isp`, `cam-csiphy-driver`, `cam-actuator-driver`, `cam-sensor-driver`, `cam-eeprom`, `cam-ois`, `cam-jpeg`, `cam-fd`, and `cam-lrme`
- The same inventory confirms this is not a simple UVC-style `/dev/videoN` capture stream:
  - `/dev/video0` is `sde_rotator`
  - `/dev/video32..34` are `qcom,vidc1`
  - `/sys/class/media` was empty even though `/dev/media*` exists
  - Android still exposes the real public cameras through `android.hardware.camera.provider.ICameraProvider/internal/0`
- The first implemented Linux probe succeeded on `0B191JEC203253`:
  - artifact root: `/Users/justin/code/shadow/worktrees/worker-3/build/pixel/camera-linux-api/20260423T205038Z-0B191JEC203253_`
  - `linux-probe.json` reports `ok=true`, `interpretation=topology-visible`, and 28 successful ioctl calls.
  - Qualcomm `CAM_QUERY_CAP` succeeded for CPAS, ISP, CSIPHY, actuator, both sensors, EEPROM, OIS, JPEG, FD, and LRME without invoking acquire/start/config/request/buffer ioctls.
  - `/dev/video1` `cam-req-mgr` remained intentionally skipped for direct open; `/dev/video2` `cam_sync` returned `EALREADY` on open and was recorded as data.
- Current working thesis:
  - a pure Rust/Linux kernel-UAPI camera stack remains valuable to evaluate, but it is likely to become a large Qualcomm request-manager, sensor, ISP, buffer, and sync reimplementation project
  - a contained HAL backend is probably the faster path to a working Pixel 4a camera if its Android dependencies can be isolated behind a small Shadow-owned Rust-facing daemon contract
- Evidence:
  - `/Users/justin/code/shadow/worktrees/worker-3/build/pixel/runs/camera-linux-api-recon/20260423T201839Z-0B191JEC203253/status.json`
  - `/Users/justin/code/shadow/worktrees/worker-3/build/pixel/runs/camera-linux-api-recon/20260423T201839Z-0B191JEC203253/device-inventory.txt`
  - `/Users/justin/code/shadow/worktrees/worker-3/build/pixel/camera-linux-api/20260423T205038Z-0B191JEC203253_/status.json`
  - `/Users/justin/code/shadow/worktrees/worker-3/build/pixel/camera-linux-api/20260423T205038Z-0B191JEC203253_/linux-probe.json`

## Source-Level Recon

- Android camera source read:
  - AOSP `ICameraProvider.aidl` defines the provider service naming shape `android.hardware.camera.provider.ICameraProvider/<type>/<instance>` and device names `device@<major>.<minor>/<type>/<id>`.
  - `ICameraProvider.getCameraIdList()` and `getCameraDeviceInterface()` match the current Shadow `list` path.
  - `ICameraDevice.open()` starts an active camera session; `ICameraDeviceSession.configureStreams()` and `processCaptureRequest()` depend on HAL stream configuration, metadata, native handles, fences, and buffers.
  - The on-device process name is HIDL-flavored (`android.hardware.camera.provider@2.7-service-google`), and AOSP HIDL `ICameraProvider@2.7` only extends the provider surface with concurrent-stream queries. The current service instance exposed through servicemanager is still the AIDL-style provider name used by `shadow-camera-provider-host`.
- Shadow Android path source read:
  - `rust/shadow-camera-provider-host` hand-declares the AIDL binder parcel surface it needs, loads `libbinder_ndk.so`, enumerates provider instances, opens a device, configures a JPEG/preview stream, and uses `AHardwareBuffer` plus camera metadata parsing.
  - This confirms the current path is a thin Android camera-provider client, not a reusable Linux camera library.
- Pixel 4a Linux source read:
  - Public source branch used for ABI recon: `android-msm-sunfish-4.14-android13-qpr3` at `c6d66c401d23a399a453b64824bb74945e4708d3`.
  - The live device reports `4.14.302-g92e0d94b6cba`; this exact running kernel commit has not been matched to a public source commit, so on-device errno/results remain the truth source.
  - `include/uapi/media/cam_defs.h` defines `VIDIOC_CAM_CONTROL`, `CAM_QUERY_CAP`, `CAM_ACQUIRE_DEV`, `CAM_START_DEV`, `CAM_STOP_DEV`, `CAM_CONFIG_DEV`, and `struct cam_control`.
  - `include/uapi/media/cam_req_mgr.h` defines the Qualcomm camera entity types seen in inventory, including sensor, IFE/ISP, CPAS, CSIPHY, actuator, EEPROM, OIS, JPEG, FD, and LRME.
  - `cam_req_mgr_dev.c` makes `/dev/video1` (`cam-req-mgr`) an exclusive opener (`-EALREADY` after one open) and its close path runs camera request-manager shutdown and memory-manager deinit. The first probe must not treat this as a harmless UVC-style capture node.
  - Generic Qualcomm `cam_node` devices (`cam-isp`, `cam-jpeg`, `cam-fd`, `cam-lrme`) handle `CAM_QUERY_CAP` through a nested `struct cam_query_cap_cmd` whose `caps_handle` points to the device-specific query payload.
  - Sensor-family direct subdevs (`cam-sensor-driver`, `cam-csiphy-driver`, `cam-actuator-driver`, `cam-eeprom`, `cam-ois`) and CPAS handle `CAM_QUERY_CAP` with the device-specific query payload directly in `cam_control.handle`.
  - `CAM_SENSOR_PROBE_CMD`, `CAM_ACQUIRE_DEV`, `CAM_START_DEV`, `CAM_CONFIG_DEV`, request-manager session/link ioctls, and `cam_sync` create/destroy/wait ioctls are not part of the first probe.

## Approach

- Keep Android camera support untouched until Linux probing has its own reliable evidence.
- Evaluate two backend tracks in parallel:
  - direct Linux kernel UAPI: read-only discovery first, then only narrowly scoped session/acquire probes if the evidence supports it
  - contained vendor HAL: inventory dependency closure, prove whether the Pixel HAL/provider can be loaded or talked to from a small native daemon, then attempt one constrained frame
- Keep Shadow's camera-facing API Rust-owned in both tracks. Android Binder, HAL structs, native handles, gralloc/AHardwareBuffer, and vendor libraries must stay behind one narrow backend boundary.
- Start the Linux track with read-only kernel ABI discovery:
  - media controller device info/topology
  - V4L2 node capabilities
  - V4L2 subdevice capabilities
  - Qualcomm camera private query-cap ioctls where the payload shape is known from public UAPI source
  - sysfs names, major/minor pairs, SELinux labels, and owner/group/mode
- Treat every ioctl failure as useful output, not as a probe failure, unless opening the expected node set itself fails unexpectedly.
- Correlate Linux node names with Android provider output before attempting any buffer allocation or capture request.
- Run the first Linux probe on a leased rooted Pixel with no active Android camera session. Opening/closing Qualcomm camera subdevs is not entirely side-effect free, even when the requested ioctl is query-only.
- Probe `/dev/video1` conservatively:
  - default path records sysfs/media identity and skips private request-manager controls
  - any direct open of `cam-req-mgr` must be short-lived, last in the probe, and reported with `EALREADY`/`EBUSY`/`EACCES` as an expected outcome when Android owns the stack

## Parallel HAL Probe Track

- Goal: determine whether Pixel 4a's vendor camera HAL can be used as a contained backend without making Shadow depend on the Android app/framework camera stack.
- Preferred containment shape:
  - Rust-owned Shadow camera trait/API
  - one small native camera daemon or helper with a narrow command protocol
  - optional C/C++ FFI shim for HAL structs, callbacks, native handles, and linker details
  - vendor HAL/provider code treated as an implementation detail behind that daemon
- First HAL questions:
  - can a native helper direct-load or otherwise instantiate `/vendor/lib64/hw/camera.sm6150.so` and the Google/Qualcomm camera HAL components on the rooted Pixel?
  - which dependencies are required at runtime: Bionic linker namespaces, Android properties, vendor services, gralloc/AHardwareBuffer, sync fences, Binder/HIDL/AIDL libraries, SELinux labels, or camera provider process state?
  - if direct-load is brittle, is talking to the existing provider service a smaller and more reliable contained backend?
- First HAL proof artifacts should mirror the Linux probe lane under `build/pixel/camera-linux-api/<timestamp>-<serial>/` or a sibling `camera-hal-api` run root, with `hal-probe.json`, `device-output.txt`, and `status.json`.
- Success criterion for the HAL probe:
  - list cameras through the contained backend
  - identify the minimal dependency closure
  - either capture one fixed rear-camera frame or report the exact missing dependency/blocker
  - keep the Shadow-facing protocol independent of Android camera API details

## First Runnable Probe Contract

- Probe name: `camera-linux-surface-probe`.
- Proposed command shape:
  - `SHADOW_DEVICE_LEASE_FORCE=1 PIXEL_SERIAL=<serial> scripts/pixel/pixel_camera_rs_run.sh linux-probe`
- Owned code path:
  - add a `linux-probe` command to `rust/shadow-camera-provider-host`
  - keep staging/running through `scripts/pixel/pixel_camera_rs_run.sh`
  - add shared helper knobs to `scripts/lib/pixel_camera_runtime_common.sh` only if the probe needs stable artifact naming or service metadata reuse
- Inputs:
  - `/dev/media0`, `/dev/media1`
  - `/dev/video1`, `/dev/video2`
  - `/dev/v4l-subdev0..16`
  - `/sys/class/video4linux/*`
  - `/proc/devices`
- Expected libraries:
  - first probe should need only Rust `std` plus `libc`/raw `ioctl`; no Android Binder NDK, `libcamera_metadata`, `AHardwareBuffer`, or vendor camera userspace libraries
  - mirror only the minimal Qualcomm UAPI structs needed for query-cap payloads, with size checks in tests/build-time assertions where practical
  - the Android baseline remains useful for comparison and currently depends on Android camera provider Binder services plus platform camera metadata/buffer libraries
  - vendor libraries observed on-device include `/vendor/lib64/hw/camera.sm6150.so`, `libgooglecamerahal*.so`, and Qualcomm `camx`/`chi` components; do not link them in the first Linux-only probe
- Read-only ioctl set:
  - media nodes: `MEDIA_IOC_DEVICE_INFO`, then `MEDIA_IOC_G_TOPOLOGY`; fall back to `MEDIA_IOC_ENUM_ENTITIES` / `MEDIA_IOC_ENUM_LINKS` if topology is unavailable on the 4.14 Pixel kernel
  - V4L2 video/subdev nodes: `VIDIOC_QUERYCAP` / `VIDIOC_SUBDEV_QUERYCAP` where supported, recording `ENOTTY` as data
  - Qualcomm direct `VIDIOC_CAM_CONTROL` + `CAM_QUERY_CAP`:
    - sensor: `struct cam_sensor_query_cap`
    - CPAS: `struct cam_cpas_query_cap`
    - CSIPHY: `struct cam_csiphy_query_cap`
    - actuator: `struct cam_actuator_query_cap`
    - EEPROM: `struct cam_eeprom_query_cap_t`
    - OIS: `struct cam_ois_query_cap_t`
  - Qualcomm nested `VIDIOC_CAM_CONTROL` + `CAM_QUERY_CAP` through `struct cam_query_cap_cmd`:
    - ISP/IFE: `struct cam_isp_query_cap_cmd`
    - JPEG: `struct cam_jpeg_query_cap_cmd`
    - FD: `struct cam_fd_query_cap_cmd`
    - LRME: `struct cam_lrme_query_cap_cmd`
  - forbidden in this probe: `CAM_SENSOR_PROBE_CMD`, `CAM_ACQUIRE_DEV`, `CAM_START_DEV`, `CAM_STOP_DEV`, `CAM_CONFIG_DEV`, request-manager create/link/apply/flush controls, `CAM_SYNC_CREATE`, `CAM_SYNC_DESTROY`, `CAM_SYNC_WAIT`, and any buffer allocation/import/export
- JSON output:
  - `schemaVersion`
  - `serial`, `fingerprint`, `kernelRelease`, `selinuxMode`
  - `androidCameraProviderDeclared`
  - `mediaDevices[]` with open status, device info, topology counts, entities, links, and ioctl errors
  - `videoNodes[]` with name, major/minor, querycap fields, capabilities, device capabilities, and ioctl errors
  - `subdevNodes[]` with sysfs name, major/minor, querycap status, and ioctl errors
  - `qualcommQueryCaps[]` with node, entity type/name, payload kind, decoded fields where safe, raw struct size, and errno/result
  - `exclusiveOpenNotes[]` for `cam-req-mgr` and any node whose open/close semantics are not purely informational
  - `interpretation` with one of `surface-inventory-only`, `topology-visible`, `candidate-capture-path`, or `blocked`
- Proof artifacts:
  - `build/pixel/camera-linux-api/<timestamp>-<serial>/linux-probe.json`
  - `build/pixel/camera-linux-api/<timestamp>-<serial>/device-output.txt`
  - `build/pixel/camera-linux-api/<timestamp>-<serial>/status.json`
- Success criterion for the first probe:
  - it opens the safe expected node families on a rooted Pixel and records intentional skips or exact `errno` for exclusive nodes such as `cam-req-mgr`
  - it records at least one successful Linux camera-surface ioctl or a precise `errno` for every attempted ioctl
  - it proves whether public Qualcomm query-cap UAPI is callable from rooted userspace without invoking acquire/start/config
  - it exits `ok=true` when discovery completed, even if capture remains `blocked`
- Explicit non-goal for the first probe:
  - no `VIDIOC_REQBUFS`, no stream configuration, no media link mutation, no sensor controls, no DMA buffer export/import, no frame capture.

## Steps

- [x] Rebase worker branch onto root `master`.
- [x] Claim `boot-camera-linux-api-recon`.
- [x] Read current boot and camera plans plus supported operator docs.
- [x] Inventory current Android camera path and existing Shadow abstractions.
- [x] Run rooted Pixel Linux camera surface inventory on `0B191JEC203253`.
- [x] Run existing Android provider `list` baseline on `0B191JEC203253`.
- [x] Read relevant AOSP camera HAL and Pixel 4a Qualcomm Linux camera source.
- [x] Define first Linux-only probe contract from source plus device inventory.
- [x] Implement `linux-probe` as the next narrow code slice.
- [x] Validate `linux-probe` on a rooted Pixel and compare with Android provider camera IDs.
- [ ] Add a HAL dependency/probe task to the queue.
- [ ] Run a contained HAL inventory probe and decide whether direct HAL loading or provider-service containment is the smaller backend.
- [ ] Decide whether a direct Linux capture probe is plausible from Linux media/V4L2/Qualcomm UAPI alone or whether that lane should stay limited to instrumentation.
- [ ] Choose the first frame-capture track: direct Linux UAPI, contained HAL backend, or both if the probes remain cheap and informative.

## References

- Android AIDL camera provider source: https://android.googlesource.com/platform/hardware/interfaces/+/refs/heads/main/camera/provider/aidl/android/hardware/camera/provider/ICameraProvider.aidl
- Android AIDL camera device source: https://android.googlesource.com/platform/hardware/interfaces/+/refs/heads/main/camera/device/aidl/android/hardware/camera/device/ICameraDevice.aidl
- Android AIDL camera session source: https://android.googlesource.com/platform/hardware/interfaces/+/refs/heads/main/camera/device/aidl/android/hardware/camera/device/ICameraDeviceSession.aidl
- Android HIDL provider 2.7 source: https://android.googlesource.com/platform/hardware/interfaces/+/refs/heads/main/camera/provider/2.7/ICameraProvider.hal
- Pixel 4a public kernel branch used for recon: https://android.googlesource.com/kernel/msm/+/refs/heads/android-msm-sunfish-4.14-android13-qpr3
- Qualcomm camera common UAPI: https://android.googlesource.com/kernel/msm/+/refs/heads/android-msm-sunfish-4.14-android13-qpr3/include/uapi/media/cam_defs.h
- Qualcomm camera request-manager UAPI: https://android.googlesource.com/kernel/msm/+/refs/heads/android-msm-sunfish-4.14-android13-qpr3/include/uapi/media/cam_req_mgr.h
- Qualcomm request-manager driver: https://android.googlesource.com/kernel/msm/+/refs/heads/android-msm-sunfish-4.14-android13-qpr3/drivers/media/platform/msm/camera/cam_req_mgr/cam_req_mgr_dev.c
- Qualcomm generic camera subdev/node drivers: https://android.googlesource.com/kernel/msm/+/refs/heads/android-msm-sunfish-4.14-android13-qpr3/drivers/media/platform/msm/camera/cam_core/cam_subdev.c and https://android.googlesource.com/kernel/msm/+/refs/heads/android-msm-sunfish-4.14-android13-qpr3/drivers/media/platform/msm/camera/cam_core/cam_node.c
- Qualcomm sensor-family UAPI: https://android.googlesource.com/kernel/msm/+/refs/heads/android-msm-sunfish-4.14-android13-qpr3/include/uapi/media/cam_sensor.h
- Linux Media Controller API: https://docs.kernel.org/userspace-api/media/mediactl/media-controller.html
- Linux media controller uAPI symbols: https://docs.kernel.org/userspace-api/media/mediactl/media-header.html
- Linux `VIDIOC_QUERYCAP`: https://docs.kernel.org/userspace-api/media/v4l/vidioc-querycap.html
- Linux `VIDIOC_SUBDEV_QUERYCAP`: https://www.infradead.org/~mchehab/kernel_docs/userspace-api/media/v4l/vidioc-subdev-querycap.html
- Android Camera HAL overview: https://source.android.com/docs/core/camera/camera3

## Implementation Notes

- `0B191JEC203253` was root-ready. `09051JEC202061` was attached but not root-ready during this pass.
- `/dev/media*` and the Qualcomm camera nodes are owned `system:camera` with `u:object_r:video_device:s0`; root can open them in Android userspace, but boot-owned userspace will need matching node creation, ownership, and SELinux implications only after the read-only ABI probe proves useful.
- Current Android provider process is `android.hardware.camera.provider@2.7-service-google`; current Shadow helper talks to service `android.hardware.camera.provider.ICameraProvider/internal/0`.
- The source-level correction is that Linux recon is not plain media/V4L2. The useful public ABI is media topology plus Qualcomm private `VIDIOC_CAM_CONTROL` query-cap payloads, with strict no-acquire/no-start/no-config limits.
- The implemented probe is still discovery-only. Successful query-cap proves the kernel surface is reachable from rooted userspace; it does not prove Linux-only capture because capture still requires sessions, request-manager links, buffers, sync objects, sensor power/config packets, and likely vendor HAL policy.
- A Linux-only camera library should probably start as a separate internal module under `rust/shadow-camera-provider-host` or a new narrow `rust/shadow-linux-camera-probe` binary, then graduate only if the discovery probe identifies a real capture path.
- A HAL-backed path should start as a quarantined backend, not as Shadow adopting Android camera architecture. The acceptable shape is a small Rust-facing daemon/helper that hides Android/HAL details and can later be swapped or retired if direct Linux capture becomes viable.
