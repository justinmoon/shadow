use std::env;
use std::fmt;
use std::io::Cursor;
use std::io::ErrorKind;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use base64::Engine as _;
#[cfg(feature = "runtime-extension")]
use deno_core::{extension, op2, Extension};
#[cfg(feature = "runtime-extension")]
use deno_error::JsErrorBox;
use image::ImageFormat;
use image::{DynamicImage, ImageBuffer, Luma};
use qrcodegen::{QrCode, QrCodeEcc};
use serde::{Deserialize, Serialize};

pub const CAMERA_ENDPOINT_ENV: &str = "SHADOW_RUNTIME_CAMERA_ENDPOINT";
pub const CAMERA_ALLOW_MOCK_ENV: &str = "SHADOW_RUNTIME_CAMERA_ALLOW_MOCK";
pub const CAMERA_MOCK_QR_PAYLOAD_ENV: &str = "SHADOW_RUNTIME_CAMERA_MOCK_QR_PAYLOAD";
pub const CAMERA_TIMEOUT_MS_ENV: &str = "SHADOW_RUNTIME_CAMERA_TIMEOUT_MS";
const DEFAULT_TIMEOUT_MS: u64 = 30_000;
const CONNECT_RETRY_ATTEMPTS: usize = 10;
const CONNECT_RETRY_DELAY_MS: u64 = 250;
const MOCK_CAMERA_ID: &str = "mock/rear/0";
const MOCK_QR_BORDER_MODULES: u32 = 4;
const MOCK_QR_MODULE_SCALE: u32 = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CameraHostErrorKind {
    BackendNotConfigured,
    Unavailable,
    NoCamera,
    InvalidImageData,
    QrCodeNotFound,
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CameraHostError {
    kind: CameraHostErrorKind,
    message: String,
}

impl CameraHostError {
    pub fn kind(&self) -> CameraHostErrorKind {
        self.kind
    }

    pub fn message(&self) -> &str {
        &self.message
    }

    fn new(kind: CameraHostErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    fn backend_not_configured(message: impl Into<String>) -> Self {
        Self::new(CameraHostErrorKind::BackendNotConfigured, message)
    }

    fn unavailable(message: impl Into<String>) -> Self {
        Self::new(CameraHostErrorKind::Unavailable, message)
    }

    fn no_camera(message: impl Into<String>) -> Self {
        Self::new(CameraHostErrorKind::NoCamera, message)
    }

    fn invalid_image_data(message: impl Into<String>) -> Self {
        Self::new(CameraHostErrorKind::InvalidImageData, message)
    }

    fn qr_code_not_found(message: impl Into<String>) -> Self {
        Self::new(CameraHostErrorKind::QrCodeNotFound, message)
    }

    fn other(message: impl Into<String>) -> Self {
        Self::new(CameraHostErrorKind::Other, message)
    }
}

impl fmt::Display for CameraHostError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for CameraHostError {}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct CameraDevice {
    pub id: String,
    pub label: String,
    #[serde(rename = "lensFacing")]
    pub lens_facing: String,
    #[serde(
        rename = "sensorOrientationDegrees",
        skip_serializing_if = "Option::is_none"
    )]
    pub sensor_orientation_degrees: Option<u16>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct CaptureRequest {
    #[serde(rename = "cameraId")]
    pub camera_id: Option<String>,
}

impl CaptureRequest {
    pub fn with_camera_id(mut self, camera_id: impl Into<String>) -> Self {
        self.camera_id = Some(camera_id.into());
        self
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct CaptureStillReceipt {
    pub bytes: usize,
    #[serde(rename = "cameraId")]
    pub camera_id: String,
    #[serde(rename = "capturedAtMs")]
    pub captured_at_ms: u64,
    #[serde(rename = "imageDataUrl")]
    pub image_data_url: String,
    #[serde(rename = "isMock")]
    pub is_mock: bool,
    #[serde(rename = "mimeType")]
    pub mime_type: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct DecodeQrCodeRequest {
    #[serde(rename = "imageDataUrl")]
    pub image_data_url: Option<String>,
}

impl DecodeQrCodeRequest {
    pub fn with_image_data_url(mut self, image_data_url: impl Into<String>) -> Self {
        self.image_data_url = Some(image_data_url.into());
        self
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct DecodeQrCodeReceipt {
    #[serde(rename = "codeCount")]
    pub code_count: usize,
    pub payload: String,
}

#[derive(Debug, Serialize)]
struct BrokerRequest<'a> {
    command: &'a str,
    #[serde(rename = "cameraId", skip_serializing_if = "Option::is_none")]
    camera_id: Option<&'a str>,
}

#[derive(Debug, Deserialize)]
struct BrokerListResponse {
    ok: bool,
    #[serde(default)]
    cameras: Vec<BrokerCameraDevice>,
    #[serde(rename = "cameraIds", default)]
    camera_ids: Vec<String>,
    error: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct BrokerCameraDevice {
    id: String,
    #[serde(default)]
    label: Option<String>,
    #[serde(rename = "lensFacing", default)]
    lens_facing: Option<String>,
    #[serde(rename = "sensorOrientationDegrees", default)]
    sensor_orientation_degrees: Option<u16>,
}

#[derive(Debug, Deserialize)]
struct BrokerCaptureResponse {
    ok: bool,
    #[serde(rename = "bytesWritten", default)]
    bytes_written: usize,
    #[serde(rename = "displayRotationDegrees", default)]
    display_rotation_degrees: u16,
    error: Option<String>,
    #[serde(rename = "imageBase64")]
    image_base64: Option<String>,
    #[serde(rename = "mimeType")]
    mime_type: Option<String>,
    #[serde(rename = "selectedCamera")]
    selected_camera: Option<String>,
}

#[derive(Debug, Clone)]
struct CameraHostConfig {
    endpoint: Option<String>,
    allow_mock: bool,
    timeout: Duration,
}

impl CameraHostConfig {
    fn from_env() -> Self {
        let endpoint = env::var(CAMERA_ENDPOINT_ENV)
            .ok()
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty());
        let timeout = env::var(CAMERA_TIMEOUT_MS_ENV)
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .filter(|value| *value > 0)
            .map(Duration::from_millis)
            .unwrap_or_else(|| Duration::from_millis(DEFAULT_TIMEOUT_MS));
        let allow_mock = env::var(CAMERA_ALLOW_MOCK_ENV)
            .ok()
            .is_some_and(|value| parse_truthy_env(&value));

        Self {
            endpoint,
            allow_mock,
            timeout,
        }
    }

    fn list_cameras(&self) -> Result<Vec<CameraDevice>, CameraHostError> {
        match self.endpoint.as_deref() {
            Some(endpoint) => self.list_cameras_via_broker(endpoint),
            None if self.allow_mock => Ok(mock_cameras()),
            None => Err(missing_camera_backend_error()),
        }
    }

    fn capture_still(
        &self,
        request: CaptureRequest,
    ) -> Result<CaptureStillReceipt, CameraHostError> {
        match self.endpoint.as_deref() {
            Some(endpoint) => self.capture_via_broker(endpoint, request),
            None if self.allow_mock => mock_capture(request.camera_id),
            None => Err(missing_camera_backend_error()),
        }
    }

    fn capture_preview_frame(
        &self,
        request: CaptureRequest,
    ) -> Result<CaptureStillReceipt, CameraHostError> {
        match self.endpoint.as_deref() {
            Some(endpoint) => self.capture_preview_via_broker(endpoint, request),
            None if self.allow_mock => mock_capture(request.camera_id),
            None => Err(missing_camera_backend_error()),
        }
    }

    fn list_cameras_via_broker(
        &self,
        endpoint: &str,
    ) -> Result<Vec<CameraDevice>, CameraHostError> {
        let response: BrokerListResponse = self.send(
            endpoint,
            BrokerRequest {
                command: "list",
                camera_id: None,
            },
        )?;
        if !response.ok {
            return Err(CameraHostError::unavailable(
                response
                    .error
                    .unwrap_or_else(|| String::from("camera broker list failed")),
            ));
        }

        if response.camera_ids.is_empty() {
            if response.cameras.is_empty() {
                return Err(CameraHostError::no_camera(
                    "camera broker returned no camera descriptors",
                ));
            }
        }

        Ok(camera_devices_from_broker_list_response(response))
    }

    fn capture_via_broker(
        &self,
        endpoint: &str,
        request: CaptureRequest,
    ) -> Result<CaptureStillReceipt, CameraHostError> {
        self.capture_frame_via_broker(endpoint, "capture", request)
    }

    fn capture_preview_via_broker(
        &self,
        endpoint: &str,
        request: CaptureRequest,
    ) -> Result<CaptureStillReceipt, CameraHostError> {
        self.capture_frame_via_broker(endpoint, "preview", request)
    }

    fn capture_frame_via_broker(
        &self,
        endpoint: &str,
        command: &'static str,
        request: CaptureRequest,
    ) -> Result<CaptureStillReceipt, CameraHostError> {
        let response: BrokerCaptureResponse = self.send(
            endpoint,
            BrokerRequest {
                command,
                camera_id: request.camera_id.as_deref(),
            },
        )?;
        if !response.ok {
            return Err(CameraHostError::unavailable(
                response
                    .error
                    .unwrap_or_else(|| format!("camera broker {command} failed")),
            ));
        }

        let image_base64 = response.image_base64.ok_or_else(|| {
            CameraHostError::other("camera broker capture response missing imageBase64")
        })?;
        let mime_type = response
            .mime_type
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| String::from("image/jpeg"));
        let camera_id = response
            .selected_camera
            .or(request.camera_id)
            .unwrap_or_else(|| String::from(MOCK_CAMERA_ID));
        let (image_data_url, final_mime_type, final_bytes) = build_capture_image_data_url(
            &image_base64,
            &mime_type,
            response.display_rotation_degrees,
            response.bytes_written,
        )?;

        Ok(CaptureStillReceipt {
            bytes: final_bytes,
            camera_id,
            captured_at_ms: unix_time_ms(),
            image_data_url,
            is_mock: false,
            mime_type: final_mime_type,
        })
    }

    fn send<Response>(
        &self,
        endpoint: &str,
        request: BrokerRequest<'_>,
    ) -> Result<Response, CameraHostError>
    where
        Response: for<'de> Deserialize<'de>,
    {
        let mut addrs = endpoint.to_socket_addrs().map_err(|error| {
            CameraHostError::unavailable(format!("resolve camera endpoint {endpoint}: {error}"))
        })?;
        let address = addrs.next().ok_or_else(|| {
            CameraHostError::unavailable(format!("camera endpoint {endpoint} did not resolve"))
        })?;
        let mut stream = connect_with_retry(address, self.timeout).map_err(|error| {
            CameraHostError::unavailable(format!("connect camera endpoint {endpoint}: {error}"))
        })?;
        stream
            .set_read_timeout(Some(self.timeout))
            .map_err(|error| {
                CameraHostError::unavailable(format!("set camera endpoint read timeout: {error}"))
            })?;
        stream
            .set_write_timeout(Some(self.timeout))
            .map_err(|error| {
                CameraHostError::unavailable(format!("set camera endpoint write timeout: {error}"))
            })?;

        let encoded = serde_json::to_string(&request)
            .map_err(|error| CameraHostError::other(format!("encode camera request: {error}")))?;
        writeln!(stream, "{encoded}")
            .and_then(|_| stream.flush())
            .map_err(|error| {
                CameraHostError::unavailable(format!("write camera request: {error}"))
            })?;

        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        let read = reader.read_line(&mut line).map_err(|error| {
            CameraHostError::unavailable(format!("read camera response: {error}"))
        })?;
        if read == 0 {
            return Err(CameraHostError::unavailable(
                "camera broker closed connection without a response",
            ));
        }

        serde_json::from_str::<Response>(line.trim_end()).map_err(|error| {
            CameraHostError::unavailable(format!("decode camera response: {error}"))
        })
    }
}

fn connect_with_retry(
    address: std::net::SocketAddr,
    timeout: Duration,
) -> Result<TcpStream, std::io::Error> {
    let mut last_error = None;
    for attempt in 0..CONNECT_RETRY_ATTEMPTS {
        match TcpStream::connect_timeout(&address, timeout) {
            Ok(stream) => return Ok(stream),
            Err(error) if should_retry_connect(&error) && attempt + 1 < CONNECT_RETRY_ATTEMPTS => {
                last_error = Some(error);
                thread::sleep(Duration::from_millis(CONNECT_RETRY_DELAY_MS));
            }
            Err(error) => return Err(error),
        }
    }

    Err(last_error.unwrap_or_else(|| {
        std::io::Error::new(
            ErrorKind::TimedOut,
            "camera endpoint retry budget exhausted",
        )
    }))
}

fn should_retry_connect(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        ErrorKind::ConnectionRefused
            | ErrorKind::ConnectionAborted
            | ErrorKind::ConnectionReset
            | ErrorKind::Interrupted
            | ErrorKind::TimedOut
    )
}

fn parse_truthy_env(value: &str) -> bool {
    matches!(
        value.trim().to_ascii_lowercase().as_str(),
        "1" | "true" | "yes" | "on"
    )
}

fn missing_camera_backend_error() -> CameraHostError {
    CameraHostError::backend_not_configured(format!(
        "camera backend not configured; set {CAMERA_ENDPOINT_ENV} for live capture or {CAMERA_ALLOW_MOCK_ENV}=1 for explicit mock mode"
    ))
}

pub fn list_cameras() -> Result<Vec<CameraDevice>, CameraHostError> {
    CameraHostConfig::from_env().list_cameras()
}

pub fn capture_still(request: CaptureRequest) -> Result<CaptureStillReceipt, CameraHostError> {
    CameraHostConfig::from_env().capture_still(request)
}

pub fn capture_preview_frame(
    request: CaptureRequest,
) -> Result<CaptureStillReceipt, CameraHostError> {
    CameraHostConfig::from_env().capture_preview_frame(request)
}

pub fn decode_qr_code(
    request: DecodeQrCodeRequest,
) -> Result<DecodeQrCodeReceipt, CameraHostError> {
    decode_qr_code_request(request)
}

#[cfg(feature = "runtime-extension")]
#[op2]
#[serde]
async fn op_runtime_camera_list_cameras() -> Result<Vec<CameraDevice>, JsErrorBox> {
    tokio::task::spawn_blocking(list_cameras)
        .await
        .map_err(|error| JsErrorBox::generic(format!("camera.listCameras join: {error}")))?
        .map_err(|error| JsErrorBox::generic(error.to_string()))
}

#[cfg(feature = "runtime-extension")]
#[op2]
#[serde]
async fn op_runtime_camera_capture_still(
    #[serde] request: CaptureRequest,
) -> Result<CaptureStillReceipt, JsErrorBox> {
    tokio::task::spawn_blocking(move || capture_still(request))
        .await
        .map_err(|error| JsErrorBox::generic(format!("camera.captureStill join: {error}")))?
        .map_err(|error| JsErrorBox::generic(error.to_string()))
}

#[cfg(feature = "runtime-extension")]
#[op2]
#[serde]
async fn op_runtime_camera_capture_preview_frame(
    #[serde] request: CaptureRequest,
) -> Result<CaptureStillReceipt, JsErrorBox> {
    tokio::task::spawn_blocking(move || capture_preview_frame(request))
        .await
        .map_err(|error| JsErrorBox::generic(format!("camera.capturePreviewFrame join: {error}")))?
        .map_err(|error| JsErrorBox::generic(error.to_string()))
}

#[cfg(feature = "runtime-extension")]
#[op2(fast)]
fn op_runtime_camera_debug_log(#[string] message: String) {
    eprintln!("[shadow-runtime-camera] {message}");
}

#[cfg(feature = "runtime-extension")]
#[op2]
#[serde]
async fn op_runtime_camera_decode_qr_code(
    #[serde] request: DecodeQrCodeRequest,
) -> Result<DecodeQrCodeReceipt, JsErrorBox> {
    tokio::task::spawn_blocking(move || decode_qr_code(request))
        .await
        .map_err(|error| JsErrorBox::generic(format!("camera.decodeQrCode join: {error}")))?
        .map_err(|error| JsErrorBox::generic(error.to_string()))
}

fn label_for_camera_id(camera_id: &str) -> String {
    if camera_id.ends_with("/0") {
        return String::from("Rear Camera");
    }
    if camera_id.ends_with("/1") {
        return String::from("Front Camera");
    }
    format!("Camera {camera_id}")
}

fn label_for_camera(camera_id: &str, lens_facing: &str) -> String {
    match lens_facing {
        "front" => String::from("Front Camera"),
        "rear" => String::from("Rear Camera"),
        "external" => String::from("External Camera"),
        _ => label_for_camera_id(camera_id),
    }
}

fn lens_facing_for_camera_id(camera_id: &str) -> String {
    if camera_id.ends_with("/1") {
        return String::from("front");
    }
    String::from("rear")
}

fn camera_devices_from_broker_list_response(response: BrokerListResponse) -> Vec<CameraDevice> {
    if !response.cameras.is_empty() {
        return response
            .cameras
            .into_iter()
            .map(camera_device_from_broker_camera)
            .collect();
    }

    response
        .camera_ids
        .into_iter()
        .map(|camera_id| CameraDevice {
            label: label_for_camera_id(&camera_id),
            lens_facing: lens_facing_for_camera_id(&camera_id),
            sensor_orientation_degrees: None,
            id: camera_id,
        })
        .collect()
}

fn camera_device_from_broker_camera(camera: BrokerCameraDevice) -> CameraDevice {
    let lens_facing = camera
        .lens_facing
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| lens_facing_for_camera_id(&camera.id));
    let label = camera
        .label
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| label_for_camera(&camera.id, &lens_facing));

    CameraDevice {
        id: camera.id,
        label,
        lens_facing,
        sensor_orientation_degrees: camera.sensor_orientation_degrees,
    }
}

fn mock_cameras() -> Vec<CameraDevice> {
    vec![CameraDevice {
        id: String::from(MOCK_CAMERA_ID),
        label: String::from("Mock Rear Camera"),
        lens_facing: String::from("rear"),
        sensor_orientation_degrees: None,
    }]
}

fn mock_capture(camera_id: Option<String>) -> Result<CaptureStillReceipt, CameraHostError> {
    if let Some(payload) = env::var(CAMERA_MOCK_QR_PAYLOAD_ENV)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
    {
        return mock_qr_capture(camera_id, &payload);
    }

    let timestamp = unix_time_ms();
    let card = timestamp % 10_000;
    let svg = format!(
        "<svg xmlns='http://www.w3.org/2000/svg' width='720' height='960' viewBox='0 0 720 960'>\
<defs><linearGradient id='g' x1='0' x2='1' y1='0' y2='1'><stop stop-color='#1d4ed8'/><stop offset='0.55' stop-color='#0f766e'/><stop offset='1' stop-color='#f97316'/></linearGradient></defs>\
<rect width='720' height='960' fill='url(#g)' rx='44'/>\
<circle cx='560' cy='200' r='128' fill='rgba(255,255,255,0.22)'/>\
<rect x='72' y='116' width='576' height='728' rx='36' fill='rgba(2,6,23,0.38)' stroke='rgba(255,255,255,0.22)' stroke-width='4'/>\
<text x='96' y='214' fill='#f8fafc' font-family='Google Sans, Roboto, sans-serif' font-size='34' font-weight='700'>Shadow Camera Mock</text>\
<text x='96' y='276' fill='#dbeafe' font-family='Google Sans, Roboto, sans-serif' font-size='24'>Explicit mock camera mode is active.</text>\
<text x='96' y='744' fill='#f8fafc' font-family='Google Sans, Roboto, sans-serif' font-size='112' font-weight='800'>Frame {card:04}</text>\
<text x='96' y='806' fill='#e2e8f0' font-family='Google Sans, Roboto, sans-serif' font-size='28'>Captured at {timestamp}</text>\
</svg>"
    );

    Ok(CaptureStillReceipt {
        bytes: svg.len(),
        camera_id: camera_id.unwrap_or_else(|| String::from(MOCK_CAMERA_ID)),
        captured_at_ms: timestamp,
        image_data_url: format!("data:image/svg+xml;utf8,{}", encode_svg_data_url(&svg)),
        is_mock: true,
        mime_type: String::from("image/svg+xml"),
    })
}

fn mock_qr_capture(
    camera_id: Option<String>,
    payload: &str,
) -> Result<CaptureStillReceipt, CameraHostError> {
    let (image_data_url, bytes) = build_qr_png_data_url(payload)?;
    Ok(CaptureStillReceipt {
        bytes,
        camera_id: camera_id.unwrap_or_else(|| String::from(MOCK_CAMERA_ID)),
        captured_at_ms: unix_time_ms(),
        image_data_url,
        is_mock: true,
        mime_type: String::from("image/png"),
    })
}

fn encode_svg_data_url(svg: &str) -> String {
    let mut encoded = String::with_capacity(svg.len());
    for char in svg.chars() {
        match char {
            '%' => encoded.push_str("%25"),
            ' ' => encoded.push_str("%20"),
            '#' => encoded.push_str("%23"),
            '"' => encoded.push_str("%22"),
            '<' => encoded.push_str("%3C"),
            '>' => encoded.push_str("%3E"),
            '?' => encoded.push_str("%3F"),
            '&' => encoded.push_str("%26"),
            '+' => encoded.push_str("%2B"),
            '\n' => {}
            _ => encoded.push(char),
        }
    }
    encoded
}

fn unix_time_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn build_capture_image_data_url(
    image_base64: &str,
    mime_type: &str,
    display_rotation_degrees: u16,
    fallback_bytes: usize,
) -> Result<(String, String, usize), CameraHostError> {
    let normalized_rotation = normalize_rotation_degrees(display_rotation_degrees);
    if normalized_rotation == 0 {
        return Ok((
            format!("data:{mime_type};base64,{image_base64}"),
            String::from(mime_type),
            fallback_bytes,
        ));
    }

    let format = match image_format_for_mime_type(mime_type) {
        Some(format) => format,
        None => {
            return Ok((
                format!("data:{mime_type};base64,{image_base64}"),
                String::from(mime_type),
                fallback_bytes,
            ));
        }
    };

    let image_bytes = BASE64_STANDARD.decode(image_base64).map_err(|error| {
        CameraHostError::invalid_image_data(format!("decode captured image base64: {error}"))
    })?;
    let image = image::load_from_memory_with_format(&image_bytes, format).map_err(|error| {
        CameraHostError::invalid_image_data(format!("decode captured image: {error}"))
    })?;
    let rotated = match normalized_rotation {
        90 => image.rotate90(),
        180 => image.rotate180(),
        270 => image.rotate270(),
        _ => image,
    };

    let mut encoded = Cursor::new(Vec::new());
    rotated
        .write_to(&mut encoded, ImageFormat::Png)
        .map_err(|error| {
            CameraHostError::other(format!("encode rotated captured image: {error}"))
        })?;
    let output_bytes = encoded.into_inner();
    let output_mime = String::from("image/png");

    Ok((
        format!(
            "data:{output_mime};base64,{}",
            BASE64_STANDARD.encode(&output_bytes)
        ),
        output_mime,
        output_bytes.len(),
    ))
}

fn build_qr_png_data_url(payload: &str) -> Result<(String, usize), CameraHostError> {
    let qr = QrCode::encode_text(payload, QrCodeEcc::Medium)
        .map_err(|error| CameraHostError::other(format!("camera mock QR encode: {error:?}")))?;
    let module_count = qr.size() as u32;
    let image_size = (module_count + MOCK_QR_BORDER_MODULES * 2) * MOCK_QR_MODULE_SCALE;
    let mut image = ImageBuffer::from_pixel(image_size, image_size, Luma([255_u8]));

    for y in 0..module_count {
        for x in 0..module_count {
            if !qr.get_module(x as i32, y as i32) {
                continue;
            }
            let left = (x + MOCK_QR_BORDER_MODULES) * MOCK_QR_MODULE_SCALE;
            let top = (y + MOCK_QR_BORDER_MODULES) * MOCK_QR_MODULE_SCALE;
            for dy in 0..MOCK_QR_MODULE_SCALE {
                for dx in 0..MOCK_QR_MODULE_SCALE {
                    image.put_pixel(left + dx, top + dy, Luma([0_u8]));
                }
            }
        }
    }

    let mut encoded = Cursor::new(Vec::new());
    DynamicImage::ImageLuma8(image)
        .write_to(&mut encoded, ImageFormat::Png)
        .map_err(|error| CameraHostError::other(format!("camera mock QR encode png: {error}")))?;
    let output_bytes = encoded.into_inner();
    Ok((
        format!(
            "data:image/png;base64,{}",
            BASE64_STANDARD.encode(&output_bytes)
        ),
        output_bytes.len(),
    ))
}

fn image_format_for_mime_type(mime_type: &str) -> Option<ImageFormat> {
    match mime_type {
        "image/jpeg" | "image/jpg" => Some(ImageFormat::Jpeg),
        "image/png" => Some(ImageFormat::Png),
        _ => None,
    }
}

fn decode_qr_code_request(
    request: DecodeQrCodeRequest,
) -> Result<DecodeQrCodeReceipt, CameraHostError> {
    let image_data_url = request
        .image_data_url
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            CameraHostError::invalid_image_data("camera.decodeQrCode requires imageDataUrl")
        })?;
    decode_qr_code_from_image_data_url(image_data_url)
}

fn decode_qr_code_from_image_data_url(
    image_data_url: &str,
) -> Result<DecodeQrCodeReceipt, CameraHostError> {
    let image_bytes = decode_image_data_url(image_data_url)?;
    let image = image::load_from_memory(&image_bytes).map_err(|error| {
        CameraHostError::invalid_image_data(format!("camera.decodeQrCode decode image: {error}"))
    })?;
    let mut prepared = rqrr::PreparedImage::prepare(image.to_luma8());
    let grids = prepared.detect_grids();
    let code_count = grids.len();
    if code_count == 0 {
        return Err(CameraHostError::qr_code_not_found(
            "camera.decodeQrCode found no QR code in captured image",
        ));
    }

    let mut errors = Vec::new();
    for grid in grids {
        match grid.decode() {
            Ok((_meta, payload)) if !payload.trim().is_empty() => {
                return Ok(DecodeQrCodeReceipt {
                    code_count,
                    payload,
                });
            }
            Ok((_meta, _payload)) => errors.push(String::from("empty QR payload")),
            Err(error) => errors.push(error.to_string()),
        }
    }

    Err(CameraHostError::qr_code_not_found(format!(
        "camera.decodeQrCode could not decode {} QR code{}: {}",
        code_count,
        if code_count == 1 { "" } else { "s" },
        errors.join("; "),
    )))
}

fn decode_image_data_url(image_data_url: &str) -> Result<Vec<u8>, CameraHostError> {
    let (header, payload) = image_data_url.split_once(',').ok_or_else(|| {
        CameraHostError::invalid_image_data("camera.decodeQrCode imageDataUrl must be a data URL")
    })?;
    let normalized_header = header.to_ascii_lowercase();
    if !normalized_header.starts_with("data:image/") {
        return Err(CameraHostError::invalid_image_data(
            "camera.decodeQrCode imageDataUrl must contain image data",
        ));
    }
    if !normalized_header.contains(";base64") {
        return Err(CameraHostError::invalid_image_data(
            "camera.decodeQrCode imageDataUrl must be base64 encoded",
        ));
    }

    let compact_payload = payload
        .chars()
        .filter(|character| !character.is_ascii_whitespace())
        .collect::<String>();
    BASE64_STANDARD.decode(compact_payload).map_err(|error| {
        CameraHostError::invalid_image_data(format!(
            "camera.decodeQrCode decode base64 image: {error}"
        ))
    })
}

fn normalize_rotation_degrees(rotation_degrees: u16) -> u16 {
    match rotation_degrees % 360 {
        0 => 0,
        90 => 90,
        180 => 180,
        270 => 270,
        _ => 0,
    }
}

#[cfg(feature = "runtime-extension")]
extension!(
    runtime_camera_host_extension,
    ops = [
        op_runtime_camera_list_cameras,
        op_runtime_camera_capture_still,
        op_runtime_camera_capture_preview_frame,
        op_runtime_camera_debug_log,
        op_runtime_camera_decode_qr_code
    ],
    esm_entry_point = "ext:runtime_camera_host_extension/bootstrap.js",
    esm = [dir "js", "bootstrap.js"],
);

#[cfg(feature = "runtime-extension")]
pub fn init_extension() -> Extension {
    runtime_camera_host_extension::init()
}

#[cfg(test)]
mod tests {
    use super::{
        build_capture_image_data_url, build_qr_png_data_url,
        camera_devices_from_broker_list_response, capture_still, decode_image_data_url,
        decode_qr_code, decode_qr_code_from_image_data_url, image_format_for_mime_type,
        list_cameras, missing_camera_backend_error, normalize_rotation_degrees, parse_truthy_env,
        BrokerCameraDevice, BrokerListResponse, CameraHostErrorKind, CaptureRequest,
        DecodeQrCodeRequest, BASE64_STANDARD, CAMERA_ALLOW_MOCK_ENV, CAMERA_ENDPOINT_ENV,
        CAMERA_MOCK_QR_PAYLOAD_ENV, CAMERA_TIMEOUT_MS_ENV,
    };
    use base64::Engine as _;
    use image::{DynamicImage, ImageBuffer, ImageFormat, Luma, Rgb};
    use std::io::Cursor;
    use std::sync::{Mutex, OnceLock};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn clear_camera_env() {
        for key in [
            CAMERA_ALLOW_MOCK_ENV,
            CAMERA_ENDPOINT_ENV,
            CAMERA_MOCK_QR_PAYLOAD_ENV,
            CAMERA_TIMEOUT_MS_ENV,
        ] {
            std::env::remove_var(key);
        }
    }

    fn sample_png_base64(width: u32, height: u32) -> String {
        let image = DynamicImage::ImageRgb8(ImageBuffer::from_fn(width, height, |x, _| {
            if x == 0 {
                Rgb([255, 0, 0])
            } else {
                Rgb([0, 0, 255])
            }
        }));
        let mut output = Cursor::new(Vec::new());
        image.write_to(&mut output, ImageFormat::Png).unwrap();
        BASE64_STANDARD.encode(output.into_inner())
    }

    fn sample_qr_png_data_url(payload: &str) -> String {
        build_qr_png_data_url(payload).unwrap().0
    }

    fn sample_blank_png_data_url() -> String {
        let image = DynamicImage::ImageLuma8(ImageBuffer::from_pixel(64, 64, Luma([255_u8])));
        let mut output = Cursor::new(Vec::new());
        image.write_to(&mut output, ImageFormat::Png).unwrap();
        format!(
            "data:image/png;base64,{}",
            BASE64_STANDARD.encode(output.into_inner())
        )
    }

    #[test]
    fn normalizes_only_quarter_turn_rotations() {
        assert_eq!(normalize_rotation_degrees(0), 0);
        assert_eq!(normalize_rotation_degrees(90), 90);
        assert_eq!(normalize_rotation_degrees(180), 180);
        assert_eq!(normalize_rotation_degrees(270), 270);
        assert_eq!(normalize_rotation_degrees(450), 90);
        assert_eq!(normalize_rotation_degrees(45), 0);
    }

    #[test]
    fn maps_supported_mime_types_to_image_formats() {
        assert_eq!(
            image_format_for_mime_type("image/jpeg"),
            Some(ImageFormat::Jpeg)
        );
        assert_eq!(
            image_format_for_mime_type("image/png"),
            Some(ImageFormat::Png)
        );
        assert_eq!(image_format_for_mime_type("image/webp"), None);
    }

    #[test]
    fn parses_truthy_runtime_camera_env_values() {
        assert!(parse_truthy_env("1"));
        assert!(parse_truthy_env("true"));
        assert!(parse_truthy_env(" YES "));
        assert!(parse_truthy_env("on"));
        assert!(!parse_truthy_env("0"));
        assert!(!parse_truthy_env("false"));
        assert!(!parse_truthy_env(""));
    }

    #[test]
    fn missing_camera_backend_error_mentions_required_envs() {
        let error = missing_camera_backend_error();
        assert_eq!(error.kind(), CameraHostErrorKind::BackendNotConfigured);
        assert!(error.to_string().contains(CAMERA_ENDPOINT_ENV));
        assert!(error.to_string().contains(CAMERA_ALLOW_MOCK_ENV));
    }

    #[test]
    fn native_api_lists_mock_cameras_when_enabled() {
        let _guard = env_lock().lock().expect("env lock");
        clear_camera_env();
        std::env::set_var(CAMERA_ALLOW_MOCK_ENV, "1");

        let cameras = list_cameras().expect("mock cameras");
        assert_eq!(cameras.len(), 1);
        assert_eq!(cameras[0].id, "mock/rear/0");
        assert_eq!(cameras[0].label, "Mock Rear Camera");
        assert_eq!(cameras[0].lens_facing, "rear");
    }

    #[test]
    fn native_api_captures_and_decodes_mock_qr_frames() {
        let _guard = env_lock().lock().expect("env lock");
        clear_camera_env();
        std::env::set_var(CAMERA_ALLOW_MOCK_ENV, "1");
        std::env::set_var(CAMERA_MOCK_QR_PAYLOAD_ENV, "shadow://camera-proof");

        let capture = capture_still(CaptureRequest::default().with_camera_id("mock/front/1"))
            .expect("mock qr capture");
        assert_eq!(capture.camera_id, "mock/front/1");
        assert!(capture.is_mock);
        assert_eq!(capture.mime_type, "image/png");

        let decoded = decode_qr_code(
            DecodeQrCodeRequest::default().with_image_data_url(capture.image_data_url),
        )
        .expect("decode mock qr");
        assert_eq!(decoded.payload, "shadow://camera-proof");
        assert_eq!(decoded.code_count, 1);
    }

    #[test]
    fn native_api_requires_an_explicit_backend() {
        let _guard = env_lock().lock().expect("env lock");
        clear_camera_env();

        let error = list_cameras().unwrap_err();
        assert_eq!(error.kind(), CameraHostErrorKind::BackendNotConfigured);
        assert!(error.to_string().contains(CAMERA_ENDPOINT_ENV));
        assert!(error.to_string().contains(CAMERA_ALLOW_MOCK_ENV));
    }

    #[test]
    fn rotates_captured_images_and_reencodes_as_png() {
        let source = sample_png_base64(2, 1);
        let (data_url, mime_type, bytes) =
            build_capture_image_data_url(&source, "image/png", 90, 0).unwrap();

        assert_eq!(mime_type, "image/png");
        assert!(bytes > 0);
        let prefix = "data:image/png;base64,";
        assert!(data_url.starts_with(prefix));

        let decoded = BASE64_STANDARD.decode(&data_url[prefix.len()..]).unwrap();
        let rotated = image::load_from_memory_with_format(&decoded, ImageFormat::Png).unwrap();
        assert_eq!(rotated.width(), 1);
        assert_eq!(rotated.height(), 2);
    }

    #[test]
    fn decodes_fixed_qr_image_payloads() {
        let fixtures = [
            "cashuAeyJ0b2tlbiI6ImZpeHR1cmUifQ",
            "https://mint.example.test",
            "lnbcrt1u1pjfixture",
            "shadow://unsupported",
        ];

        for fixture in fixtures {
            let receipt =
                decode_qr_code_from_image_data_url(&sample_qr_png_data_url(fixture)).unwrap();
            assert_eq!(receipt.payload, fixture);
            assert_eq!(receipt.code_count, 1);
        }
    }

    #[test]
    fn rejects_missing_qr_code() {
        let error = decode_qr_code_from_image_data_url(&sample_blank_png_data_url()).unwrap_err();
        assert_eq!(error.kind(), CameraHostErrorKind::QrCodeNotFound);
        assert!(error.to_string().contains("found no QR code"));
    }

    #[test]
    fn rejects_non_image_data_urls() {
        let error = decode_image_data_url("data:text/plain;base64,SGVsbG8=").unwrap_err();
        assert_eq!(error.kind(), CameraHostErrorKind::InvalidImageData);
        assert!(error.to_string().contains("image data"));
    }

    #[test]
    fn uses_structured_broker_camera_metadata_when_present() {
        let devices = camera_devices_from_broker_list_response(BrokerListResponse {
            ok: true,
            cameras: vec![BrokerCameraDevice {
                id: String::from("device/front"),
                label: Some(String::from("Selfie Camera")),
                lens_facing: Some(String::from("front")),
                sensor_orientation_degrees: Some(270),
            }],
            camera_ids: vec![String::from("legacy/ignored")],
            error: None,
        });

        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].id, "device/front");
        assert_eq!(devices[0].label, "Selfie Camera");
        assert_eq!(devices[0].lens_facing, "front");
        assert_eq!(devices[0].sensor_orientation_degrees, Some(270));
    }

    #[test]
    fn falls_back_to_legacy_camera_ids_when_structured_metadata_is_missing() {
        let devices = camera_devices_from_broker_list_response(BrokerListResponse {
            ok: true,
            cameras: Vec::new(),
            camera_ids: vec![String::from("device/0"), String::from("device/1")],
            error: None,
        });

        assert_eq!(devices.len(), 2);
        assert_eq!(devices[0].label, "Rear Camera");
        assert_eq!(devices[0].lens_facing, "rear");
        assert_eq!(devices[0].sensor_orientation_degrees, None);
        assert_eq!(devices[1].label, "Front Camera");
        assert_eq!(devices[1].lens_facing, "front");
    }
}
