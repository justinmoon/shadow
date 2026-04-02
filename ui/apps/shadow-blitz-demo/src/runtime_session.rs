use std::env;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

use serde::{Deserialize, Serialize};

use crate::runtime_document::RuntimeDocumentPayload;

const RUNTIME_APP_BUNDLE_PATH_ENV: &str = "SHADOW_RUNTIME_APP_BUNDLE_PATH";
const RUNTIME_HOST_BINARY_PATH_ENV: &str = "SHADOW_RUNTIME_HOST_BINARY_PATH";

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
        self.send_request(&SessionRequest::Render)
    }

    pub fn dispatch(
        &mut self,
        event: RuntimeDispatchEvent,
    ) -> Result<RuntimeDocumentPayload, String> {
        self.send_request(&SessionRequest::Dispatch { event })
    }

    fn spawn(host_binary_path: String, bundle_path: String) -> Result<Self, String> {
        let mut child = Command::new(&host_binary_path)
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

    fn send_request(&mut self, request: &SessionRequest) -> Result<RuntimeDocumentPayload, String> {
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

        match serde_json::from_str::<SessionResponse>(line.trim_end()) {
            Ok(SessionResponse::Ok { payload }) => Ok(payload),
            Ok(SessionResponse::Error { message }) => Err(message),
            Err(error) => Err(format!("decode response: {error}")),
        }
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
    pub pointer: Option<RuntimePointerEvent>,
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

#[derive(Debug, Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum SessionRequest {
    Render,
    Dispatch { event: RuntimeDispatchEvent },
}

#[derive(Debug, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum SessionResponse {
    Ok { payload: RuntimeDocumentPayload },
    Error { message: String },
}
