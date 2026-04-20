use std::fmt;

#[doc(hidden)]
pub mod ipc;
mod store;
pub mod types;

pub use ipc::NOSTR_SERVICE_SOCKET_ENV;
pub use store::{
    Kind1Event, ListKind1Query, NostrHostError, PublishKind1Request, SqliteNostrService,
    DEFAULT_PUBLISH_PUBKEY, NOSTR_ACCOUNT_NSEC_ENV, NOSTR_ACCOUNT_PATH_ENV, NOSTR_DB_PATH_ENV,
};
pub use types::{
    NostrAccountSource, NostrAccountSummary, NostrEvent, NostrEventReference, NostrQuery,
    NostrReplaceableQuery, NostrSyncReceipt, NostrSyncRequest,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NostrErrorKind {
    Other,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NostrError {
    kind: NostrErrorKind,
    message: String,
}

impl NostrError {
    pub fn kind(&self) -> NostrErrorKind {
        self.kind
    }
}

impl fmt::Display for NostrError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for NostrError {}

impl From<NostrHostError> for NostrError {
    fn from(error: NostrHostError) -> Self {
        Self {
            kind: NostrErrorKind::Other,
            message: error.to_string(),
        }
    }
}

pub fn query(query: NostrQuery) -> Result<Vec<NostrEvent>, NostrError> {
    if ipc::service_socket_path().is_some() {
        return ipc::query(query).map_err(NostrError::from);
    }
    store::query(query).map_err(NostrError::from)
}

pub fn current_account() -> Result<Option<NostrAccountSummary>, NostrError> {
    if ipc::service_socket_path().is_some() {
        return ipc::current_account().map_err(NostrError::from);
    }
    store::current_account().map_err(NostrError::from)
}

pub fn generate_account() -> Result<NostrAccountSummary, NostrError> {
    if ipc::service_socket_path().is_some() {
        return ipc::generate_account().map_err(NostrError::from);
    }
    store::generate_account().map_err(NostrError::from)
}

pub fn import_account_nsec(nsec: impl AsRef<str>) -> Result<NostrAccountSummary, NostrError> {
    if ipc::service_socket_path().is_some() {
        return ipc::import_account_nsec(nsec.as_ref()).map_err(NostrError::from);
    }
    store::import_account_nsec(nsec).map_err(NostrError::from)
}

pub fn count(query: NostrQuery) -> Result<usize, NostrError> {
    if ipc::service_socket_path().is_some() {
        return ipc::count(query).map_err(NostrError::from);
    }
    store::count(query).map_err(NostrError::from)
}

pub fn get_event(id: impl AsRef<str>) -> Result<Option<NostrEvent>, NostrError> {
    if ipc::service_socket_path().is_some() {
        return ipc::get_event(id.as_ref().to_owned()).map_err(NostrError::from);
    }
    store::get_event(id).map_err(NostrError::from)
}

pub fn get_replaceable(query: NostrReplaceableQuery) -> Result<Option<NostrEvent>, NostrError> {
    if ipc::service_socket_path().is_some() {
        return ipc::get_replaceable(query).map_err(NostrError::from);
    }
    store::get_replaceable(query).map_err(NostrError::from)
}

pub fn list_kind1(query: ListKind1Query) -> Result<Vec<Kind1Event>, NostrError> {
    if ipc::service_socket_path().is_some() {
        return ipc::list_kind1(query).map_err(NostrError::from);
    }
    store::list_kind1(query).map_err(NostrError::from)
}

pub fn publish_kind1(request: PublishKind1Request) -> Result<Kind1Event, NostrError> {
    if ipc::service_socket_path().is_some() {
        return ipc::publish_kind1(request).map_err(NostrError::from);
    }
    store::publish_kind1(request).map_err(NostrError::from)
}

pub fn sync(request: NostrSyncRequest) -> Result<NostrSyncReceipt, NostrError> {
    ipc::sync(request).map_err(NostrError::from)
}

#[cfg(test)]
mod tests {
    use super::{
        count, current_account, generate_account, get_event, import_account_nsec, query,
        NostrAccountSource, NostrEvent, NostrQuery, SqliteNostrService, NOSTR_ACCOUNT_NSEC_ENV,
        NOSTR_ACCOUNT_PATH_ENV, NOSTR_DB_PATH_ENV, NOSTR_SERVICE_SOCKET_ENV,
    };
    use nostr::prelude::{Keys, ToBech32};
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    use crate::services::nostr::store::test_env_lock;

    fn with_temp_db<T>(f: impl FnOnce() -> T) -> T {
        let _guard = test_env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time")
            .as_nanos();
        let db_path = std::env::temp_dir().join(format!("shadow-sdk-nostr-{timestamp}.sqlite"));
        let account_path = db_path.with_file_name(format!("shadow-sdk-nostr-{timestamp}.json"));
        std::env::set_var(NOSTR_DB_PATH_ENV, &db_path);
        std::env::remove_var(NOSTR_ACCOUNT_NSEC_ENV);
        std::env::set_var(NOSTR_ACCOUNT_PATH_ENV, &account_path);
        std::env::remove_var(NOSTR_SERVICE_SOCKET_ENV);
        let output = f();
        std::env::remove_var(NOSTR_DB_PATH_ENV);
        std::env::remove_var(NOSTR_ACCOUNT_PATH_ENV);
        let _ = fs::remove_file(&db_path);
        let _ = fs::remove_file(&account_path);
        output
    }

    fn seed_cached_test_events() {
        let service = SqliteNostrService::from_env().expect("open sqlite service");
        for event in [
            NostrEvent {
                content: String::from("first cached note"),
                created_at: 1_700_000_001,
                id: String::from("test-note-1"),
                kind: 1,
                pubkey: String::from("npub-test-a"),
                identifier: None,
                root_event_id: None,
                reply_to_event_id: None,
                references: Vec::new(),
            },
            NostrEvent {
                content: String::from("second cached note"),
                created_at: 1_700_000_002,
                id: String::from("test-note-2"),
                kind: 1,
                pubkey: String::from("npub-test-a"),
                identifier: None,
                root_event_id: None,
                reply_to_event_id: None,
                references: Vec::new(),
            },
            NostrEvent {
                content: String::from("third cached note"),
                created_at: 1_700_000_003,
                id: String::from("test-note-3"),
                kind: 1,
                pubkey: String::from("npub-test-b"),
                identifier: None,
                root_event_id: None,
                reply_to_event_id: None,
                references: Vec::new(),
            },
        ] {
            service.store_event(&event).expect("store cached event");
        }
    }

    #[test]
    fn query_reads_cached_events_from_sqlite_service() {
        with_temp_db(|| {
            seed_cached_test_events();
            let events = query(NostrQuery::default()).expect("query events");

            assert_eq!(events.len(), 3);
            assert_eq!(events[0].id, "test-note-3");
        });
    }

    #[test]
    fn count_and_get_event_use_the_generic_nostr_surface() {
        with_temp_db(|| {
            seed_cached_test_events();
            let count = count(NostrQuery {
                authors: Some(vec![String::from("npub-test-a")]),
                kinds: Some(vec![1]),
                referenced_ids: None,
                reply_to_ids: None,
                since: None,
                until: None,
                limit: None,
                ids: None,
            })
            .expect("count events");
            let event: NostrEvent = get_event("test-note-1")
                .expect("get event")
                .expect("cached event");

            assert_eq!(count, 2);
            assert_eq!(event.content, "first cached note");
        });
    }

    #[test]
    fn generate_account_persists_public_summary_through_sdk_surface() {
        with_temp_db(|| {
            assert_eq!(current_account().expect("read current account"), None);

            let generated = generate_account().expect("generate account");
            assert_eq!(generated.source, NostrAccountSource::Generated);
            assert!(generated.npub.starts_with("npub1"));

            let current = current_account()
                .expect("read current generated account")
                .expect("generated account");
            assert_eq!(current, generated);
        });
    }

    #[test]
    fn current_account_prefers_env_seeded_override() {
        with_temp_db(|| {
            let keys = Keys::generate();
            let nsec = keys.secret_key().to_bech32().expect("encode nsec override");
            std::env::set_var(NOSTR_ACCOUNT_NSEC_ENV, &nsec);

            let imported = import_account_nsec(&nsec).expect("import persisted account");
            let current = current_account()
                .expect("read env current account")
                .expect("env account");

            assert_eq!(imported.source, NostrAccountSource::Imported);
            assert_eq!(current.source, NostrAccountSource::Env);
            assert_eq!(
                current.npub,
                keys.public_key().to_bech32().expect("encode npub override")
            );

            std::env::remove_var(NOSTR_ACCOUNT_NSEC_ENV);
        });
    }
}
