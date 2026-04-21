use std::collections::BTreeSet;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

use nostr::prelude::{Keys, ToBech32};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::services::session_config::{self, RUNTIME_SESSION_CONFIG_ENV};

use super::types::{
    NostrAccountSource, NostrAccountSummary, NostrEvent, NostrEventReference,
    NostrPublicKeyReference, NostrQuery, NostrReplaceableQuery,
};

pub const NOSTR_ACCOUNT_NSEC_ENV: &str = "SHADOW_RUNTIME_NOSTR_ACCOUNT_NSEC";
pub const NOSTR_ACCOUNT_PATH_ENV: &str = "SHADOW_RUNTIME_NOSTR_ACCOUNT_PATH";
pub const NOSTR_DB_PATH_ENV: &str = "SHADOW_RUNTIME_NOSTR_DB_PATH";

const IN_MEMORY_DB_PATH: &str = ":memory:";
const LEGACY_KIND1_TABLE: &str = "nostr_kind1_events";
const NOSTR_ACCOUNT_BASENAME: &str = "runtime-nostr-account.json";
const LEGACY_DEMO_EVENT_IDS: [&str; 3] = ["shadow-note-1", "shadow-note-2", "shadow-note-3"];

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
struct PersistedNostrAccount {
    nsec: String,
    source: NostrAccountSource,
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
pub struct ListKind1Query {
    pub authors: Option<Vec<String>>,
    pub since: Option<u64>,
    pub until: Option<u64>,
    pub limit: Option<usize>,
}

#[derive(Debug)]
pub struct SqliteNostrService {
    connection: Connection,
}

impl SqliteNostrService {
    pub fn from_env() -> Result<Self, NostrHostError> {
        let db_path = resolved_db_path()?;
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
                    identifier TEXT,
                    root_event_id TEXT,
                    reply_to_event_id TEXT,
                    references_json TEXT NOT NULL DEFAULT '[]',
                    public_keys_json TEXT NOT NULL DEFAULT '[]'
                );
                CREATE INDEX IF NOT EXISTS nostr_events_created_at_idx
                    ON nostr_events (created_at DESC, sequence DESC);
                CREATE INDEX IF NOT EXISTS nostr_events_replaceable_idx
                    ON nostr_events (kind, pubkey, identifier, created_at DESC, sequence DESC);
                CREATE INDEX IF NOT EXISTS nostr_events_reply_idx
                    ON nostr_events (reply_to_event_id, created_at DESC, sequence DESC);
                ",
            )
            .map_err(|error| {
                NostrHostError::new(format!(
                    "shadow nostr service: initialize sqlite schema: {error}"
                ))
            })?;
        self.ensure_nostr_events_columns()?;

        self.import_legacy_kind1_events()?;
        self.remove_legacy_demo_events()?;

        Ok(())
    }

    fn ensure_nostr_events_columns(&self) -> Result<(), NostrHostError> {
        self.ensure_nostr_events_column(
            "root_event_id",
            "ALTER TABLE nostr_events ADD COLUMN root_event_id TEXT",
        )?;
        self.ensure_nostr_events_column(
            "reply_to_event_id",
            "ALTER TABLE nostr_events ADD COLUMN reply_to_event_id TEXT",
        )?;
        self.ensure_nostr_events_column(
            "references_json",
            "ALTER TABLE nostr_events ADD COLUMN references_json TEXT NOT NULL DEFAULT '[]'",
        )?;
        self.ensure_nostr_events_column(
            "public_keys_json",
            "ALTER TABLE nostr_events ADD COLUMN public_keys_json TEXT NOT NULL DEFAULT '[]'",
        )?;
        self.connection
            .execute(
                "
                CREATE INDEX IF NOT EXISTS nostr_events_reply_idx
                ON nostr_events (reply_to_event_id, created_at DESC, sequence DESC)
                ",
                [],
            )
            .map_err(|error| {
                NostrHostError::new(format!(
                    "shadow nostr service: ensure reply sqlite index: {error}"
                ))
            })?;
        Ok(())
    }

    fn ensure_nostr_events_column(
        &self,
        column_name: &str,
        alter_sql: &str,
    ) -> Result<(), NostrHostError> {
        let mut statement = self
            .connection
            .prepare("PRAGMA table_info(nostr_events)")
            .map_err(|error| {
                NostrHostError::new(format!(
                    "shadow nostr service: inspect sqlite schema columns: {error}"
                ))
            })?;
        let mut rows = statement.query([]).map_err(|error| {
            NostrHostError::new(format!(
                "shadow nostr service: query sqlite schema columns: {error}"
            ))
        })?;
        while let Some(row) = rows.next().map_err(|error| {
            NostrHostError::new(format!(
                "shadow nostr service: decode sqlite schema columns: {error}"
            ))
        })? {
            let existing: String = row.get("name").map_err(|error| {
                NostrHostError::new(format!(
                    "shadow nostr service: read sqlite column name: {error}"
                ))
            })?;
            if existing == column_name {
                return Ok(());
            }
        }

        self.connection.execute(alter_sql, []).map_err(|error| {
            NostrHostError::new(format!(
                "shadow nostr service: alter sqlite schema for {column_name}: {error}"
            ))
        })?;
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
                    identifier,
                    root_event_id,
                    reply_to_event_id,
                    references_json,
                    public_keys_json
                )
                SELECT id, kind, pubkey, created_at, content, NULL, NULL, NULL, '[]', '[]'
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

    fn remove_legacy_demo_events(&self) -> Result<(), NostrHostError> {
        self.connection
            .execute(
                "DELETE FROM nostr_events WHERE id IN (?1, ?2, ?3)",
                params![
                    LEGACY_DEMO_EVENT_IDS[0],
                    LEGACY_DEMO_EVENT_IDS[1],
                    LEGACY_DEMO_EVENT_IDS[2],
                ],
            )
            .map_err(|error| {
                NostrHostError::new(format!(
                    "shadow nostr service: delete legacy demo events: {error}"
                ))
            })?;
        Ok(())
    }

    pub fn current_account(&self) -> Result<Option<NostrAccountSummary>, NostrHostError> {
        if let Some(summary) = env_account_summary()? {
            return Ok(Some(summary));
        }

        let Some(account_path) = account_path()? else {
            return Ok(None);
        };
        read_persisted_account(&account_path)
    }

    pub fn generate_account(&self) -> Result<NostrAccountSummary, NostrHostError> {
        self.persist_active_account(Keys::generate(), NostrAccountSource::Generated)
    }

    pub fn import_account_nsec(
        &self,
        nsec: impl AsRef<str>,
    ) -> Result<NostrAccountSummary, NostrHostError> {
        let keys = parse_account_keys(
            nsec.as_ref(),
            "nostr.importAccountNsec requires a valid nsec or hex secret key",
        )?;
        self.persist_active_account(keys, NostrAccountSource::Imported)
    }

    #[doc(hidden)]
    pub fn active_account_keys(&self) -> Result<Keys, NostrHostError> {
        if let Some(keys) = env_account_keys()? {
            return Ok(keys);
        }

        let Some(account_path) = account_path()? else {
            return Err(NostrHostError::new(
                "shadow nostr service: no active account is configured",
            ));
        };
        let (keys, _source) = read_persisted_account_keys(&account_path)?.ok_or_else(|| {
            NostrHostError::new("shadow nostr service: no active account is configured")
        })?;
        Ok(keys)
    }

    fn persist_active_account(
        &self,
        keys: Keys,
        source: NostrAccountSource,
    ) -> Result<NostrAccountSummary, NostrHostError> {
        let account_path = account_path()?.ok_or_else(|| {
            NostrHostError::new(format!(
                "shadow nostr service: cannot resolve account path; set {NOSTR_ACCOUNT_PATH_ENV} or configure {RUNTIME_SESSION_CONFIG_ENV} or {NOSTR_DB_PATH_ENV}"
            ))
        })?;
        let persisted = PersistedNostrAccount {
            nsec: keys.secret_key().to_bech32().map_err(|error| {
                NostrHostError::new(format!(
                    "shadow nostr service: encode account nsec for {}: {error}",
                    account_path.display()
                ))
            })?,
            source,
        };
        write_persisted_account(&account_path, &persisted)?;
        summarize_account(&keys, source)
    }

    pub fn query(&self, query: NostrQuery) -> Result<Vec<NostrEvent>, NostrHostError> {
        let NostrQuery {
            ids,
            authors,
            kinds,
            referenced_ids,
            reply_to_ids,
            since,
            until,
            limit,
        } = query;
        let ids = ids.map(|ids| ids.into_iter().collect::<BTreeSet<_>>());
        let authors = authors.map(|authors| authors.into_iter().collect::<BTreeSet<_>>());
        let kinds = kinds.map(|kinds| kinds.into_iter().collect::<BTreeSet<_>>());
        let referenced_ids = referenced_ids
            .map(|referenced_ids| referenced_ids.into_iter().collect::<BTreeSet<_>>());
        let reply_to_ids =
            reply_to_ids.map(|reply_to_ids| reply_to_ids.into_iter().collect::<BTreeSet<_>>());
        let limit = limit.unwrap_or(usize::MAX);

        let mut statement = self
            .connection
            .prepare(
                "
                SELECT id, kind, pubkey, created_at, content, identifier,
                       root_event_id, reply_to_event_id, references_json, public_keys_json
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
            if referenced_ids.as_ref().is_some_and(|referenced_ids| {
                !event
                    .references
                    .iter()
                    .any(|reference| referenced_ids.contains(reference.event_id.as_str()))
            }) {
                continue;
            }
            if reply_to_ids.as_ref().is_some_and(|reply_to_ids| {
                !event
                    .reply_to_event_id
                    .as_deref()
                    .is_some_and(|reply_to_id| reply_to_ids.contains(reply_to_id))
            }) {
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
                SELECT id, kind, pubkey, created_at, content, identifier,
                       root_event_id, reply_to_event_id, references_json, public_keys_json
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
            SELECT id, kind, pubkey, created_at, content, identifier,
                   root_event_id, reply_to_event_id, references_json, public_keys_json
            FROM nostr_events
            WHERE kind = ?1 AND pubkey = ?2 AND identifier = ?3
            ORDER BY created_at DESC, sequence DESC
            LIMIT 1
            "
        } else {
            "
            SELECT id, kind, pubkey, created_at, content, identifier,
                   root_event_id, reply_to_event_id, references_json, public_keys_json
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
            referenced_ids: None,
            reply_to_ids: None,
            since: query.since,
            until: query.until,
            limit: query.limit,
        })
        .map(|events| events.into_iter().map(Kind1Event::from).collect())
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
                    identifier,
                    root_event_id,
                    reply_to_event_id,
                    references_json,
                    public_keys_json
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                ",
                params![
                    event.id,
                    event.kind,
                    event.pubkey,
                    event.created_at,
                    event.content,
                    event.identifier,
                    event.root_event_id,
                    event.reply_to_event_id,
                    encode_references_json(&event.references)?,
                    encode_public_keys_json(&event.public_keys)?
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
            root_event_id: None,
            reply_to_event_id: None,
            references: Vec::new(),
            public_keys: Vec::new(),
        }
    }
}

pub fn current_account() -> Result<Option<NostrAccountSummary>, NostrHostError> {
    SqliteNostrService::from_env()?.current_account()
}

pub fn generate_account() -> Result<NostrAccountSummary, NostrHostError> {
    SqliteNostrService::from_env()?.generate_account()
}

pub fn import_account_nsec(nsec: impl AsRef<str>) -> Result<NostrAccountSummary, NostrHostError> {
    SqliteNostrService::from_env()?.import_account_nsec(nsec)
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

fn account_path() -> Result<Option<PathBuf>, NostrHostError> {
    let explicit_path = std::env::var(NOSTR_ACCOUNT_PATH_ENV)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .map(PathBuf::from);
    if explicit_path.is_some() {
        return Ok(explicit_path);
    }
    default_account_path()
}

fn default_account_path() -> Result<Option<PathBuf>, NostrHostError> {
    let Some(db_path) = configured_db_path()? else {
        return Ok(None);
    };
    if db_path == IN_MEMORY_DB_PATH {
        return Ok(None);
    }

    let Some(parent) = Path::new(&db_path)
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    else {
        return Ok(None);
    };
    Ok(Some(parent.join(NOSTR_ACCOUNT_BASENAME)))
}

pub(crate) fn configured_db_path() -> Result<Option<String>, NostrHostError> {
    if let Some(db_path) = session_config::runtime_services_config()
        .map_err(|error| NostrHostError::new(error.to_string()))?
        .and_then(|services| services.nostr_db_path)
    {
        return Ok(Some(db_path.to_string_lossy().into_owned()));
    }
    Ok(std::env::var(NOSTR_DB_PATH_ENV)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty()))
}

fn resolved_db_path() -> Result<String, NostrHostError> {
    Ok(configured_db_path()?.unwrap_or_else(|| String::from(IN_MEMORY_DB_PATH)))
}

fn ensure_db_parent_dir(db_path: &str) -> Result<(), NostrHostError> {
    ensure_parent_dir(Path::new(db_path), "sqlite parent")
}

fn ensure_parent_dir(path: &Path, label: &str) -> Result<(), NostrHostError> {
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        fs::create_dir_all(parent).map_err(|error| {
            NostrHostError::new(format!(
                "shadow nostr service: create {label} dir {}: {error}",
                parent.display()
            ))
        })?;
    }
    Ok(())
}

fn env_account_summary() -> Result<Option<NostrAccountSummary>, NostrHostError> {
    let Some(keys) = env_account_keys()? else {
        return Ok(None);
    };
    summarize_account(&keys, NostrAccountSource::Env).map(Some)
}

fn env_account_keys() -> Result<Option<Keys>, NostrHostError> {
    let Some(nsec) = std::env::var(NOSTR_ACCOUNT_NSEC_ENV)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
    else {
        return Ok(None);
    };
    let keys = parse_account_keys(
        &nsec,
        &format!(
            "shadow nostr service: {NOSTR_ACCOUNT_NSEC_ENV} must be a valid nsec or hex secret key"
        ),
    )?;
    Ok(Some(keys))
}

fn read_persisted_account(
    account_path: &Path,
) -> Result<Option<NostrAccountSummary>, NostrHostError> {
    let Some((keys, source)) = read_persisted_account_keys(account_path)? else {
        return Ok(None);
    };
    summarize_account(&keys, source).map(Some)
}

fn read_persisted_account_keys(
    account_path: &Path,
) -> Result<Option<(Keys, NostrAccountSource)>, NostrHostError> {
    if !account_path.exists() {
        return Ok(None);
    }

    let encoded = fs::read_to_string(account_path).map_err(|error| {
        NostrHostError::new(format!(
            "shadow nostr service: read account file {}: {error}",
            account_path.display()
        ))
    })?;
    let persisted: PersistedNostrAccount = serde_json::from_str(&encoded).map_err(|error| {
        NostrHostError::new(format!(
            "shadow nostr service: decode account file {}: {error}",
            account_path.display()
        ))
    })?;
    let keys = parse_account_keys(
        &persisted.nsec,
        &format!(
            "shadow nostr service: parse account file {}",
            account_path.display()
        ),
    )?;
    Ok(Some((keys, persisted.source)))
}

fn write_persisted_account(
    account_path: &Path,
    persisted: &PersistedNostrAccount,
) -> Result<(), NostrHostError> {
    ensure_parent_dir(account_path, "account")?;
    let encoded = serde_json::to_string(persisted).map_err(|error| {
        NostrHostError::new(format!(
            "shadow nostr service: encode account file {}: {error}",
            account_path.display()
        ))
    })?;
    let temp_path = account_path.with_extension("tmp");
    fs::write(&temp_path, encoded.as_bytes()).map_err(|error| {
        NostrHostError::new(format!(
            "shadow nostr service: write account temp file {}: {error}",
            temp_path.display()
        ))
    })?;
    fs::rename(&temp_path, account_path).map_err(|error| {
        NostrHostError::new(format!(
            "shadow nostr service: rename account temp file {} -> {}: {error}",
            temp_path.display(),
            account_path.display()
        ))
    })?;
    Ok(())
}

fn parse_account_keys(input: &str, context: &str) -> Result<Keys, NostrHostError> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err(NostrHostError::new(context));
    }

    Keys::parse(trimmed).map_err(|error| NostrHostError::new(format!("{context}: {error}")))
}

fn summarize_account(
    keys: &Keys,
    source: NostrAccountSource,
) -> Result<NostrAccountSummary, NostrHostError> {
    let npub = keys.public_key().to_bech32().map_err(|error| {
        NostrHostError::new(format!(
            "shadow nostr service: encode account npub: {error}"
        ))
    })?;
    Ok(NostrAccountSummary { npub, source })
}

fn map_nostr_event(row: &rusqlite::Row<'_>) -> rusqlite::Result<NostrEvent> {
    let references_json: String = row.get("references_json")?;
    let public_keys_json: String = row.get("public_keys_json")?;
    Ok(NostrEvent {
        id: row.get("id")?,
        kind: row.get("kind")?,
        pubkey: row.get("pubkey")?,
        created_at: row.get("created_at")?,
        content: row.get("content")?,
        identifier: row.get("identifier")?,
        root_event_id: row.get("root_event_id")?,
        reply_to_event_id: row.get("reply_to_event_id")?,
        references: decode_references_json(&references_json).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                references_json.len(),
                rusqlite::types::Type::Text,
                Box::new(error),
            )
        })?,
        public_keys: decode_public_keys_json(&public_keys_json).map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                public_keys_json.len(),
                rusqlite::types::Type::Text,
                Box::new(error),
            )
        })?,
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

fn encode_references_json(references: &[NostrEventReference]) -> Result<String, NostrHostError> {
    serde_json::to_string(references).map_err(|error| {
        NostrHostError::new(format!(
            "shadow nostr service: encode event references json: {error}"
        ))
    })
}

fn encode_public_keys_json(
    public_keys: &[NostrPublicKeyReference],
) -> Result<String, NostrHostError> {
    serde_json::to_string(public_keys).map_err(|error| {
        NostrHostError::new(format!(
            "shadow nostr service: encode event public keys json: {error}"
        ))
    })
}

fn decode_references_json(
    references_json: &str,
) -> Result<Vec<NostrEventReference>, serde_json::Error> {
    serde_json::from_str(references_json)
}

fn decode_public_keys_json(
    public_keys_json: &str,
) -> Result<Vec<NostrPublicKeyReference>, serde_json::Error> {
    serde_json::from_str(public_keys_json)
}

#[cfg(test)]
mod tests {
    use super::{
        account_path, current_account, default_account_path, generate_account, import_account_nsec,
        Kind1Event, ListKind1Query, NostrAccountSource, NostrEvent, NostrEventReference,
        NostrQuery, NostrReplaceableQuery, SqliteNostrService, LEGACY_DEMO_EVENT_IDS,
        NOSTR_ACCOUNT_NSEC_ENV, NOSTR_ACCOUNT_PATH_ENV, NOSTR_DB_PATH_ENV,
        RUNTIME_SESSION_CONFIG_ENV,
    };
    use nostr::prelude::{Keys, ToBech32};
    use rusqlite::Connection;
    use std::fs;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    use crate::services::test_env_lock;

    fn in_memory_service() -> SqliteNostrService {
        let service = SqliteNostrService {
            connection: Connection::open_in_memory().expect("open in-memory sqlite"),
        };
        service.initialize().expect("initialize sqlite schema");
        service
    }

    fn store_cached_test_events(service: &SqliteNostrService) {
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
                public_keys: Vec::new(),
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
                public_keys: Vec::new(),
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
                public_keys: Vec::new(),
            },
        ] {
            service
                .store_event(&event)
                .expect("store cached test event");
        }
    }

    fn with_temp_env<T>(f: impl FnOnce(PathBuf, PathBuf) -> T) -> T {
        let _guard = test_env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time")
            .as_nanos();
        let temp_dir = std::env::temp_dir().join(format!("shadow-sdk-nostr-account-{timestamp}"));
        let db_path = temp_dir.join("runtime-nostr.sqlite3");
        let account_path = temp_dir.join("runtime-nostr-account.json");
        fs::create_dir_all(&temp_dir).expect("create temp dir");
        std::env::set_var(NOSTR_DB_PATH_ENV, &db_path);
        std::env::remove_var(NOSTR_ACCOUNT_NSEC_ENV);
        std::env::remove_var(NOSTR_ACCOUNT_PATH_ENV);
        std::env::remove_var(RUNTIME_SESSION_CONFIG_ENV);

        let output = f(db_path.clone(), account_path.clone());

        std::env::remove_var(NOSTR_DB_PATH_ENV);
        std::env::remove_var(NOSTR_ACCOUNT_NSEC_ENV);
        std::env::remove_var(NOSTR_ACCOUNT_PATH_ENV);
        std::env::remove_var(RUNTIME_SESSION_CONFIG_ENV);
        let _ = fs::remove_dir_all(&temp_dir);
        output
    }

    fn with_temp_session_config<T>(f: impl FnOnce(PathBuf, PathBuf) -> T) -> T {
        let _guard = test_env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time")
            .as_nanos();
        let temp_dir = std::env::temp_dir().join(format!("shadow-sdk-nostr-config-{timestamp}"));
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
        std::env::set_var(NOSTR_DB_PATH_ENV, temp_dir.join("ignored.sqlite3"));
        std::env::remove_var(NOSTR_ACCOUNT_NSEC_ENV);
        std::env::remove_var(NOSTR_ACCOUNT_PATH_ENV);

        let output = f(db_path.clone(), account_path.clone());

        std::env::remove_var(RUNTIME_SESSION_CONFIG_ENV);
        std::env::remove_var(NOSTR_DB_PATH_ENV);
        std::env::remove_var(NOSTR_ACCOUNT_NSEC_ENV);
        std::env::remove_var(NOSTR_ACCOUNT_PATH_ENV);
        let _ = fs::remove_dir_all(&temp_dir);
        output
    }

    #[test]
    fn default_account_path_uses_nostr_db_parent() {
        with_temp_env(|db_path, expected_account_path| {
            assert_eq!(
                default_account_path().expect("resolve default account path"),
                Some(expected_account_path.clone())
            );
            assert_eq!(
                account_path().expect("resolve account path"),
                Some(expected_account_path.clone())
            );
            assert_eq!(db_path.parent(), expected_account_path.parent());
        });
    }

    #[test]
    fn default_account_path_is_none_for_in_memory_db() {
        let _guard = test_env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        std::env::set_var(NOSTR_DB_PATH_ENV, ":memory:");
        std::env::remove_var(NOSTR_ACCOUNT_PATH_ENV);
        std::env::remove_var(NOSTR_ACCOUNT_NSEC_ENV);
        std::env::remove_var(RUNTIME_SESSION_CONFIG_ENV);

        assert_eq!(
            default_account_path().expect("resolve default account path"),
            None
        );
        assert_eq!(account_path().expect("resolve account path"), None);

        std::env::remove_var(NOSTR_DB_PATH_ENV);
    }

    #[test]
    fn default_account_path_prefers_session_config_nostr_db_parent() {
        with_temp_session_config(|db_path, expected_account_path| {
            assert_eq!(
                default_account_path().expect("resolve default account path"),
                Some(expected_account_path.clone())
            );
            assert_eq!(
                account_path().expect("resolve account path"),
                Some(expected_account_path.clone())
            );
            assert_eq!(db_path.parent(), expected_account_path.parent());
        });
    }

    #[test]
    fn generate_and_current_account_persist_shared_account_state() {
        with_temp_env(|_db_path, account_path| {
            let generated = generate_account().expect("generate account");
            assert_eq!(generated.source, NostrAccountSource::Generated);
            assert!(generated.npub.starts_with("npub1"));
            assert!(account_path.exists());

            let persisted = fs::read_to_string(&account_path).expect("read account file");
            assert!(persisted.contains("\"source\":\"generated\""));
            assert!(persisted.contains("\"nsec\":\"nsec1"));
            assert!(!persisted.contains(&generated.npub));

            let current = current_account()
                .expect("read current account")
                .expect("persisted account");
            assert_eq!(current, generated);
        });
    }

    #[test]
    fn import_account_nsec_persists_imported_source() {
        with_temp_env(|_db_path, account_path| {
            let keys = Keys::generate();
            let nsec = keys
                .secret_key()
                .to_bech32()
                .expect("encode generated nsec");

            let imported = import_account_nsec(&nsec).expect("import account");
            assert_eq!(imported.source, NostrAccountSource::Imported);
            assert_eq!(
                imported.npub,
                keys.public_key()
                    .to_bech32()
                    .expect("encode generated npub")
            );

            let persisted = fs::read_to_string(&account_path).expect("read imported account file");
            assert!(persisted.contains("\"source\":\"imported\""));
            assert!(persisted.contains(&nsec));
        });
    }

    #[test]
    fn import_account_nsec_rejects_invalid_secret_material() {
        with_temp_env(|_db_path, _account_path| {
            let error = import_account_nsec("not-a-secret").expect_err("reject invalid nsec");
            assert!(error.message().contains("valid nsec"));
        });
    }

    #[test]
    fn current_account_prefers_env_seeded_override() {
        with_temp_env(|_db_path, _account_path| {
            let keys = Keys::generate();
            let nsec = keys.secret_key().to_bech32().expect("encode env nsec");
            std::env::set_var(NOSTR_ACCOUNT_NSEC_ENV, &nsec);

            let current = current_account()
                .expect("read env current account")
                .expect("env current account");
            assert_eq!(current.source, NostrAccountSource::Env);
            assert_eq!(
                current.npub,
                keys.public_key().to_bech32().expect("encode env npub")
            );
        });
    }

    #[test]
    fn query_filters_by_author_and_limit() {
        let service = in_memory_service();
        store_cached_test_events(&service);

        let events = service
            .query(NostrQuery {
                authors: Some(vec![String::from("npub-test-a")]),
                limit: Some(1),
                ..NostrQuery::default()
            })
            .expect("query cached events");

        assert_eq!(events.len(), 1);
        assert_eq!(events[0].id, "test-note-2");
    }

    #[test]
    fn count_uses_generic_query_filters() {
        let service = in_memory_service();
        store_cached_test_events(&service);

        let count = service
            .count(NostrQuery {
                authors: Some(vec![String::from("npub-test-a")]),
                since: Some(1_700_000_002),
                ..NostrQuery::default()
            })
            .expect("count cached events");

        assert_eq!(count, 1);
    }

    #[test]
    fn get_event_reads_cached_rows() {
        let service = in_memory_service();
        store_cached_test_events(&service);

        let event = service
            .get_event("test-note-3")
            .expect("read cached event")
            .expect("cached event");

        assert_eq!(event.kind, 1);
        assert_eq!(event.pubkey, "npub-test-b");
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
                root_event_id: None,
                reply_to_event_id: None,
                references: Vec::new(),
                public_keys: Vec::new(),
            },
            NostrEvent {
                content: String::from("profile-v2"),
                created_at: 1_700_000_200,
                id: String::from("profile-2"),
                kind: 0,
                pubkey: String::from("npub-feed-a"),
                identifier: None,
                root_event_id: None,
                reply_to_event_id: None,
                references: Vec::new(),
                public_keys: Vec::new(),
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
    fn query_filters_by_reply_to_event_id() {
        let service = in_memory_service();
        store_cached_test_events(&service);
        service
            .store_event(&NostrEvent {
                content: String::from("first reply"),
                created_at: 1_700_000_300,
                id: String::from("reply-1"),
                kind: 1,
                pubkey: String::from("npub-test-a"),
                identifier: None,
                root_event_id: Some(String::from("test-note-1")),
                reply_to_event_id: Some(String::from("test-note-1")),
                references: vec![NostrEventReference {
                    event_id: String::from("test-note-1"),
                    marker: Some(String::from("reply")),
                }],
                public_keys: Vec::new(),
            })
            .expect("store reply");
        service
            .store_event(&NostrEvent {
                content: String::from("other reply"),
                created_at: 1_700_000_301,
                id: String::from("reply-2"),
                kind: 1,
                pubkey: String::from("npub-test-b"),
                identifier: None,
                root_event_id: Some(String::from("test-note-2")),
                reply_to_event_id: Some(String::from("test-note-2")),
                references: vec![NostrEventReference {
                    event_id: String::from("test-note-2"),
                    marker: Some(String::from("reply")),
                }],
                public_keys: Vec::new(),
            })
            .expect("store other reply");

        let replies = service
            .query(NostrQuery {
                ids: None,
                authors: None,
                kinds: Some(vec![1]),
                referenced_ids: None,
                reply_to_ids: Some(vec![String::from("test-note-1")]),
                since: None,
                until: None,
                limit: None,
            })
            .expect("query replies");

        assert_eq!(replies.len(), 1);
        assert_eq!(replies[0].id, "reply-1");
        assert_eq!(replies[0].reply_to_event_id.as_deref(), Some("test-note-1"));
    }

    #[test]
    fn query_filters_by_referenced_event_id() {
        let service = in_memory_service();
        store_cached_test_events(&service);
        service
            .store_event(&NostrEvent {
                content: String::from("quoted reply"),
                created_at: 1_700_000_320,
                id: String::from("reply-ref-1"),
                kind: 1,
                pubkey: String::from("npub-test-c"),
                identifier: None,
                root_event_id: Some(String::from("test-note-1")),
                reply_to_event_id: Some(String::from("test-note-1")),
                references: vec![
                    NostrEventReference {
                        event_id: String::from("test-note-1"),
                        marker: Some(String::from("root")),
                    },
                    NostrEventReference {
                        event_id: String::from("test-note-2"),
                        marker: Some(String::from("reply")),
                    },
                ],
                public_keys: Vec::new(),
            })
            .expect("store referenced event");

        let referenced = service
            .query(NostrQuery {
                ids: None,
                authors: None,
                kinds: Some(vec![1]),
                referenced_ids: Some(vec![String::from("test-note-2")]),
                reply_to_ids: None,
                since: None,
                until: None,
                limit: None,
            })
            .expect("query referenced events");

        assert_eq!(referenced.len(), 1);
        assert_eq!(referenced[0].id, "reply-ref-1");
    }

    #[test]
    fn list_kind1_compatibility_stays_kind1_only() {
        let service = in_memory_service();
        store_cached_test_events(&service);
        service
            .store_event(&NostrEvent {
                content: String::from("{\"name\":\"shadow\"}"),
                created_at: 1_700_000_500,
                id: String::from("profile-metadata"),
                kind: 0,
                pubkey: String::from("npub-test-a"),
                identifier: None,
                root_event_id: None,
                reply_to_event_id: None,
                references: Vec::new(),
                public_keys: Vec::new(),
            })
            .expect("store non-kind1 event");

        let events = service
            .list_kind1(ListKind1Query::default())
            .expect("list kind1 events");

        assert!(events.iter().all(|event: &Kind1Event| event.kind == 1));
        assert_eq!(events.len(), 3);
    }

    #[test]
    fn initialize_leaves_new_cache_empty() {
        let service = in_memory_service();

        let events = service
            .query(NostrQuery::default())
            .expect("query initialized cache");

        assert!(events.is_empty());
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
    fn initialize_removes_legacy_demo_rows() {
        let service = in_memory_service();
        for id in LEGACY_DEMO_EVENT_IDS {
            service
                .store_event(&NostrEvent {
                    content: String::from("old demo row"),
                    created_at: 1_700_000_010,
                    id: String::from(id),
                    kind: 1,
                    pubkey: String::from("npub-demo"),
                    identifier: None,
                    root_event_id: None,
                    reply_to_event_id: None,
                    references: Vec::new(),
                    public_keys: Vec::new(),
                })
                .expect("store legacy demo row");
        }
        service
            .store_event(&NostrEvent {
                content: String::from("real cached row"),
                created_at: 1_700_000_011,
                id: String::from("real-note"),
                kind: 1,
                pubkey: String::from("npub-real"),
                identifier: None,
                root_event_id: None,
                reply_to_event_id: None,
                references: Vec::new(),
                public_keys: Vec::new(),
            })
            .expect("store real cached row");

        service.initialize().expect("reinitialize service");

        for id in LEGACY_DEMO_EVENT_IDS {
            assert!(
                service.get_event(id).expect("query demo row").is_none(),
                "expected {id} to be removed"
            );
        }
        assert!(
            service
                .get_event("real-note")
                .expect("query real row")
                .is_some(),
            "expected real row to remain"
        );
    }

    #[test]
    fn get_replaceable_rejects_non_replaceable_kinds() {
        let service = in_memory_service();

        let error = service
            .get_replaceable(NostrReplaceableQuery {
                kind: 1,
                pubkey: String::from("npub-test-a"),
                identifier: None,
            })
            .expect_err("non-replaceable kinds should fail");

        assert!(error.message().contains("replaceable"));
    }
}
