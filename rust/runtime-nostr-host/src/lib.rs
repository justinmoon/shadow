use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use deno_core::extension;
use deno_core::op2;
use deno_core::Extension;
use deno_core::OpState;
use deno_error::JsErrorBox;
use rusqlite::params;
use rusqlite::Connection;
use serde::{Deserialize, Serialize};

const DEFAULT_PUBLISH_PUBKEY: &str = "npub-shadow-os";
const NOSTR_DB_PATH_ENV: &str = "SHADOW_RUNTIME_NOSTR_DB_PATH";
const IN_MEMORY_DB_PATH: &str = ":memory:";
const INITIAL_CREATED_AT_BASE: u64 = 1_700_000_000;

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Kind1Event {
    pub content: String,
    pub created_at: u64,
    pub id: String,
    pub kind: u32,
    pub pubkey: String,
}

#[derive(Debug, Default, Deserialize)]
struct ListKind1Query {
    authors: Option<Vec<String>>,
    since: Option<u64>,
    until: Option<u64>,
    limit: Option<usize>,
}

#[derive(Debug, Default, Deserialize)]
struct PublishKind1Request {
    content: Option<String>,
    pubkey: Option<String>,
}

#[derive(Debug)]
struct NostrHostState {
    service: Result<SqliteNostrService, String>,
}

impl NostrHostState {
    fn from_env() -> Self {
        Self {
            service: SqliteNostrService::from_env(),
        }
    }

    fn service(&self) -> Result<&SqliteNostrService, JsErrorBox> {
        self.service
            .as_ref()
            .map_err(|error| JsErrorBox::generic(error.clone()))
    }
}

#[derive(Debug)]
struct SqliteNostrService {
    connection: Connection,
}

impl SqliteNostrService {
    fn from_env() -> Result<Self, String> {
        let db_path = std::env::var(NOSTR_DB_PATH_ENV)
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| String::from(IN_MEMORY_DB_PATH));
        if db_path != IN_MEMORY_DB_PATH {
            ensure_db_parent_dir(&db_path)?;
        }

        let connection = Connection::open(&db_path)
            .map_err(|error| format!("runtime nostr host: open sqlite db {db_path}: {error}"))?;
        let service = Self { connection };
        service.initialize()?;
        Ok(service)
    }

    fn initialize(&self) -> Result<(), String> {
        self.connection
            .execute_batch(
                "
                CREATE TABLE IF NOT EXISTS nostr_kind1_events (
                    sequence INTEGER PRIMARY KEY,
                    id TEXT NOT NULL UNIQUE,
                    kind INTEGER NOT NULL,
                    pubkey TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    content TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS nostr_kind1_events_created_at_idx
                    ON nostr_kind1_events (created_at DESC, sequence DESC);
                ",
            )
            .map_err(|error| format!("runtime nostr host: initialize sqlite schema: {error}"))?;

        let row_count: u64 = self
            .connection
            .query_row("SELECT COUNT(*) FROM nostr_kind1_events", [], |row| {
                row.get(0)
            })
            .map_err(|error| format!("runtime nostr host: count sqlite rows: {error}"))?;

        if row_count == 0 {
            self.seed_initial_events()?;
        }

        Ok(())
    }

    fn seed_initial_events(&self) -> Result<(), String> {
        for (sequence, id, created_at, pubkey, content) in [
            (
                1_u64,
                "shadow-note-1",
                1_700_000_001_u64,
                "npub-feed-a",
                "shadow os owns nostr for tiny apps",
            ),
            (
                2_u64,
                "shadow-note-2",
                1_700_000_002_u64,
                "npub-feed-a",
                "relay subscriptions will live below app code",
            ),
            (
                3_u64,
                "shadow-note-3",
                1_700_000_003_u64,
                "npub-feed-b",
                "local cache warmed from the system service",
            ),
        ] {
            self.connection
                .execute(
                    "
                    INSERT INTO nostr_kind1_events (
                        sequence,
                        id,
                        kind,
                        pubkey,
                        created_at,
                        content
                    ) VALUES (?1, ?2, 1, ?3, ?4, ?5)
                    ",
                    params![sequence, id, pubkey, created_at, content],
                )
                .map_err(|error| format!("runtime nostr host: seed sqlite note {id}: {error}"))?;
        }

        Ok(())
    }

    fn list_kind1(&self, query: ListKind1Query) -> Result<Vec<Kind1Event>, JsErrorBox> {
        let authors = query
            .authors
            .map(|authors| authors.into_iter().collect::<BTreeSet<_>>());
        let mut statement = self
            .connection
            .prepare(
                "
                SELECT id, kind, pubkey, created_at, content
                FROM nostr_kind1_events
                WHERE kind = 1
                ORDER BY created_at DESC, sequence DESC
                ",
            )
            .map_err(|error| {
                JsErrorBox::generic(format!("nostr.listKind1 prepare sqlite query: {error}"))
            })?;
        let rows = statement.query_map([], map_kind1_event).map_err(|error| {
            JsErrorBox::generic(format!("nostr.listKind1 run sqlite query: {error}"))
        })?;

        let mut events = Vec::new();
        for row in rows {
            let event = row.map_err(|error| {
                JsErrorBox::generic(format!("nostr.listKind1 decode sqlite row: {error}"))
            })?;
            if authors
                .as_ref()
                .is_some_and(|authors| !authors.contains(&event.pubkey))
            {
                continue;
            }
            if query.since.is_some_and(|since| event.created_at < since) {
                continue;
            }
            if query.until.is_some_and(|until| event.created_at > until) {
                continue;
            }

            events.push(event);
            if query.limit.is_some_and(|limit| events.len() >= limit) {
                break;
            }
        }

        Ok(events)
    }

    fn publish_kind1(&self, request: PublishKind1Request) -> Result<Kind1Event, JsErrorBox> {
        let content = request
            .content
            .as_deref()
            .map(str::trim)
            .filter(|content| !content.is_empty())
            .ok_or_else(|| JsErrorBox::type_error("nostr.publishKind1 requires non-empty content"))?
            .to_owned();
        let next_sequence: u64 = self
            .connection
            .query_row(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM nostr_kind1_events",
                [],
                |row| row.get(0),
            )
            .map_err(|error| {
                JsErrorBox::generic(format!(
                    "nostr.publishKind1 load next sqlite sequence: {error}"
                ))
            })?;
        let next_created_at: u64 = self
            .connection
            .query_row(
                "SELECT COALESCE(MAX(created_at), ?1) + 1 FROM nostr_kind1_events",
                params![INITIAL_CREATED_AT_BASE],
                |row| row.get(0),
            )
            .map_err(|error| {
                JsErrorBox::generic(format!(
                    "nostr.publishKind1 load next sqlite timestamp: {error}"
                ))
            })?;
        let pubkey = request
            .pubkey
            .as_deref()
            .filter(|pubkey| !pubkey.is_empty())
            .unwrap_or(DEFAULT_PUBLISH_PUBKEY)
            .to_owned();
        let id = format!("shadow-note-{next_sequence}");

        let event = Kind1Event {
            content,
            created_at: next_created_at,
            id: id.clone(),
            kind: 1,
            pubkey,
        };
        self.connection
            .execute(
                "
                INSERT INTO nostr_kind1_events (
                    sequence,
                    id,
                    kind,
                    pubkey,
                    created_at,
                    content
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                ",
                params![
                    next_sequence,
                    event.id,
                    event.kind,
                    event.pubkey,
                    event.created_at,
                    event.content
                ],
            )
            .map_err(|error| {
                JsErrorBox::generic(format!(
                    "nostr.publishKind1 insert sqlite note {id}: {error}"
                ))
            })?;

        Ok(event)
    }
}

#[op2]
#[serde]
fn op_runtime_nostr_list_kind1(
    state: &mut OpState,
    #[serde] query: ListKind1Query,
) -> Result<Vec<Kind1Event>, JsErrorBox> {
    state
        .borrow::<NostrHostState>()
        .service()?
        .list_kind1(query)
}

#[op2]
#[serde]
fn op_runtime_nostr_publish_kind1(
    state: &mut OpState,
    #[serde] request: PublishKind1Request,
) -> Result<Kind1Event, JsErrorBox> {
    state
        .borrow::<NostrHostState>()
        .service()?
        .publish_kind1(request)
}

fn ensure_db_parent_dir(db_path: &str) -> Result<(), String> {
    let path = Path::new(db_path);
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        fs::create_dir_all(parent).map_err(|error| {
            format!(
                "runtime nostr host: create sqlite parent dir {}: {error}",
                parent.display()
            )
        })?;
    }
    Ok(())
}

fn map_kind1_event(row: &rusqlite::Row<'_>) -> rusqlite::Result<Kind1Event> {
    Ok(Kind1Event {
        id: row.get("id")?,
        kind: row.get("kind")?,
        pubkey: row.get("pubkey")?,
        created_at: row.get("created_at")?,
        content: row.get("content")?,
    })
}

extension!(
    runtime_nostr_host_extension,
    ops = [op_runtime_nostr_list_kind1, op_runtime_nostr_publish_kind1],
    esm_entry_point = "ext:runtime_nostr_host_extension/bootstrap.js",
    esm = [dir "js", "bootstrap.js"],
    state = |state| {
        state.put(NostrHostState::from_env());
    },
);

pub fn init_extension() -> Extension {
    runtime_nostr_host_extension::init()
}
