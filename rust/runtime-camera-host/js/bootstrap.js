import { core } from "ext:core/mod.js";

function installShadowRuntimeCamera() {
  const shadow = globalThis.Shadow ?? {};
  const os = shadow.os ?? {};
  const camera = {
    async listCameras() {
      return await core.ops.op_runtime_camera_list_cameras();
    },
    async captureStill(request = {}) {
      return await core.ops.op_runtime_camera_capture_still(request);
    },
    debugLog(message) {
      core.ops.op_runtime_camera_debug_log(String(message));
    },

    async decodeQrCode(request = {}) {
      return await core.ops.op_runtime_camera_decode_qr_code(request);
    },
  };

  globalThis.Shadow = {
    ...shadow,
    os: {
      ...os,
      camera,
    },
  };
}

installShadowRuntimeCamera();
