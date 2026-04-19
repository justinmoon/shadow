use std::collections::BTreeSet;
use std::fmt;
use std::fs;
use std::path::Path;

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

pub const DEFAULT_PUBLISH_PUBKEY: &str = "npub-shadow-os";
pub const NOSTR_DB_PATH_ENV: &str = "SHADOW_RUNTIME_NOSTR_DB_PATH";

const IN_MEMORY_DB_PATH: &str = ":memory:";
const INITIAL_CREATED_AT_BASE: u64 = 1_700_000_000;
const LEGACY_KIND1_TABLE: &str = "nostr_kind1_events";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NostrHostError {
    message: String,
}

impl NostrHostError {
    pub fn message(&self) -> &str {
        &self.message
    }

    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for NostrHostError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for NostrHostError {}

impl From<String> for NostrHostError {
    fn from(message: String) -> Self {
        Self::new(message)
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct NostrEvent {
    pub content: String,
    pub created_at: u64,
    pub id: String,
    pub kind: u32,
    pub pubkey: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub identifier: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Kind1Event {
    pub content: String,
    pub created_at: u64,
    pub id: String,
    pub kind: u32,
    pub pubkey: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct NostrQuery {
    pub ids: Option<Vec<String>>,
    pub authors: Option<Vec<String>>,
    pub kinds: Option<Vec<u32>>,
    pub since: Option<u64>,
    pub until: Option<u64>,
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct NostrReplaceableQuery {
    pub kind: u32,
    pub pubkey: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub identifier: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct ListKind1Query {
    pub authors: Option<Vec<String>>,
    pub since: Option<u64>,
    pub until: Option<u64>,
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct PublishKind1Request {
    pub content: Option<String>,
    pub pubkey: Option<String>,
}

#[derive(Debug)]
pub struct SqliteNostrService {
    connection: Connection,
}

impl SqliteNostrService {
    pub fn from_env() -> Result<Self, NostrHostError> {
        let db_path = std::env::var(NOSTR_DB_PATH_ENV)
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| String::from(IN_MEMORY_DB_PATH));
        Self::open(&db_path)
    }

    fn open(db_path: &str) -> Result<Self, NostrHostError> {
        if db_path != IN_MEMORY_DB_PATH {
            ensure_db_parent_dir(db_path)?;
        }

        let connection = Connection::open(db_path).map_err(|error| {
            NostrHostError::new(format!(
                "shadow nostr service: open sqlite db {db_path}: {error}"
            ))
        })?;
        let service = Self { connection };
        service.initialize()?;
        Ok(service)
    }

    fn initialize(&self) -> Result<(), NostrHostError> {
        self.connection
            .execute_batch(
                "
                CREATE TABLE IF NOT EXISTS nostr_events (
                    sequence INTEGER PRIMARY KEY,
                    id TEXT NOT NULL UNIQUE,
                    kind INTEGER NOT NULL,
                    pubkey TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    content TEXT NOT NULL,
                    identifier TEXT
                );
                CREATE INDEX IF NOT EXISTS nostr_events_created_at_idx
                    ON nostr_events (created_at DESC, sequence DESC);
                CREATE INDEX IF NOT EXISTS nostr_events_replaceable_idx
                    ON nostr_events (kind, pubkey, identifier, created_at DESC, sequence DESC);
                ",
            )
            .map_err(|error| {
                NostrHostError::new(format!(
                    "shadow nostr service: initialize sqlite schema: {error}"
                ))
            })?;

        self.import_legacy_kind1_events()?;

        let row_count: u64 = self
            .connection
            .query_row("SELECT COUNT(*) FROM nostr_events", [], |row| row.get(0))
            .map_err(|error| {
                NostrHostError::new(format!("shadow nostr service: count sqlite rows: {error}"))
            })?;
        if row_count == 0 {
            self.seed_initial_events()?;
        }

        Ok(())
    }

    fn import_legacy_kind1_events(&self) -> Result<(), NostrHostError> {
        let legacy_exists: bool = self
            .connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1)",
                [LEGACY_KIND1_TABLE],
                |row| row.get(0),
            )
            .map_err(|error| {
                NostrHostError::new(format!(
                    "shadow nostr service: inspect legacy sqlite schema: {error}"
                ))
            })?;
        if !legacy_exists {
            return Ok(());
        }

        self.connection
            .execute(
                "
                INSERT OR IGNORE INTO nostr_events (
                    id,
                    kind,
                    pubkey,
                    created_at,
                    content,
                    identifier
                )
                SELECT id, kind, pubkey, created_at, content, NULL
                FROM nostr_kind1_events
                ",
                [],
            )
            .map_err(|error| {
                NostrHostError::new(format!(
                    "shadow nostr service: import legacy kind1 rows: {error}"
                ))
            })?;

        Ok(())
    }

    fn seed_initial_events(&self) -> Result<(), NostrHostError> {
        for (id, created_at, pubkey, content) in [
            (
                "shadow-note-1",
                1_700_000_001_u64,
                "npub-feed-a",
                "shadow os owns nostr for tiny apps",
            ),
            (
                "shadow-note-2",
                1_700_000_002_u64,
                "npub-feed-a",
                "relay subscriptions will live below app code",
            ),
            (
                "shadow-note-3",
                1_700_000_003_u64,
                "npub-feed-b",
                "local cache warmed from the system service",
            ),
        ] {
            self.connection
                .execute(
                    "
                    INSERT INTO nostr_events (
                        id,
                        kind,
                        pubkey,
                        created_at,
                        content,
                        identifier
                    ) VALUES (?1, 1, ?2, ?3, ?4, NULL)
                    ",
                    params![id, pubkey, created_at, content],
                )
                .map_err(|error| {
                    NostrHostError::new(format!(
                        "shadow nostr service: seed sqlite note {id}: {error}"
                    ))
                })?;
        }

        Ok(())
    }

    pub fn query(&self, query: NostrQuery) -> Result<Vec<NostrEvent>, NostrHostError> {
        let NostrQuery {
            ids,
            authors,
            kinds,
            since,
            until,
            limit,
        } = query;
        let ids = ids.map(|ids| ids.into_iter().collect::<BTreeSet<_>>());
        let authors = authors.map(|authors| authors.into_iter().collect::<BTreeSet<_>>());
        let kinds = kinds.map(|kinds| kinds.into_iter().collect::<BTreeSet<_>>());
        let limit = limit.unwrap_or(usize::MAX);

        let mut statement = self
            .connection
            .prepare(
                "
                SELECT id, kind, pubkey, created_at, content, identifier
                FROM nostr_events
                ORDER BY created_at DESC, sequence DESC
                ",
            )
            .map_err(|error| {
                NostrHostError::new(format!("nostr.query prepare sqlite query: {error}"))
            })?;
        let rows = statement.query_map([], map_nostr_event).map_err(|error| {
            NostrHostError::new(format!("nostr.query run sqlite query: {error}"))
        })?;

        let mut events = Vec::new();
        for row in rows {
            let event = row.map_err(|error| {
                NostrHostError::new(format!("nostr.query decode sqlite row: {error}"))
            })?;
            if ids
                .as_ref()
                .is_some_and(|ids| !ids.contains(event.id.as_str()))
            {
                continue;
            }
            if authors
                .as_ref()
                .is_some_and(|authors| !authors.contains(event.pubkey.as_str()))
            {
                continue;
            }
            if kinds
                .as_ref()
                .is_some_and(|kinds| !kinds.contains(&event.kind))
            {
                continue;
            }
            if since.is_some_and(|since| event.created_at < since) {
                continue;
            }
            if until.is_some_and(|until| event.created_at > until) {
                continue;
            }

            events.push(event);
            if events.len() >= limit {
                break;
            }
        }

        Ok(events)
    }

    pub fn count(&self, query: NostrQuery) -> Result<usize, NostrHostError> {
        Ok(self.query(query)?.len())
    }

    pub fn get_event(&self, id: &str) -> Result<Option<NostrEvent>, NostrHostError> {
        let id = id.trim();
        if id.is_empty() {
            return Err(NostrHostError::new(
                "nostr.getEvent requires a non-empty event id",
            ));
        }

        self.connection
            .query_row(
                "
                SELECT id, kind, pubkey, created_at, content, identifier
                FROM nostr_events
                WHERE id = ?1
                ",
                [id],
                map_nostr_event,
            )
            .optional()
            .map_err(|error| {
                NostrHostError::new(format!("nostr.getEvent query sqlite row: {error}"))
            })
    }

    pub fn get_replaceable(
        &self,
        query: NostrReplaceableQuery,
    ) -> Result<Option<NostrEvent>, NostrHostError> {
        if !kind_is_replaceable(query.kind) {
            return Err(NostrHostError::new(format!(
                "nostr.getReplaceable requires a replaceable or addressable kind, got {}",
                query.kind
            )));
        }
        let pubkey = query.pubkey.trim();
        if pubkey.is_empty() {
            return Err(NostrHostError::new(
                "nostr.getReplaceable requires a non-empty pubkey",
            ));
        }

        let identifier = normalize_optional_string(query.identifier);
        let sql = if identifier.is_some() {
            "
            SELECT id, kind, pubkey, created_at, content, identifier
            FROM nostr_events
            WHERE kind = ?1 AND pubkey = ?2 AND identifier = ?3
            ORDER BY created_at DESC, sequence DESC
            LIMIT 1
            "
        } else {
            "
            SELECT id, kind, pubkey, created_at, content, identifier
            FROM nostr_events
            WHERE kind = ?1 AND pubkey = ?2 AND identifier IS NULL
            ORDER BY created_at DESC, sequence DESC
            LIMIT 1
            "
        };
        let mut statement = self.connection.prepare(sql).map_err(|error| {
            NostrHostError::new(format!(
                "nostr.getReplaceable prepare sqlite query: {error}"
            ))
        })?;

        if let Some(identifier) = identifier {
            statement
                .query_row(params![query.kind, pubkey, identifier], map_nostr_event)
                .optional()
                .map_err(|error| {
                    NostrHostError::new(format!("nostr.getReplaceable query sqlite row: {error}"))
                })
        } else {
            statement
                .query_row(params![query.kind, pubkey], map_nostr_event)
                .optional()
                .map_err(|error| {
                    NostrHostError::new(format!("nostr.getReplaceable query sqlite row: {error}"))
                })
        }
    }

    pub fn list_kind1(&self, query: ListKind1Query) -> Result<Vec<Kind1Event>, NostrHostError> {
        self.query(NostrQuery {
            ids: None,
            authors: query.authors,
            kinds: Some(vec![1]),
            since: query.since,
            until: query.until,
            limit: query.limit,
        })
        .map(|events| events.into_iter().map(Kind1Event::from).collect())
    }

    pub fn publish_kind1(
        &self,
        request: PublishKind1Request,
    ) -> Result<Kind1Event, NostrHostError> {
        let content = request
            .content
            .as_deref()
            .map(str::trim)
            .filter(|content| !content.is_empty())
            .ok_or_else(|| NostrHostError::new("nostr.publishKind1 requires non-empty content"))?
            .to_owned();
        let next_sequence: u64 = self
            .connection
            .query_row(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM nostr_events",
                [],
                |row| row.get(0),
            )
            .map_err(|error| {
                NostrHostError::new(format!(
                    "nostr.publishKind1 load next sqlite sequence: {error}"
                ))
            })?;
        let next_created_at: u64 = self
            .connection
            .query_row(
                "SELECT COALESCE(MAX(created_at), ?1) + 1 FROM nostr_events",
                params![INITIAL_CREATED_AT_BASE],
                |row| row.get(0),
            )
            .map_err(|error| {
                NostrHostError::new(format!(
                    "nostr.publishKind1 load next sqlite timestamp: {error}"
                ))
            })?;
        let pubkey = request
            .pubkey
            .as_deref()
            .map(str::trim)
            .filter(|pubkey| !pubkey.is_empty())
            .unwrap_or(DEFAULT_PUBLISH_PUBKEY)
            .to_owned();
        let event = NostrEvent {
            content,
            created_at: next_created_at,
            id: format!("shadow-note-{next_sequence}"),
            kind: 1,
            pubkey,
            identifier: None,
        };
        self.store_event(&event).map_err(|error| {
            NostrHostError::new(format!(
                "nostr.publishKind1 insert sqlite note {}: {error}",
                event.id
            ))
        })?;

        Ok(Kind1Event::from(event))
    }

    pub fn store_event(&self, event: &NostrEvent) -> Result<bool, NostrHostError> {
        let inserted = self
            .connection
            .execute(
                "
                INSERT OR IGNORE INTO nostr_events (
                    id,
                    kind,
                    pubkey,
                    created_at,
                    content,
                    identifier
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                ",
                params![
                    event.id,
                    event.kind,
                    event.pubkey,
                    event.created_at,
                    event.content,
                    event.identifier
                ],
            )
            .map_err(|error| {
                NostrHostError::new(format!(
                    "shadow nostr service: insert sqlite note {}: {error}",
                    event.id
                ))
            })?;

        Ok(inserted > 0)
    }

    pub fn store_kind1_event(&self, event: &Kind1Event) -> Result<bool, NostrHostError> {
        self.store_event(&NostrEvent::from(event.clone()))
    }
}

impl From<NostrEvent> for Kind1Event {
    fn from(value: NostrEvent) -> Self {
        Self {
            content: value.content,
            created_at: value.created_at,
            id: value.id,
            kind: value.kind,
            pubkey: value.pubkey,
        }
    }
}

impl From<Kind1Event> for NostrEvent {
    fn from(value: Kind1Event) -> Self {
        Self {
            content: value.content,
            created_at: value.created_at,
            id: value.id,
            kind: value.kind,
            pubkey: value.pubkey,
            identifier: None,
        }
    }
}

pub fn query(query: NostrQuery) -> Result<Vec<NostrEvent>, NostrHostError> {
    SqliteNostrService::from_env()?.query(query)
}

pub fn count(query: NostrQuery) -> Result<usize, NostrHostError> {
    SqliteNostrService::from_env()?.count(query)
}

pub fn get_event(id: impl AsRef<str>) -> Result<Option<NostrEvent>, NostrHostError> {
    SqliteNostrService::from_env()?.get_event(id.as_ref())
}

pub fn get_replaceable(query: NostrReplaceableQuery) -> Result<Option<NostrEvent>, NostrHostError> {
    SqliteNostrService::from_env()?.get_replaceable(query)
}

pub fn list_kind1(query: ListKind1Query) -> Result<Vec<Kind1Event>, NostrHostError> {
    SqliteNostrService::from_env()?.list_kind1(query)
}

pub fn publish_kind1(request: PublishKind1Request) -> Result<Kind1Event, NostrHostError> {
    SqliteNostrService::from_env()?.publish_kind1(request)
}

fn ensure_db_parent_dir(db_path: &str) -> Result<(), NostrHostError> {
    let path = Path::new(db_path);
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        fs::create_dir_all(parent).map_err(|error| {
            NostrHostError::new(format!(
                "shadow nostr service: create sqlite parent dir {}: {error}",
                parent.display()
            ))
        })?;
    }
    Ok(())
}

fn map_nostr_event(row: &rusqlite::Row<'_>) -> rusqlite::Result<NostrEvent> {
    Ok(NostrEvent {
        id: row.get("id")?,
        kind: row.get("kind")?,
        pubkey: row.get("pubkey")?,
        created_at: row.get("created_at")?,
        content: row.get("content")?,
        identifier: row.get("identifier")?,
    })
}

fn normalize_optional_string(value: Option<String>) -> Option<String> {
    value
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn kind_is_replaceable(kind: u32) -> bool {
    kind == 0 || kind == 3 || (10_000..20_000).contains(&kind) || (30_000..40_000).contains(&kind)
}

#[cfg(test)]
mod tests {
    use super::{
        Kind1Event, ListKind1Query, NostrEvent, NostrQuery, NostrReplaceableQuery,
        SqliteNostrService,
    };
    use rusqlite::Connection;

    fn in_memory_service() -> SqliteNostrService {
        let service = SqliteNostrService {
            connection: Connection::open_in_memory().expect("open in-memory sqlite"),
        };
        service.initialize().expect("initialize sqlite schema");
        service
    }

    #[test]
    fn query_filters_by_author_and_limit() {
        let service = in_memory_service();

        let events = service
            .query(NostrQuery {
                authors: Some(vec![String::from("npub-feed-a")]),
                limit: Some(1),
                ..NostrQuery::default()
            })
            .expect("query cached events");

        assert_eq!(events.len(), 1);
        assert_eq!(events[0].id, "shadow-note-2");
    }

    #[test]
    fn count_uses_generic_query_filters() {
        let service = in_memory_service();

        let count = service
            .count(NostrQuery {
                authors: Some(vec![String::from("npub-feed-a")]),
                since: Some(1_700_000_002),
                ..NostrQuery::default()
            })
            .expect("count cached events");

        assert_eq!(count, 1);
    }

    #[test]
    fn get_event_reads_seeded_cache_rows() {
        let service = in_memory_service();

        let event = service
            .get_event("shadow-note-3")
            .expect("read cached event")
            .expect("seeded event");

        assert_eq!(event.kind, 1);
        assert_eq!(event.pubkey, "npub-feed-b");
    }

    #[test]
    fn get_replaceable_returns_latest_matching_event() {
        let service = in_memory_service();
        for event in [
            NostrEvent {
                content: String::from("profile-v1"),
                created_at: 1_700_000_100,
                id: String::from("profile-1"),
                kind: 0,
                pubkey: String::from("npub-feed-a"),
                identifier: None,
            },
            NostrEvent {
                content: String::from("profile-v2"),
                created_at: 1_700_000_200,
                id: String::from("profile-2"),
                kind: 0,
                pubkey: String::from("npub-feed-a"),
                identifier: None,
            },
        ] {
            service
                .store_event(&event)
                .expect("store replaceable event");
        }

        let event = service
            .get_replaceable(NostrReplaceableQuery {
                kind: 0,
                pubkey: String::from("npub-feed-a"),
                identifier: None,
            })
            .expect("lookup replaceable event")
            .expect("replaceable event");

        assert_eq!(event.id, "profile-2");
        assert_eq!(event.content, "profile-v2");
    }

    #[test]
    fn list_kind1_compatibility_stays_kind1_only() {
        let service = in_memory_service();
        service
            .store_event(&NostrEvent {
                content: String::from("{\"name\":\"shadow\"}"),
                created_at: 1_700_000_500,
                id: String::from("profile-metadata"),
                kind: 0,
                pubkey: String::from("npub-feed-a"),
                identifier: None,
            })
            .expect("store non-kind1 event");

        let events = service
            .list_kind1(ListKind1Query::default())
            .expect("list kind1 events");

        assert!(events.iter().all(|event: &Kind1Event| event.kind == 1));
        assert_eq!(events.len(), 3);
    }

    #[test]
    fn initialize_imports_legacy_kind1_rows() {
        let connection = Connection::open_in_memory().expect("open in-memory sqlite");
        connection
            .execute_batch(
                "
                CREATE TABLE nostr_kind1_events (
                    sequence INTEGER PRIMARY KEY,
                    id TEXT NOT NULL UNIQUE,
                    kind INTEGER NOT NULL,
                    pubkey TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    content TEXT NOT NULL
                );
                INSERT INTO nostr_kind1_events (
                    sequence,
                    id,
                    kind,
                    pubkey,
                    created_at,
                    content
                ) VALUES (1, 'legacy-note', 1, 'npub-legacy', 1700000999, 'legacy cache row');
                ",
            )
            .expect("create legacy kind1 table");

        let service = SqliteNostrService { connection };
        service.initialize().expect("initialize generic schema");

        let event = service
            .get_event("legacy-note")
            .expect("read migrated event")
            .expect("migrated event");
        assert_eq!(event.pubkey, "npub-legacy");
        assert_eq!(
            service
                .query(NostrQuery::default())
                .expect("query events")
                .len(),
            1
        );
    }

    #[test]
    fn get_replaceable_rejects_non_replaceable_kinds() {
        let service = in_memory_service();

        let error = service
            .get_replaceable(NostrReplaceableQuery {
                kind: 1,
                pubkey: String::from("npub-feed-a"),
                identifier: None,
            })
            .expect_err("non-replaceable kinds should fail");

        assert!(error.message().contains("replaceable"));
    }
}
