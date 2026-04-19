use std::fmt;

mod store;

pub use store::{
    Kind1Event, ListKind1Query, NostrEvent, NostrHostError, NostrQuery, NostrReplaceableQuery,
    PublishKind1Request, SqliteNostrService, DEFAULT_PUBLISH_PUBKEY, NOSTR_DB_PATH_ENV,
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
    store::query(query).map_err(NostrError::from)
}

pub fn count(query: NostrQuery) -> Result<usize, NostrError> {
    store::count(query).map_err(NostrError::from)
}

pub fn get_event(id: impl AsRef<str>) -> Result<Option<NostrEvent>, NostrError> {
    store::get_event(id).map_err(NostrError::from)
}

pub fn get_replaceable(query: NostrReplaceableQuery) -> Result<Option<NostrEvent>, NostrError> {
    store::get_replaceable(query).map_err(NostrError::from)
}

pub fn list_kind1(query: ListKind1Query) -> Result<Vec<Kind1Event>, NostrError> {
    store::list_kind1(query).map_err(NostrError::from)
}

pub fn publish_kind1(request: PublishKind1Request) -> Result<Kind1Event, NostrError> {
    store::publish_kind1(request).map_err(NostrError::from)
}

#[cfg(test)]
mod tests {
    use super::{count, get_event, query, NostrEvent, NostrQuery, NOSTR_DB_PATH_ENV};
    use std::fs;
    use std::sync::{Mutex, OnceLock};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn with_temp_db<T>(f: impl FnOnce() -> T) -> T {
        let _guard = env_lock().lock().expect("env lock");
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time")
            .as_nanos();
        let db_path = std::env::temp_dir().join(format!("shadow-sdk-nostr-{timestamp}.sqlite"));
        std::env::set_var(NOSTR_DB_PATH_ENV, &db_path);
        let output = f();
        std::env::remove_var(NOSTR_DB_PATH_ENV);
        let _ = fs::remove_file(&db_path);
        output
    }

    #[test]
    fn query_reads_seeded_events_from_sqlite_service() {
        with_temp_db(|| {
            let events = query(NostrQuery::default()).expect("query events");

            assert_eq!(events.len(), 3);
            assert_eq!(events[0].id, "shadow-note-3");
        });
    }

    #[test]
    fn count_and_get_event_use_the_generic_nostr_surface() {
        with_temp_db(|| {
            let count = count(NostrQuery {
                authors: Some(vec![String::from("npub-feed-a")]),
                kinds: Some(vec![1]),
                since: None,
                until: None,
                limit: None,
                ids: None,
            })
            .expect("count events");
            let event: NostrEvent = get_event("shadow-note-1")
                .expect("get event")
                .expect("seeded event");

            assert_eq!(count, 2);
            assert_eq!(event.content, "shadow os owns nostr for tiny apps");
        });
    }
}
