use std::env;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use deno_core::extension;
use deno_core::op2;
use deno_core::Extension;
use deno_error::JsErrorBox;
use serde::{Deserialize, Serialize};

const CAMERA_ENDPOINT_ENV: &str = "SHADOW_RUNTIME_CAMERA_ENDPOINT";
const CAMERA_TIMEOUT_MS_ENV: &str = "SHADOW_RUNTIME_CAMERA_TIMEOUT_MS";
const DEFAULT_TIMEOUT_MS: u64 = 30_000;
const MOCK_CAMERA_ID: &str = "mock/rear/0";

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct CameraDevice {
    pub id: String,
    pub label: String,
    #[serde(rename = "lensFacing")]
    pub lens_facing: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct CaptureStillRequest {
    #[serde(rename = "cameraId")]
    camera_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
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

#[derive(Debug, Serialize)]
struct BrokerRequest<'a> {
    command: &'a str,
    #[serde(rename = "cameraId", skip_serializing_if = "Option::is_none")]
    camera_id: Option<&'a str>,
}

#[derive(Debug, Deserialize)]
struct BrokerListResponse {
    ok: bool,
    #[serde(rename = "cameraIds", default)]
    camera_ids: Vec<String>,
    error: Option<String>,
}

#[derive(Debug, Deserialize)]
struct BrokerCaptureResponse {
    ok: bool,
    #[serde(rename = "bytesWritten", default)]
    bytes_written: usize,
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

        Self { endpoint, timeout }
    }

    fn list_cameras(&self) -> Result<Vec<CameraDevice>, String> {
        match self.endpoint.as_deref() {
            Some(endpoint) => self.list_cameras_via_broker(endpoint),
            None => Ok(mock_cameras()),
        }
    }

    fn capture_still(&self, request: CaptureStillRequest) -> Result<CaptureStillReceipt, String> {
        match self.endpoint.as_deref() {
            Some(endpoint) => self.capture_via_broker(endpoint, request),
            None => Ok(mock_capture(request.camera_id)),
        }
    }

    fn list_cameras_via_broker(&self, endpoint: &str) -> Result<Vec<CameraDevice>, String> {
        let response: BrokerListResponse = self.send(
            endpoint,
            BrokerRequest {
                command: "list",
                camera_id: None,
            },
        )?;
        if !response.ok {
            return Err(response
                .error
                .unwrap_or_else(|| String::from("camera broker list failed")));
        }

        if response.camera_ids.is_empty() {
            return Err(String::from("camera broker returned no camera IDs"));
        }

        Ok(response
            .camera_ids
            .into_iter()
            .map(|camera_id| CameraDevice {
                label: label_for_camera_id(&camera_id),
                lens_facing: lens_facing_for_camera_id(&camera_id),
                id: camera_id,
            })
            .collect())
    }

    fn capture_via_broker(
        &self,
        endpoint: &str,
        request: CaptureStillRequest,
    ) -> Result<CaptureStillReceipt, String> {
        let response: BrokerCaptureResponse = self.send(
            endpoint,
            BrokerRequest {
                command: "capture",
                camera_id: request.camera_id.as_deref(),
            },
        )?;
        if !response.ok {
            return Err(response
                .error
                .unwrap_or_else(|| String::from("camera broker capture failed")));
        }

        let image_base64 = response
            .image_base64
            .ok_or_else(|| String::from("camera broker capture response missing imageBase64"))?;
        let mime_type = response
            .mime_type
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| String::from("image/jpeg"));
        let camera_id = response
            .selected_camera
            .or(request.camera_id)
            .unwrap_or_else(|| String::from(MOCK_CAMERA_ID));

        Ok(CaptureStillReceipt {
            bytes: response.bytes_written,
            camera_id,
            captured_at_ms: unix_time_ms(),
            image_data_url: format!("data:{mime_type};base64,{image_base64}"),
            is_mock: false,
            mime_type,
        })
    }

    fn send<Response>(&self, endpoint: &str, request: BrokerRequest<'_>) -> Result<Response, String>
    where
        Response: for<'de> Deserialize<'de>,
    {
        let mut addrs = endpoint
            .to_socket_addrs()
            .map_err(|error| format!("resolve camera endpoint {endpoint}: {error}"))?;
        let address = addrs
            .next()
            .ok_or_else(|| format!("camera endpoint {endpoint} did not resolve"))?;
        let mut stream = TcpStream::connect_timeout(&address, self.timeout)
            .map_err(|error| format!("connect camera endpoint {endpoint}: {error}"))?;
        stream
            .set_read_timeout(Some(self.timeout))
            .map_err(|error| format!("set camera endpoint read timeout: {error}"))?;
        stream
            .set_write_timeout(Some(self.timeout))
            .map_err(|error| format!("set camera endpoint write timeout: {error}"))?;

        let encoded = serde_json::to_string(&request)
            .map_err(|error| format!("encode camera request: {error}"))?;
        writeln!(stream, "{encoded}")
            .and_then(|_| stream.flush())
            .map_err(|error| format!("write camera request: {error}"))?;

        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        let read = reader
            .read_line(&mut line)
            .map_err(|error| format!("read camera response: {error}"))?;
        if read == 0 {
            return Err(String::from(
                "camera broker closed connection without a response",
            ));
        }

        serde_json::from_str::<Response>(line.trim_end())
            .map_err(|error| format!("decode camera response: {error}"))
    }
}

#[op2]
#[serde]
async fn op_runtime_camera_list_cameras() -> Result<Vec<CameraDevice>, JsErrorBox> {
    tokio::task::spawn_blocking(|| CameraHostConfig::from_env().list_cameras())
        .await
        .map_err(|error| JsErrorBox::generic(format!("camera.listCameras join: {error}")))?
        .map_err(JsErrorBox::generic)
}

#[op2]
#[serde]
async fn op_runtime_camera_capture_still(
    #[serde] request: CaptureStillRequest,
) -> Result<CaptureStillReceipt, JsErrorBox> {
    tokio::task::spawn_blocking(move || CameraHostConfig::from_env().capture_still(request))
        .await
        .map_err(|error| JsErrorBox::generic(format!("camera.captureStill join: {error}")))?
        .map_err(JsErrorBox::generic)
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

fn lens_facing_for_camera_id(camera_id: &str) -> String {
    if camera_id.ends_with("/1") {
        return String::from("front");
    }
    String::from("rear")
}

fn mock_cameras() -> Vec<CameraDevice> {
    vec![CameraDevice {
        id: String::from(MOCK_CAMERA_ID),
        label: String::from("Mock Rear Camera"),
        lens_facing: String::from("rear"),
    }]
}

fn mock_capture(camera_id: Option<String>) -> CaptureStillReceipt {
    let timestamp = unix_time_ms();
    let card = timestamp % 10_000;
    let svg = format!(
        "<svg xmlns='http://www.w3.org/2000/svg' width='720' height='960' viewBox='0 0 720 960'>\
<defs><linearGradient id='g' x1='0' x2='1' y1='0' y2='1'><stop stop-color='#1d4ed8'/><stop offset='0.55' stop-color='#0f766e'/><stop offset='1' stop-color='#f97316'/></linearGradient></defs>\
<rect width='720' height='960' fill='url(#g)' rx='44'/>\
<circle cx='560' cy='200' r='128' fill='rgba(255,255,255,0.22)'/>\
<rect x='72' y='116' width='576' height='728' rx='36' fill='rgba(2,6,23,0.38)' stroke='rgba(255,255,255,0.22)' stroke-width='4'/>\
<text x='96' y='214' fill='#f8fafc' font-family='Google Sans, Roboto, sans-serif' font-size='34' font-weight='700'>Shadow Camera Mock</text>\
<text x='96' y='276' fill='#dbeafe' font-family='Google Sans, Roboto, sans-serif' font-size='24'>No live broker configured in this runtime.</text>\
<text x='96' y='744' fill='#f8fafc' font-family='Google Sans, Roboto, sans-serif' font-size='112' font-weight='800'>Frame {card:04}</text>\
<text x='96' y='806' fill='#e2e8f0' font-family='Google Sans, Roboto, sans-serif' font-size='28'>Captured at {timestamp}</text>\
</svg>"
    );

    CaptureStillReceipt {
        bytes: svg.len(),
        camera_id: camera_id.unwrap_or_else(|| String::from(MOCK_CAMERA_ID)),
        captured_at_ms: timestamp,
        image_data_url: format!("data:image/svg+xml;utf8,{}", encode_svg_data_url(&svg)),
        is_mock: true,
        mime_type: String::from("image/svg+xml"),
    }
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

extension!(
    runtime_camera_host_extension,
    ops = [
        op_runtime_camera_list_cameras,
        op_runtime_camera_capture_still
    ],
    esm_entry_point = "ext:runtime_camera_host_extension/bootstrap.js",
    esm = [dir "js", "bootstrap.js"],
);

pub fn init_extension() -> Extension {
    runtime_camera_host_extension::init()
}
