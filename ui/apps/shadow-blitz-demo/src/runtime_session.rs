use std::env;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::Instant;

use serde::{Deserialize, Serialize};

use crate::log::runtime_log;
use crate::runtime_document::RuntimeDocumentPayload;

const RUNTIME_APP_BUNDLE_PATH_ENV: &str = "SHADOW_RUNTIME_APP_BUNDLE_PATH";
const RUNTIME_HOST_BINARY_PATH_ENV: &str = "SHADOW_RUNTIME_HOST_BINARY_PATH";
const RUNTIME_HOST_CLEAN_ENV: &[&str] = &[
    "LD_LIBRARY_PATH",
    "LD_PRELOAD",
    "LIBGL_DRIVERS_PATH",
    "__EGL_VENDOR_LIBRARY_DIRS",
    "VK_ICD_FILENAMES",
    "WGPU_BACKEND",
    "MESA_LOADER_DRIVER_OVERRIDE",
    "MESA_SHADER_CACHE_DIR",
    "SHADOW_LINUX_LD_PRELOAD",
    "SHADOW_OPENLOG_DENY_DRI",
    "TU_DEBUG",
];

pub struct RuntimeSession {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl RuntimeSession {
    pub fn from_env() -> Result<Option<Self>, String> {
        let bundle_path = env::var(RUNTIME_APP_BUNDLE_PATH_ENV).ok();
        let host_binary_path = env::var(RUNTIME_HOST_BINARY_PATH_ENV).ok();

        match (host_binary_path, bundle_path) {
            (None, None) => Ok(None),
            (Some(host_binary_path), Some(bundle_path)) => {
                Self::spawn(host_binary_path, bundle_path).map(Some)
            }
            _ => Err(format!(
                "runtime session requires both {RUNTIME_HOST_BINARY_PATH_ENV} and {RUNTIME_APP_BUNDLE_PATH_ENV}"
            )),
        }
    }

    pub fn render_document(&mut self) -> Result<RuntimeDocumentPayload, String> {
        match self.send_request(&SessionRequest::Render)? {
            SessionResponse::Ok { payload } => Ok(payload),
            SessionResponse::NoUpdate => {
                Err(String::from("runtime host returned no update for render"))
            }
            SessionResponse::Error { message } => Err(message),
        }
    }

    pub fn render_if_dirty(&mut self) -> Result<Option<RuntimeDocumentPayload>, String> {
        match self.send_request(&SessionRequest::RenderIfDirty)? {
            SessionResponse::Ok { payload } => Ok(Some(payload)),
            SessionResponse::NoUpdate => Ok(None),
            SessionResponse::Error { message } => Err(message),
        }
    }

    pub fn dispatch(
        &mut self,
        event: RuntimeDispatchEvent,
    ) -> Result<RuntimeDocumentPayload, String> {
        match self.send_request(&SessionRequest::Dispatch { event })? {
            SessionResponse::Ok { payload } => Ok(payload),
            SessionResponse::NoUpdate => {
                Err(String::from("runtime host returned no update for dispatch"))
            }
            SessionResponse::Error { message } => Err(message),
        }
    }

    fn spawn(host_binary_path: String, bundle_path: String) -> Result<Self, String> {
        let mut command = Command::new(&host_binary_path);
        for key in RUNTIME_HOST_CLEAN_ENV {
            command.env_remove(key);
        }
        let mut child = command
            .arg("--session")
            .arg(&bundle_path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .map_err(|error| {
                format!(
                    "spawn runtime host {} for {}: {error}",
                    host_binary_path, bundle_path
                )
            })?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| String::from("runtime host missing stdin pipe"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| String::from("runtime host missing stdout pipe"))?;

        Ok(Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
        })
    }

    fn send_request(&mut self, request: &SessionRequest) -> Result<SessionResponse, String> {
        let started = Instant::now();
        let encoded =
            serde_json::to_string(request).map_err(|error| format!("encode request: {error}"))?;
        writeln!(self.stdin, "{encoded}")
            .and_then(|_| self.stdin.flush())
            .map_err(|error| format!("write request: {error}"))?;

        let mut line = String::new();
        let bytes = self
            .stdout
            .read_line(&mut line)
            .map_err(|error| format!("read response: {error}"))?;
        if bytes == 0 {
            return Err(String::from("runtime host closed its stdout pipe"));
        }

        runtime_log(format!(
            "runtime-session-response op={} elapsed_ms={}",
            session_request_name(request),
            started.elapsed().as_millis()
        ));

        serde_json::from_str::<SessionResponse>(line.trim_end())
            .map_err(|error| format!("decode response: {error}"))
    }
}

fn session_request_name(request: &SessionRequest) -> &'static str {
    match request {
        SessionRequest::Render => "render",
        SessionRequest::RenderIfDirty => "render_if_dirty",
        SessionRequest::Dispatch { .. } => "dispatch",
    }
}

impl Drop for RuntimeSession {
    fn drop(&mut self) {
        if let Ok(None) = self.child.try_wait() {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct RuntimeDispatchEvent {
    #[serde(rename = "targetId")]
    pub target_id: String,
    #[serde(rename = "type")]
    pub event_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub checked: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selection: Option<RuntimeSelectionEvent>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pointer: Option<RuntimePointerEvent>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keyboard: Option<RuntimeKeyboardEvent>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct RuntimeSelectionEvent {
    #[serde(rename = "start", skip_serializing_if = "Option::is_none")]
    pub start: Option<u32>,
    #[serde(rename = "end", skip_serializing_if = "Option::is_none")]
    pub end: Option<u32>,
    #[serde(rename = "direction", skip_serializing_if = "Option::is_none")]
    pub direction: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct RuntimePointerEvent {
    #[serde(rename = "clientX", skip_serializing_if = "Option::is_none")]
    pub client_x: Option<f32>,
    #[serde(rename = "clientY", skip_serializing_if = "Option::is_none")]
    pub client_y: Option<f32>,
    #[serde(rename = "isPrimary", skip_serializing_if = "Option::is_none")]
    pub is_primary: Option<bool>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct RuntimeKeyboardEvent {
    #[serde(rename = "key", skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    #[serde(rename = "code", skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(rename = "altKey", skip_serializing_if = "Option::is_none")]
    pub alt_key: Option<bool>,
    #[serde(rename = "ctrlKey", skip_serializing_if = "Option::is_none")]
    pub ctrl_key: Option<bool>,
    #[serde(rename = "metaKey", skip_serializing_if = "Option::is_none")]
    pub meta_key: Option<bool>,
    #[serde(rename = "shiftKey", skip_serializing_if = "Option::is_none")]
    pub shift_key: Option<bool>,
}

#[derive(Debug, Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum SessionRequest {
    Render,
    RenderIfDirty,
    Dispatch { event: RuntimeDispatchEvent },
}

#[derive(Debug, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum SessionResponse {
    Ok { payload: RuntimeDocumentPayload },
    NoUpdate,
    Error { message: String },
}
