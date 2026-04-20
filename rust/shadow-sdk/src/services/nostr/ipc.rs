use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

use super::{
    Kind1Event, ListKind1Query, NostrAccountSummary, NostrEvent, NostrHostError,
    NostrPublishReceipt, NostrPublishRequest, NostrQuery, NostrReplaceableQuery, NostrSyncReceipt,
    NostrSyncRequest, NOSTR_DB_PATH_ENV,
};

pub const NOSTR_SERVICE_SOCKET_ENV: &str = "SHADOW_RUNTIME_NOSTR_SERVICE_SOCKET";
pub const NOSTR_SERVICE_SOCKET_BASENAME: &str = "runtime-nostr.sock";
const IN_MEMORY_DB_PATH: &str = ":memory:";
const SERVICE_WAIT_TIMEOUT: Duration = Duration::from_secs(2);
const SERVICE_WAIT_INTERVAL: Duration = Duration::from_millis(50);
const SYSTEM_BINARY_PATH_ENV: &str = "SHADOW_SYSTEM_BINARY_PATH";

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum NostrIpcRequest {
    CurrentAccount,
    GenerateAccount,
    ImportAccountNsec { nsec: String },
    Query { query: NostrQuery },
    Count { query: NostrQuery },
    GetEvent { id: String },
    GetReplaceable { query: NostrReplaceableQuery },
    ListKind1 { query: ListKind1Query },
    Publish { request: NostrPublishRequest },
    Sync { request: NostrSyncRequest },
}

#[derive(Debug, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum NostrIpcResponse<T> {
    Ok { payload: T },
    Error { message: String },
}

pub fn query(query: NostrQuery) -> Result<Vec<NostrEvent>, NostrHostError> {
    send_request(&NostrIpcRequest::Query { query })
}

pub fn current_account() -> Result<Option<NostrAccountSummary>, NostrHostError> {
    send_request(&NostrIpcRequest::CurrentAccount)
}

pub fn generate_account() -> Result<NostrAccountSummary, NostrHostError> {
    send_request(&NostrIpcRequest::GenerateAccount)
}

pub fn import_account_nsec(nsec: impl Into<String>) -> Result<NostrAccountSummary, NostrHostError> {
    send_request(&NostrIpcRequest::ImportAccountNsec { nsec: nsec.into() })
}

pub fn count(query: NostrQuery) -> Result<usize, NostrHostError> {
    send_request(&NostrIpcRequest::Count { query })
}

pub fn get_event(id: impl Into<String>) -> Result<Option<NostrEvent>, NostrHostError> {
    send_request(&NostrIpcRequest::GetEvent { id: id.into() })
}

pub fn get_replaceable(query: NostrReplaceableQuery) -> Result<Option<NostrEvent>, NostrHostError> {
    send_request(&NostrIpcRequest::GetReplaceable { query })
}

pub fn list_kind1(query: ListKind1Query) -> Result<Vec<Kind1Event>, NostrHostError> {
    send_request(&NostrIpcRequest::ListKind1 { query })
}

pub fn publish(request: NostrPublishRequest) -> Result<NostrPublishReceipt, NostrHostError> {
    send_request(&NostrIpcRequest::Publish { request })
}

pub fn sync(request: NostrSyncRequest) -> Result<NostrSyncReceipt, NostrHostError> {
    send_request(&NostrIpcRequest::Sync { request })
}

pub fn ensure_service_running() -> Result<(), NostrHostError> {
    let socket_path = ensure_service_socket_path()?;
    let Some(socket_path) = socket_path else {
        return Ok(());
    };
    if UnixStream::connect(&socket_path).is_ok() {
        return Ok(());
    }

    spawn_nostr_service(&socket_path)?;
    wait_for_nostr_service(&socket_path)
}

pub fn service_socket_path() -> Option<PathBuf> {
    std::env::var(NOSTR_SERVICE_SOCKET_ENV)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

pub fn default_service_socket_path() -> Option<PathBuf> {
    let db_path = std::env::var(NOSTR_DB_PATH_ENV)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())?;
    if db_path == IN_MEMORY_DB_PATH {
        return None;
    }

    let parent = Path::new(&db_path)
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())?;
    Some(parent.join(NOSTR_SERVICE_SOCKET_BASENAME))
}

pub fn remove_service_socket_file(path: &Path) -> Result<(), NostrHostError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(NostrHostError::from(format!(
            "shadow nostr service: remove stale socket {}: {error}",
            path.display()
        ))),
    }
}

fn send_request<T>(request: &NostrIpcRequest) -> Result<T, NostrHostError>
where
    T: DeserializeOwned,
{
    ensure_service_running()?;
    let socket_path = service_socket_path().ok_or_else(|| {
        NostrHostError::from(format!(
            "shadow nostr service socket is not configured; set {NOSTR_SERVICE_SOCKET_ENV}"
        ))
    })?;
    let mut stream = UnixStream::connect(&socket_path).map_err(|error| {
        NostrHostError::from(format!(
            "shadow nostr service: connect {}: {error}",
            socket_path.display()
        ))
    })?;
    let encoded = serde_json::to_string(request).map_err(|error| {
        NostrHostError::from(format!("shadow nostr service: encode request: {error}"))
    })?;
    writeln!(stream, "{encoded}")
        .and_then(|_| stream.flush())
        .map_err(|error| {
            NostrHostError::from(format!(
                "shadow nostr service: write request to {}: {error}",
                socket_path.display()
            ))
        })?;

    let mut response_line = String::new();
    let mut reader = BufReader::new(stream);
    let bytes = reader.read_line(&mut response_line).map_err(|error| {
        NostrHostError::from(format!(
            "shadow nostr service: read response from {}: {error}",
            socket_path.display()
        ))
    })?;
    if bytes == 0 {
        return Err(NostrHostError::from(format!(
            "shadow nostr service: {} closed without a response",
            socket_path.display()
        )));
    }

    match serde_json::from_str::<NostrIpcResponse<T>>(response_line.trim_end()).map_err(
        |error| NostrHostError::from(format!("shadow nostr service: decode response: {error}")),
    )? {
        NostrIpcResponse::Ok { payload } => Ok(payload),
        NostrIpcResponse::Error { message } => Err(NostrHostError::from(message)),
    }
}

fn ensure_service_socket_path() -> Result<Option<PathBuf>, NostrHostError> {
    if let Some(socket_path) = service_socket_path() {
        return Ok(Some(socket_path));
    }

    let Some(socket_path) = default_service_socket_path() else {
        return Ok(None);
    };
    std::env::set_var(NOSTR_SERVICE_SOCKET_ENV, &socket_path);
    Ok(Some(socket_path))
}

fn spawn_nostr_service(socket_path: &Path) -> Result<(), NostrHostError> {
    let system_binary = system_binary_path()?;
    let log_file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(service_log_path(socket_path))
        .map_err(|error| {
            NostrHostError::from(format!(
                "shadow nostr service: open log file for {}: {error}",
                socket_path.display()
            ))
        })?;
    let stderr = log_file.try_clone().map_err(|error| {
        NostrHostError::from(format!(
            "shadow nostr service: clone log file for {}: {error}",
            socket_path.display()
        ))
    })?;

    Command::new(system_binary)
        .arg("--nostr-service")
        .arg(socket_path)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log_file))
        .stderr(Stdio::from(stderr))
        .spawn()
        .map_err(|error| {
            NostrHostError::from(format!(
                "shadow nostr service: spawn daemon for {}: {error}",
                socket_path.display()
            ))
        })?;

    Ok(())
}

fn wait_for_nostr_service(socket_path: &Path) -> Result<(), NostrHostError> {
    let deadline = Instant::now() + SERVICE_WAIT_TIMEOUT;
    while Instant::now() < deadline {
        if UnixStream::connect(socket_path).is_ok() {
            return Ok(());
        }
        std::thread::sleep(SERVICE_WAIT_INTERVAL);
    }

    Err(NostrHostError::from(format!(
        "shadow nostr service: timed out waiting for {}",
        socket_path.display()
    )))
}

fn system_binary_path() -> Result<PathBuf, NostrHostError> {
    if let Some(path) = std::env::var_os(SYSTEM_BINARY_PATH_ENV)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
    {
        return Ok(path);
    }

    let current_exe = std::env::current_exe().map_err(|error| {
        NostrHostError::from(format!(
            "shadow nostr service: resolve current executable: {error}"
        ))
    })?;
    let is_shadow_system = current_exe
        .file_name()
        .and_then(|value| value.to_str())
        .is_some_and(|value| value == "shadow-system");
    if is_shadow_system {
        return Ok(current_exe);
    }

    Err(NostrHostError::from(format!(
        "shadow nostr service: missing {SYSTEM_BINARY_PATH_ENV}; cannot spawn shared daemon from this process"
    )))
}

fn service_log_path(socket_path: &Path) -> PathBuf {
    socket_path.with_extension("log")
}
