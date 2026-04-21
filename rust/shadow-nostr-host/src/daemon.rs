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
            NostrIpcRequest::Publish {
                request,
                caller_app_id,
                caller_app_title,
            } => encode_ok(runtime.block_on(relay_publish::publish_with_client(
                &self.client,
                &mut self.relay_registry,
                &self.service,
                caller_app_id,
                caller_app_title,
                request,
            ))?),
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
    use crate::test_env_lock;
    use nostr::prelude::{Keys, ToBech32};
    use serde::Deserialize;
    use shadow_sdk::services::nostr::{
        NostrAccountSummary, NostrPublishReceipt, NostrPublishRequest, NostrQuery,
        NostrReplaceableQuery, NostrSyncReceipt, NostrSyncRequest, NOSTR_ACCOUNT_NSEC_ENV,
        NOSTR_ACCOUNT_PATH_ENV, NOSTR_DB_PATH_ENV,
    };
    use shadow_sdk::services::session_config::RUNTIME_SESSION_CONFIG_ENV;
    use std::fs;
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::path::PathBuf;
    use std::process::{Child, Command, Stdio};
    use std::time::{SystemTime, UNIX_EPOCH};

    const PROMPT_RESPONSE_ACTION_ID_ENV: &str = "SHADOW_SYSTEM_PROMPT_RESPONSE_ACTION_ID";

    fn with_temp_env<T>(f: impl FnOnce() -> T) -> T {
        let _guard = test_env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
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
        std::env::remove_var(RUNTIME_SESSION_CONFIG_ENV);

        let output = std::panic::catch_unwind(std::panic::AssertUnwindSafe(f));

        std::env::remove_var(NOSTR_DB_PATH_ENV);
        std::env::remove_var(NOSTR_ACCOUNT_PATH_ENV);
        std::env::remove_var(NOSTR_ACCOUNT_NSEC_ENV);
        std::env::remove_var(RUNTIME_SESSION_CONFIG_ENV);
        let _ = fs::remove_dir_all(&temp_dir);
        match output {
            Ok(output) => output,
            Err(panic) => std::panic::resume_unwind(panic),
        }
    }

    fn with_temp_session_config<T>(f: impl FnOnce(PathBuf, PathBuf) -> T) -> T {
        let _guard = test_env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time")
            .as_nanos();
        let temp_dir = std::env::temp_dir().join(format!("shadow-system-nostr-config-{timestamp}"));
        let db_path = temp_dir.join("runtime-nostr.sqlite3");
        let account_path = temp_dir.join("runtime-nostr-account.json");
        let config_path = temp_dir.join("session-config.json");
        fs::create_dir_all(&temp_dir).expect("create temp dir");
        fs::write(
            &config_path,
            format!(
                r#"{{
                    "services": {{
                        "nostrDbPath": "{}"
                    }}
                }}"#,
                db_path.display()
            ),
        )
        .expect("write session config");
        std::env::set_var(RUNTIME_SESSION_CONFIG_ENV, &config_path);
        std::env::remove_var(NOSTR_DB_PATH_ENV);
        std::env::remove_var(NOSTR_ACCOUNT_PATH_ENV);
        std::env::remove_var(NOSTR_ACCOUNT_NSEC_ENV);

        let output = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            f(db_path.clone(), account_path.clone())
        }));

        std::env::remove_var(RUNTIME_SESSION_CONFIG_ENV);
        std::env::remove_var(NOSTR_DB_PATH_ENV);
        std::env::remove_var(NOSTR_ACCOUNT_PATH_ENV);
        std::env::remove_var(NOSTR_ACCOUNT_NSEC_ENV);
        let _ = fs::remove_dir_all(&temp_dir);
        match output {
            Ok(output) => output,
            Err(panic) => std::panic::resume_unwind(panic),
        }
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

    fn reserve_port() -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind test port");
        listener.local_addr().expect("test port addr").port()
    }

    fn wait_for_relay(child: &mut Child, name: &str) {
        let stderr = child.stderr.take().expect("relay stderr");
        let mut reader = BufReader::new(stderr);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let mut line = String::new();
        let mut stderr_output = String::new();
        while std::time::Instant::now() < deadline {
            line.clear();
            let bytes = reader.read_line(&mut line).expect("read relay stderr line");
            if bytes == 0 {
                if child.try_wait().expect("poll relay").is_some() {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
                continue;
            }
            stderr_output.push_str(&line);
            if line.contains("relay running at") {
                child.stderr = Some(reader.into_inner());
                return;
            }
        }
        if let Some(mut stderr) = child.stderr.take() {
            let _ = std::io::Read::read_to_string(&mut stderr, &mut stderr_output);
        }
        panic!("timed out waiting for {name}\n{stderr_output}");
    }

    fn spawn_relay(port: u16) -> Child {
        let mut relay = Command::new("nak")
            .args([
                "serve",
                "--hostname",
                "127.0.0.1",
                "--port",
                &port.to_string(),
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn relay");
        wait_for_relay(&mut relay, "test relay");
        relay
    }

    fn restart_relay(mut relay: Child, port: u16) -> Child {
        relay.kill().expect("kill relay");
        let _ = relay.wait();
        spawn_relay(port)
    }

    fn generate_secret_key() -> String {
        let output = Command::new("nak")
            .args(["key", "generate"])
            .output()
            .expect("generate secret key");
        assert!(
            output.status.success(),
            "nak key generate failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("nak key output utf8")
            .trim()
            .to_owned()
    }

    fn publish_text_note(relay_url: &str, content: &str) {
        let secret = generate_secret_key();
        let mut child = Command::new("nak")
            .args(["publish", "--sec", &secret, relay_url])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn nak publish");
        child
            .stdin
            .as_mut()
            .expect("nak publish stdin")
            .write_all(content.as_bytes())
            .expect("write publish content");
        let output = child.wait_with_output().expect("wait for publish");
        assert!(
            output.status.success(),
            "nak publish failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn query_relay(relay_url: &str) -> String {
        let output = Command::new("nak")
            .args(["req", "-k", "1", "-l", "50", relay_url])
            .output()
            .expect("query relay");
        assert!(
            output.status.success(),
            "nak req failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).expect("relay stdout utf8")
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

    #[test]
    fn daemon_uses_session_config_nostr_db_path() {
        with_temp_session_config(|db_path, account_path| {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("build tokio runtime");
            let mut daemon = NostrDaemon::from_env().expect("build daemon");

            let _generated: NostrAccountSummary = decode_ok(
                &daemon
                    .handle_request(&runtime, NostrIpcRequest::GenerateAccount)
                    .expect("generate via daemon"),
            );

            assert!(db_path.exists());
            assert!(account_path.exists());
        });
    }

    #[test]
    fn handle_request_publish_writes_to_requested_relay() {
        with_temp_env(|| {
            std::env::set_var(PROMPT_RESPONSE_ACTION_ID_ENV, "allow_once");
            let port = reserve_port();
            let relay_url = format!("ws://127.0.0.1:{port}");
            let mut relay = spawn_relay(port);

            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("build tokio runtime");
            let mut daemon = NostrDaemon::from_env().expect("build daemon");
            let _: NostrAccountSummary = decode_ok(
                &daemon
                    .handle_request(&runtime, NostrIpcRequest::GenerateAccount)
                    .expect("generate via daemon"),
            );

            let receipt: NostrPublishReceipt = decode_ok(
                &daemon
                    .handle_request(
                        &runtime,
                        NostrIpcRequest::Publish {
                            request: NostrPublishRequest::TextNote {
                                content: String::from("daemon test publish"),
                                root_event_id: None,
                                reply_to_event_id: None,
                                relay_urls: Some(vec![relay_url.clone()]),
                                timeout_ms: Some(12_000),
                            },
                            caller_app_id: Some(String::from("daemon-test")),
                            caller_app_title: Some(String::from("Daemon Test")),
                        },
                    )
                    .expect("publish via daemon"),
            );

            assert_eq!(
                receipt.published_relays.len(),
                1,
                "expected publish receipt to stay scoped to one relay: {:?}",
                receipt.published_relays
            );
            assert!(
                receipt.published_relays.iter().any(|published| {
                    published == &relay_url || published == &(relay_url.clone() + "/")
                }),
                "expected relay {relay_url} in publish receipt {:?}",
                receipt.published_relays
            );

            let relay_dump = query_relay(&relay_url);
            assert!(
                relay_dump.contains("daemon test publish"),
                "expected relay dump to include published note, got {relay_dump}"
            );

            std::env::remove_var(PROMPT_RESPONSE_ACTION_ID_ENV);
            relay.kill().expect("kill relay");
            let _ = relay.wait();
        });
    }

    #[test]
    fn handle_request_publish_writes_contact_list_to_store_and_relay() {
        with_temp_env(|| {
            std::env::set_var(PROMPT_RESPONSE_ACTION_ID_ENV, "allow_once");
            let port = reserve_port();
            let relay_url = format!("ws://127.0.0.1:{port}");
            let mut relay = spawn_relay(port);

            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("build tokio runtime");
            let mut daemon = NostrDaemon::from_env().expect("build daemon");
            let account: NostrAccountSummary = decode_ok(
                &daemon
                    .handle_request(&runtime, NostrIpcRequest::GenerateAccount)
                    .expect("generate via daemon"),
            );
            let followed_npub = Keys::generate()
                .public_key()
                .to_bech32()
                .expect("encode followed npub");

            let receipt: NostrPublishReceipt = decode_ok(
                &daemon
                    .handle_request(
                        &runtime,
                        NostrIpcRequest::Publish {
                            request: NostrPublishRequest::ContactList {
                                public_keys: vec![
                                    shadow_sdk::services::nostr::NostrPublicKeyReference {
                                        public_key: followed_npub.clone(),
                                        relay_url: None,
                                        alias: None,
                                    },
                                ],
                                relay_urls: Some(vec![relay_url.clone()]),
                                timeout_ms: Some(12_000),
                            },
                            caller_app_id: Some(String::from("daemon-test")),
                            caller_app_title: Some(String::from("Daemon Test")),
                        },
                    )
                    .expect("publish contact list via daemon"),
            );

            assert_eq!(receipt.event.kind, 3);
            assert_eq!(receipt.event.public_keys.len(), 1);
            assert_eq!(receipt.event.public_keys[0].public_key, followed_npub);

            let stored = decode_ok::<Option<shadow_sdk::services::nostr::NostrEvent>>(
                &daemon
                    .handle_request(
                        &runtime,
                        NostrIpcRequest::GetReplaceable {
                            query: NostrReplaceableQuery {
                                kind: 3,
                                pubkey: account.npub,
                                identifier: None,
                            },
                        },
                    )
                    .expect("load stored contact list"),
            )
            .expect("stored contact list");
            assert_eq!(stored.id, receipt.event.id);
            assert_eq!(stored.public_keys.len(), 1);

            let relay_dump = String::from_utf8(
                Command::new("nak")
                    .args(["req", "-k", "3", "-l", "10", &relay_url])
                    .output()
                    .expect("query contact list relay")
                    .stdout,
            )
            .expect("relay stdout utf8");
            assert!(
                relay_dump.contains("\"kind\":3"),
                "expected relay dump to include contact list event, got {relay_dump}"
            );

            std::env::remove_var(PROMPT_RESPONSE_ACTION_ID_ENV);
            relay.kill().expect("kill relay");
            let _ = relay.wait();
        });
    }

    #[test]
    fn handle_request_publish_does_not_leak_to_other_registered_relays() {
        with_temp_env(|| {
            std::env::set_var(PROMPT_RESPONSE_ACTION_ID_ENV, "allow_once");
            let port_a = reserve_port();
            let port_b = reserve_port();
            let relay_a = format!("ws://127.0.0.1:{port_a}");
            let relay_b = format!("ws://127.0.0.1:{port_b}");
            let mut relay_a_child = spawn_relay(port_a);
            let mut relay_b_child = spawn_relay(port_b);

            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("build tokio runtime");
            let mut daemon = NostrDaemon::from_env().expect("build daemon");
            let _: NostrAccountSummary = decode_ok(
                &daemon
                    .handle_request(&runtime, NostrIpcRequest::GenerateAccount)
                    .expect("generate via daemon"),
            );

            let _: NostrSyncReceipt = decode_ok(
                &daemon
                    .handle_request(
                        &runtime,
                        NostrIpcRequest::Sync {
                            request: NostrSyncRequest {
                                query: NostrQuery {
                                    ids: None,
                                    authors: None,
                                    kinds: Some(vec![1]),
                                    referenced_ids: None,
                                    reply_to_ids: None,
                                    since: None,
                                    until: None,
                                    limit: Some(4),
                                },
                                relay_urls: Some(vec![relay_b.clone()]),
                                timeout_ms: Some(4_000),
                            },
                        },
                    )
                    .expect("sync relay b"),
            );

            let receipt: NostrPublishReceipt = decode_ok(
                &daemon
                    .handle_request(
                        &runtime,
                        NostrIpcRequest::Publish {
                            request: NostrPublishRequest::TextNote {
                                content: String::from("scoped publish only to relay a"),
                                root_event_id: None,
                                reply_to_event_id: None,
                                relay_urls: Some(vec![relay_a.clone()]),
                                timeout_ms: Some(12_000),
                            },
                            caller_app_id: Some(String::from("daemon-test")),
                            caller_app_title: Some(String::from("Daemon Test")),
                        },
                    )
                    .expect("publish via daemon"),
            );

            assert_eq!(
                receipt.published_relays.len(),
                1,
                "expected one published relay: {:?}",
                receipt.published_relays
            );
            assert!(
                receipt.published_relays.iter().any(|published| {
                    published == &relay_a || published == &(relay_a.clone() + "/")
                }),
                "expected relay a in publish receipt {:?}",
                receipt.published_relays
            );

            let relay_a_dump = query_relay(&relay_a);
            assert!(
                relay_a_dump.contains("scoped publish only to relay a"),
                "expected relay a dump to include the note, got {relay_a_dump}"
            );
            let relay_b_dump = query_relay(&relay_b);
            assert!(
                !relay_b_dump.contains("scoped publish only to relay a"),
                "expected relay b to stay untouched, got {relay_b_dump}"
            );

            std::env::remove_var(PROMPT_RESPONSE_ACTION_ID_ENV);
            relay_a_child.kill().expect("kill relay a");
            relay_b_child.kill().expect("kill relay b");
            let _ = relay_a_child.wait();
            let _ = relay_b_child.wait();
        });
    }

    #[test]
    fn handle_request_sync_fetches_from_requested_relay_only() {
        with_temp_env(|| {
            let port_a = reserve_port();
            let port_b = reserve_port();
            let relay_a = format!("ws://127.0.0.1:{port_a}");
            let relay_b = format!("ws://127.0.0.1:{port_b}");
            let mut relay_a_child = spawn_relay(port_a);
            let mut relay_b_child = spawn_relay(port_b);
            publish_text_note(&relay_a, "sync scoped relay a");
            publish_text_note(&relay_b, "sync scoped relay b");

            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("build tokio runtime");
            let mut daemon = NostrDaemon::from_env().expect("build daemon");

            let relay_b_receipt: NostrSyncReceipt = decode_ok(
                &daemon
                    .handle_request(
                        &runtime,
                        NostrIpcRequest::Sync {
                            request: NostrSyncRequest {
                                query: NostrQuery {
                                    ids: None,
                                    authors: None,
                                    kinds: Some(vec![1]),
                                    referenced_ids: None,
                                    reply_to_ids: None,
                                    since: None,
                                    until: None,
                                    limit: Some(8),
                                },
                                relay_urls: Some(vec![relay_b.clone()]),
                                timeout_ms: Some(8_000),
                            },
                        },
                    )
                    .expect("sync relay b"),
            );
            assert_eq!(relay_b_receipt.fetched_count, 1);
            assert_eq!(relay_b_receipt.imported_count, 1);

            let relay_a_receipt: NostrSyncReceipt = decode_ok(
                &daemon
                    .handle_request(
                        &runtime,
                        NostrIpcRequest::Sync {
                            request: NostrSyncRequest {
                                query: NostrQuery {
                                    ids: None,
                                    authors: None,
                                    kinds: Some(vec![1]),
                                    referenced_ids: None,
                                    reply_to_ids: None,
                                    since: None,
                                    until: None,
                                    limit: Some(8),
                                },
                                relay_urls: Some(vec![relay_a.clone()]),
                                timeout_ms: Some(8_000),
                            },
                        },
                    )
                    .expect("sync relay a"),
            );
            assert_eq!(
                relay_a_receipt.fetched_count, 1,
                "expected relay a fetch to stay scoped to one relay"
            );
            assert_eq!(relay_a_receipt.imported_count, 1);

            relay_a_child.kill().expect("kill relay a");
            relay_b_child.kill().expect("kill relay b");
            let _ = relay_a_child.wait();
            let _ = relay_b_child.wait();
        });
    }

    #[test]
    fn handle_request_publish_reconnects_after_relay_restart() {
        with_temp_env(|| {
            std::env::set_var(PROMPT_RESPONSE_ACTION_ID_ENV, "allow_once");
            let port = reserve_port();
            let relay_url = format!("ws://127.0.0.1:{port}");
            let mut relay = spawn_relay(port);
            publish_text_note(&relay_url, "seed before restart");

            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("build tokio runtime");
            let mut daemon = NostrDaemon::from_env().expect("build daemon");
            let _: NostrAccountSummary = decode_ok(
                &daemon
                    .handle_request(&runtime, NostrIpcRequest::GenerateAccount)
                    .expect("generate via daemon"),
            );

            let _: NostrSyncReceipt = decode_ok(
                &daemon
                    .handle_request(
                        &runtime,
                        NostrIpcRequest::Sync {
                            request: NostrSyncRequest {
                                query: NostrQuery {
                                    ids: None,
                                    authors: None,
                                    kinds: Some(vec![1]),
                                    referenced_ids: None,
                                    reply_to_ids: None,
                                    since: None,
                                    until: None,
                                    limit: Some(8),
                                },
                                relay_urls: Some(vec![relay_url.clone()]),
                                timeout_ms: Some(8_000),
                            },
                        },
                    )
                    .expect("initial sync"),
            );

            relay = restart_relay(relay, port);

            let receipt: NostrPublishReceipt = decode_ok(
                &daemon
                    .handle_request(
                        &runtime,
                        NostrIpcRequest::Publish {
                            request: NostrPublishRequest::TextNote {
                                content: String::from("publish after relay restart"),
                                root_event_id: None,
                                reply_to_event_id: None,
                                relay_urls: Some(vec![relay_url.clone()]),
                                timeout_ms: Some(12_000),
                            },
                            caller_app_id: Some(String::from("daemon-test")),
                            caller_app_title: Some(String::from("Daemon Test")),
                        },
                    )
                    .expect("publish after relay restart"),
            );

            assert_eq!(receipt.published_relays.len(), 1);
            let relay_dump = query_relay(&relay_url);
            assert!(
                relay_dump.contains("publish after relay restart"),
                "expected relay dump to include restarted publish, got {relay_dump}"
            );

            std::env::remove_var(PROMPT_RESPONSE_ACTION_ID_ENV);
            relay.kill().expect("kill relay");
            let _ = relay.wait();
        });
    }
}
