use std::collections::BTreeSet;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

use nostr_sdk::prelude::Client;
use serde::{Deserialize, Serialize};
use shadow_sdk::services::nostr::ipc::{remove_service_socket_file, NostrIpcRequest};
use shadow_sdk::services::nostr::{NostrHostError, NostrSyncReceipt, SqliteNostrService};

use super::{relay_publish, relay_sync};

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum NostrIpcResponse<T> {
    Ok { payload: T },
    Error { message: String },
}

#[derive(Debug)]
struct NostrDaemon {
    client: Client,
    relay_registry: BTreeSet<String>,
    service: SqliteNostrService,
}

impl NostrDaemon {
    fn from_env() -> Result<Self, String> {
        let service = SqliteNostrService::from_env().map_err(|error| error.to_string())?;
        Ok(Self {
            client: Client::default(),
            relay_registry: BTreeSet::new(),
            service,
        })
    }

    fn handle_request(
        &mut self,
        runtime: &tokio::runtime::Runtime,
        request: NostrIpcRequest,
    ) -> Result<String, String> {
        match request {
            NostrIpcRequest::CurrentAccount => {
                encode_ok(self.service.current_account().map_err(error_to_string)?)
            }
            NostrIpcRequest::GenerateAccount => {
                encode_ok(self.service.generate_account().map_err(error_to_string)?)
            }
            NostrIpcRequest::ImportAccountNsec { nsec } => encode_ok(
                self.service
                    .import_account_nsec(nsec)
                    .map_err(error_to_string)?,
            ),
            NostrIpcRequest::Query { query } => {
                encode_ok(self.service.query(query).map_err(error_to_string)?)
            }
            NostrIpcRequest::Count { query } => {
                encode_ok(self.service.count(query).map_err(error_to_string)?)
            }
            NostrIpcRequest::GetEvent { id } => {
                encode_ok(self.service.get_event(&id).map_err(error_to_string)?)
            }
            NostrIpcRequest::GetReplaceable { query } => encode_ok(
                self.service
                    .get_replaceable(query)
                    .map_err(error_to_string)?,
            ),
            NostrIpcRequest::ListKind1 { query } => {
                encode_ok(self.service.list_kind1(query).map_err(error_to_string)?)
            }
            NostrIpcRequest::Publish { request } => {
                encode_ok(runtime.block_on(relay_publish::publish_with_client(
                    &self.client,
                    &mut self.relay_registry,
                    &self.service,
                    request,
                ))?)
            }
            NostrIpcRequest::Sync { request } => {
                let fetched = runtime.block_on(relay_sync::sync_with_client(
                    &self.client,
                    &mut self.relay_registry,
                    request,
                ))?;
                let mut imported_count = 0_usize;
                for event in fetched.events.iter() {
                    if self.service.store_event(event).map_err(error_to_string)? {
                        imported_count += 1;
                    }
                }

                encode_ok(NostrSyncReceipt {
                    relay_urls: fetched.relay_urls,
                    fetched_count: fetched.events.len(),
                    imported_count,
                })
            }
        }
    }
}

pub fn run(socket_path: PathBuf) -> Result<(), String> {
    ensure_socket_parent_dir(&socket_path)?;
    let listener = bind_listener(&socket_path)?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| format!("shadow nostr service: build tokio runtime: {error}"))?;
    let mut daemon = NostrDaemon::from_env()?;

    loop {
        let (stream, _peer) = listener.accept().map_err(|error| {
            format!(
                "shadow nostr service: accept {}: {error}",
                socket_path.display()
            )
        })?;
        handle_client(&mut daemon, &runtime, stream)?;
    }
}

fn bind_listener(socket_path: &Path) -> Result<UnixListener, String> {
    match UnixListener::bind(socket_path) {
        Ok(listener) => Ok(listener),
        Err(error) if error.kind() == std::io::ErrorKind::AddrInUse => {
            if UnixStream::connect(socket_path).is_ok() {
                return Err(format!(
                    "shadow nostr service: socket {} is already in use",
                    socket_path.display()
                ));
            }
            remove_service_socket_file(socket_path).map_err(error_to_string)?;
            UnixListener::bind(socket_path).map_err(|error| {
                format!(
                    "shadow nostr service: bind {} after removing stale socket: {error}",
                    socket_path.display()
                )
            })
        }
        Err(error) => Err(format!(
            "shadow nostr service: bind {}: {error}",
            socket_path.display()
        )),
    }
}

fn handle_client(
    daemon: &mut NostrDaemon,
    runtime: &tokio::runtime::Runtime,
    mut stream: UnixStream,
) -> Result<(), String> {
    let mut reader = BufReader::new(
        stream
            .try_clone()
            .map_err(|error| format!("shadow nostr service: clone client stream: {error}"))?,
    );
    let mut request_line = String::new();
    let bytes = reader
        .read_line(&mut request_line)
        .map_err(|error| format!("shadow nostr service: read request: {error}"))?;
    if bytes == 0 {
        return Ok(());
    }

    let response = match serde_json::from_str::<NostrIpcRequest>(request_line.trim_end()) {
        Ok(request) => match daemon.handle_request(runtime, request) {
            Ok(encoded) => encoded,
            Err(message) => encode_error(&message)?,
        },
        Err(error) => encode_error(&format!("shadow nostr service: decode request: {error}"))?,
    };

    writeln!(stream, "{response}")
        .and_then(|_| stream.flush())
        .map_err(|error| format!("shadow nostr service: write response: {error}"))
}

fn ensure_socket_parent_dir(socket_path: &Path) -> Result<(), String> {
    let Some(parent) = socket_path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    else {
        return Ok(());
    };
    fs::create_dir_all(parent).map_err(|error| {
        format!(
            "shadow nostr service: create socket dir {}: {error}",
            parent.display()
        )
    })
}

fn encode_ok<T>(payload: T) -> Result<String, String>
where
    T: Serialize,
{
    serde_json::to_string(&NostrIpcResponse::Ok { payload })
        .map_err(|error| format!("shadow nostr service: encode ok response: {error}"))
}

fn encode_error(message: &str) -> Result<String, String> {
    serde_json::to_string(&NostrIpcResponse::<()>::Error {
        message: message.to_owned(),
    })
    .map_err(|error| format!("shadow nostr service: encode error response: {error}"))
}

fn error_to_string(error: NostrHostError) -> String {
    error.to_string()
}

#[cfg(test)]
mod tests {
    use super::{NostrDaemon, NostrIpcRequest, NostrIpcResponse};
    use serde::Deserialize;
    use shadow_sdk::services::nostr::{
        NostrAccountSummary, NOSTR_ACCOUNT_NSEC_ENV, NOSTR_ACCOUNT_PATH_ENV, NOSTR_DB_PATH_ENV,
    };
    use std::fs;
    use std::sync::{Mutex, OnceLock};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn with_temp_env<T>(f: impl FnOnce() -> T) -> T {
        let _guard = env_lock().lock().expect("env lock");
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time")
            .as_nanos();
        let temp_dir = std::env::temp_dir().join(format!("shadow-system-nostr-daemon-{timestamp}"));
        let db_path = temp_dir.join("runtime-nostr.sqlite3");
        let account_path = temp_dir.join("runtime-nostr-account.json");
        fs::create_dir_all(&temp_dir).expect("create temp dir");
        std::env::set_var(NOSTR_DB_PATH_ENV, &db_path);
        std::env::set_var(NOSTR_ACCOUNT_PATH_ENV, &account_path);
        std::env::remove_var(NOSTR_ACCOUNT_NSEC_ENV);

        let output = f();

        std::env::remove_var(NOSTR_DB_PATH_ENV);
        std::env::remove_var(NOSTR_ACCOUNT_PATH_ENV);
        std::env::remove_var(NOSTR_ACCOUNT_NSEC_ENV);
        let _ = fs::remove_dir_all(&temp_dir);
        output
    }

    fn decode_ok<T>(encoded: &str) -> T
    where
        T: for<'de> Deserialize<'de>,
    {
        match serde_json::from_str::<NostrIpcResponse<T>>(encoded).expect("decode response") {
            NostrIpcResponse::Ok { payload } => payload,
            NostrIpcResponse::Error { message } => panic!("unexpected daemon error: {message}"),
        }
    }

    #[test]
    fn handle_request_generates_and_reads_current_account() {
        with_temp_env(|| {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("build tokio runtime");
            let mut daemon = NostrDaemon::from_env().expect("build daemon");

            let generated: NostrAccountSummary = decode_ok(
                &daemon
                    .handle_request(&runtime, NostrIpcRequest::GenerateAccount)
                    .expect("generate via daemon"),
            );
            let current: Option<NostrAccountSummary> = decode_ok(
                &daemon
                    .handle_request(&runtime, NostrIpcRequest::CurrentAccount)
                    .expect("read via daemon"),
            );

            assert_eq!(current, Some(generated));
        });
    }
}
