use std::env;
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::Instant;

use shadow_runtime_protocol::{RuntimeDocumentPayload, SessionRequest, SessionResponse};

use crate::log::runtime_log;

pub use shadow_runtime_protocol::{
    AppLifecycleState, RuntimeAudioControlAction, RuntimeDispatchEvent, RuntimeKeyboardEvent,
    RuntimePointerEvent, RuntimeSelectionEvent,
};

const RUNTIME_APP_BUNDLE_PATH_ENV: &str = "SHADOW_RUNTIME_APP_BUNDLE_PATH";
const SYSTEM_BINARY_PATH_ENV: &str = "SHADOW_SYSTEM_BINARY_PATH";
const SYSTEM_STAGE_LOADER_PATH_ENV: &str = "SHADOW_SYSTEM_STAGE_LOADER_PATH";
const SYSTEM_STAGE_LIBRARY_PATH_ENV: &str = "SHADOW_SYSTEM_STAGE_LIBRARY_PATH";
const RUNTIME_DIAGNOSTIC_PREFIX: &str = "[shadow-runtime-";
const SYSTEM_CLEAN_ENV: &[&str] = &[
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
        let host_binary_path = env::var(SYSTEM_BINARY_PATH_ENV).ok();

        match (host_binary_path, bundle_path) {
            (None, None) => Ok(None),
            (Some(host_binary_path), Some(bundle_path)) => {
                Self::spawn(host_binary_path, bundle_path).map(Some)
            }
            _ => Err(format!(
                "runtime session requires both {SYSTEM_BINARY_PATH_ENV} and {RUNTIME_APP_BUNDLE_PATH_ENV}"
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

    pub fn platform_audio_control(
        &mut self,
        action: RuntimeAudioControlAction,
    ) -> Result<Option<RuntimeDocumentPayload>, String> {
        match self.send_request(&SessionRequest::PlatformAudioControl { action })? {
            SessionResponse::Ok { payload } => Ok(Some(payload)),
            SessionResponse::NoUpdate => Ok(None),
            SessionResponse::Error { message } => Err(message),
        }
    }

    pub fn platform_lifecycle_change(
        &mut self,
        state: AppLifecycleState,
    ) -> Result<Option<RuntimeDocumentPayload>, String> {
        match self.send_request(&SessionRequest::PlatformLifecycleChange { state })? {
            SessionResponse::Ok { payload } => Ok(Some(payload)),
            SessionResponse::NoUpdate => Ok(None),
            SessionResponse::Error { message } => Err(message),
        }
    }

    pub(crate) fn spawn_explicit(
        host_binary_path: String,
        bundle_path: String,
    ) -> Result<Self, String> {
        Self::spawn(host_binary_path, bundle_path)
    }

    fn spawn(host_binary_path: String, bundle_path: String) -> Result<Self, String> {
        let stage_loader_path = env::var(SYSTEM_STAGE_LOADER_PATH_ENV).ok();
        let stage_library_path = env::var(SYSTEM_STAGE_LIBRARY_PATH_ENV).ok();
        runtime_log(format!(
            "runtime-session-spawn host_binary={} bundle={} stage_loader={} stage_library={}",
            host_binary_path,
            bundle_path,
            stage_loader_path.as_deref().unwrap_or("none"),
            stage_library_path.as_deref().unwrap_or("none"),
        ));

        let mut command = match stage_loader_path {
            Some(loader_path) => {
                let mut command = Command::new(&loader_path);
                if let Some(library_path) = stage_library_path.as_deref() {
                    command.arg("--library-path").arg(library_path);
                }
                command.arg(&host_binary_path);
                command
            }
            None => Command::new(&host_binary_path),
        };
        for key in SYSTEM_CLEAN_ENV {
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

        let line = loop {
            let mut line = String::new();
            let bytes = self
                .stdout
                .read_line(&mut line)
                .map_err(|error| format!("read response: {error}"))?;
            if bytes == 0 {
                return Err(String::from("runtime host closed its stdout pipe"));
            }

            let trimmed = line.trim_end();
            if trimmed.starts_with(RUNTIME_DIAGNOSTIC_PREFIX) {
                runtime_log(trimmed);
                continue;
            }

            break line;
        };

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
        SessionRequest::PlatformAudioControl { .. } => "platform_audio_control",
        SessionRequest::PlatformLifecycleChange { .. } => "platform_lifecycle_change",
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

#[cfg(test)]
mod tests {
    use super::{SYSTEM_CLEAN_ENV, SYSTEM_STAGE_LIBRARY_PATH_ENV, SYSTEM_STAGE_LOADER_PATH_ENV};

    #[test]
    fn system_clean_env_keeps_stage_loader_settings_for_nested_services() {
        assert!(
            !SYSTEM_CLEAN_ENV.contains(&SYSTEM_STAGE_LOADER_PATH_ENV),
            "runtime host must inherit the stage loader path for nested shadow-system spawns",
        );
        assert!(
            !SYSTEM_CLEAN_ENV.contains(&SYSTEM_STAGE_LIBRARY_PATH_ENV),
            "runtime host must inherit the stage library path for nested shadow-system spawns",
        );
    }
}
