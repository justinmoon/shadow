use std::fmt;

use super::camera_backend;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CameraInfo {
    pub id: String,
    pub label: String,
    pub lens_facing: LensFacing,
    pub sensor_orientation_degrees: Option<u16>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LensFacing {
    Front,
    Rear,
    External,
    Unknown(String),
}

impl LensFacing {
    pub fn as_str(&self) -> &str {
        match self {
            Self::Front => "front",
            Self::Rear => "rear",
            Self::External => "external",
            Self::Unknown(value) => value.as_str(),
        }
    }
}

impl fmt::Display for LensFacing {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CaptureRequest {
    pub camera_id: Option<String>,
}

impl CaptureRequest {
    pub fn with_camera_id(mut self, camera_id: impl Into<String>) -> Self {
        self.camera_id = Some(camera_id.into());
        self
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CaptureResult {
    pub bytes: usize,
    pub camera_id: String,
    pub captured_at_ms: u64,
    pub image_data_url: String,
    pub mime_type: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DecodedQrCode {
    pub code_count: usize,
    pub payload: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CameraErrorKind {
    NotConfigured,
    Unavailable,
    NoCamera,
    InvalidImageData,
    QrCodeNotFound,
    Other,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CameraError {
    kind: CameraErrorKind,
    message: String,
}

impl CameraError {
    pub fn kind(&self) -> CameraErrorKind {
        self.kind
    }
}

impl fmt::Display for CameraError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for CameraError {}

impl From<camera_backend::CameraHostError> for CameraError {
    fn from(error: camera_backend::CameraHostError) -> Self {
        let kind = match error.kind() {
            camera_backend::CameraHostErrorKind::BackendNotConfigured => {
                CameraErrorKind::NotConfigured
            }
            camera_backend::CameraHostErrorKind::Unavailable => CameraErrorKind::Unavailable,
            camera_backend::CameraHostErrorKind::NoCamera => CameraErrorKind::NoCamera,
            camera_backend::CameraHostErrorKind::InvalidImageData => {
                CameraErrorKind::InvalidImageData
            }
            camera_backend::CameraHostErrorKind::QrCodeNotFound => CameraErrorKind::QrCodeNotFound,
            camera_backend::CameraHostErrorKind::Other => CameraErrorKind::Other,
        };
        Self {
            kind,
            message: error.to_string(),
        }
    }
}

impl From<String> for CameraError {
    fn from(message: String) -> Self {
        Self {
            kind: CameraErrorKind::Other,
            message,
        }
    }
}

pub fn list_cameras() -> Result<Vec<CameraInfo>, CameraError> {
    camera_backend::list_cameras()
        .map(|devices| devices.into_iter().map(CameraInfo::from).collect())
        .map_err(CameraError::from)
}

pub fn capture_still(request: CaptureRequest) -> Result<CaptureResult, CameraError> {
    camera_backend::capture_still(request.into())
        .map(CaptureResult::from)
        .map_err(CameraError::from)
}

pub fn decode_qr_code(image_data_url: impl Into<String>) -> Result<DecodedQrCode, CameraError> {
    camera_backend::decode_qr_code(camera_backend::DecodeQrCodeRequest {
        image_data_url: Some(image_data_url.into()),
    })
    .map(DecodedQrCode::from)
    .map_err(CameraError::from)
}

impl From<camera_backend::CameraDevice> for CameraInfo {
    fn from(value: camera_backend::CameraDevice) -> Self {
        Self {
            id: value.id,
            label: value.label,
            lens_facing: LensFacing::from(value.lens_facing),
            sensor_orientation_degrees: value.sensor_orientation_degrees,
        }
    }
}

impl From<String> for LensFacing {
    fn from(value: String) -> Self {
        match value.as_str() {
            "front" => Self::Front,
            "rear" => Self::Rear,
            "external" => Self::External,
            _ => Self::Unknown(value),
        }
    }
}

impl From<CaptureRequest> for camera_backend::CaptureRequest {
    fn from(value: CaptureRequest) -> Self {
        Self {
            camera_id: value.camera_id,
        }
    }
}

impl From<camera_backend::CaptureStillReceipt> for CaptureResult {
    fn from(value: camera_backend::CaptureStillReceipt) -> Self {
        Self {
            bytes: value.bytes,
            camera_id: value.camera_id,
            captured_at_ms: value.captured_at_ms,
            image_data_url: value.image_data_url,
            mime_type: value.mime_type,
        }
    }
}

impl From<camera_backend::DecodeQrCodeReceipt> for DecodedQrCode {
    fn from(value: camera_backend::DecodeQrCodeReceipt) -> Self {
        Self {
            code_count: value.code_count,
            payload: value.payload,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        capture_still, decode_qr_code, list_cameras, CameraError, CameraErrorKind, CaptureRequest,
        LensFacing,
    };
    use crate::services::camera_backend::{
        clear_test_camera_env, test_camera_env_lock, CAMERA_ALLOW_MOCK_ENV, CAMERA_ENDPOINT_ENV,
        CAMERA_MOCK_QR_PAYLOAD_ENV,
    };

    #[test]
    fn camera_api_uses_the_shared_mock_path() {
        let _guard = test_camera_env_lock().lock().expect("env lock");
        clear_test_camera_env();
        std::env::set_var(CAMERA_ALLOW_MOCK_ENV, "1");

        let cameras = list_cameras().expect("mock cameras");
        let capture =
            capture_still(CaptureRequest::default().with_camera_id(cameras[0].id.clone()))
                .expect("mock capture");

        assert_eq!(cameras[0].label, "Mock Rear Camera");
        assert_eq!(cameras[0].lens_facing, LensFacing::Rear);
        assert_eq!(capture.camera_id, cameras[0].id);
        assert_eq!(capture.mime_type, "image/svg+xml");
    }

    #[test]
    fn camera_api_decodes_mock_qr_payloads() {
        let _guard = test_camera_env_lock().lock().expect("env lock");
        clear_test_camera_env();
        std::env::set_var(CAMERA_ALLOW_MOCK_ENV, "1");
        std::env::set_var(CAMERA_MOCK_QR_PAYLOAD_ENV, "shadow://camera-sdk");

        let capture = capture_still(CaptureRequest::default()).expect("mock capture");
        let decoded = decode_qr_code(capture.image_data_url).expect("decode qr");

        assert_eq!(decoded.code_count, 1);
        assert_eq!(decoded.payload, "shadow://camera-sdk");
    }

    #[test]
    fn camera_error_preserves_backend_configuration_failures() {
        let _guard = test_camera_env_lock().lock().expect("env lock");
        clear_test_camera_env();

        let error = list_cameras().unwrap_err();
        assert_eq!(error.kind(), CameraErrorKind::NotConfigured);
        assert!(error.to_string().contains(CAMERA_ENDPOINT_ENV));
        assert!(error.to_string().contains(CAMERA_ALLOW_MOCK_ENV));
    }

    #[test]
    fn unknown_lens_facing_round_trips_verbatim() {
        let facing = LensFacing::from(String::from("sidecar"));
        assert_eq!(facing.as_str(), "sidecar");
        assert_eq!(facing.to_string(), "sidecar");
    }

    #[test]
    fn camera_error_implements_std_error() {
        let error = CameraError::from(String::from("camera boom"));
        let source: &dyn std::error::Error = &error;
        assert_eq!(source.to_string(), "camera boom");
    }
}
