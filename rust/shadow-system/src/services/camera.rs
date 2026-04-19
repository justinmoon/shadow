use deno_core::{extension, op2, Extension};
use deno_error::JsErrorBox;
use shadow_sdk::services::camera_backend::{
    self, CameraDevice, CaptureRequest, CaptureStillReceipt, DecodeQrCodeReceipt,
    DecodeQrCodeRequest,
};

#[op2]
#[serde]
async fn op_runtime_camera_list_cameras() -> Result<Vec<CameraDevice>, JsErrorBox> {
    tokio::task::spawn_blocking(camera_backend::list_cameras)
        .await
        .map_err(|error| JsErrorBox::generic(format!("camera.listCameras join: {error}")))?
        .map_err(|error| JsErrorBox::generic(error.to_string()))
}

#[op2]
#[serde]
async fn op_runtime_camera_capture_still(
    #[serde] request: CaptureRequest,
) -> Result<CaptureStillReceipt, JsErrorBox> {
    tokio::task::spawn_blocking(move || camera_backend::capture_still(request))
        .await
        .map_err(|error| JsErrorBox::generic(format!("camera.captureStill join: {error}")))?
        .map_err(|error| JsErrorBox::generic(error.to_string()))
}

#[op2]
#[serde]
async fn op_runtime_camera_capture_preview_frame(
    #[serde] request: CaptureRequest,
) -> Result<CaptureStillReceipt, JsErrorBox> {
    tokio::task::spawn_blocking(move || camera_backend::capture_preview_frame(request))
        .await
        .map_err(|error| JsErrorBox::generic(format!("camera.capturePreviewFrame join: {error}")))?
        .map_err(|error| JsErrorBox::generic(error.to_string()))
}

#[op2(fast)]
fn op_runtime_camera_debug_log(#[string] message: String) {
    eprintln!("[shadow-system-camera] {message}");
}

#[op2]
#[serde]
async fn op_runtime_camera_decode_qr_code(
    #[serde] request: DecodeQrCodeRequest,
) -> Result<DecodeQrCodeReceipt, JsErrorBox> {
    tokio::task::spawn_blocking(move || camera_backend::decode_qr_code(request))
        .await
        .map_err(|error| JsErrorBox::generic(format!("camera.decodeQrCode join: {error}")))?
        .map_err(|error| JsErrorBox::generic(error.to_string()))
}

extension!(
    shadow_system_camera_extension,
    ops = [
        op_runtime_camera_list_cameras,
        op_runtime_camera_capture_still,
        op_runtime_camera_capture_preview_frame,
        op_runtime_camera_debug_log,
        op_runtime_camera_decode_qr_code
    ],
);

pub fn init_extension() -> Extension {
    shadow_system_camera_extension::init()
}
