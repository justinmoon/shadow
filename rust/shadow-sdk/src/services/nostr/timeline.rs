use std::collections::{BTreeMap, BTreeSet};

use serde_json::Value;

use super::{
    get_event, get_replaceable, publish, query, sync, NostrError, NostrEvent,
    NostrHostError, NostrPublicKeyReference, NostrPublishReceipt, NostrPublishRequest,
    NostrQuery, NostrReplaceableQuery, NostrSyncRequest,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NostrHomeFeedSource {
    Following { count: usize },
    NoContacts,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NostrHomeFeedScope {
    pub authors: Option<Vec<String>>,
    pub source: NostrHomeFeedSource,
}

impl NostrHomeFeedScope {
    pub fn following(mut authors: Vec<String>) -> Self {
        authors.sort();
        authors.dedup();
        if authors.is_empty() {
            return Self::no_contacts();
        }
        let count = authors.len();
        Self {
            authors: Some(authors),
            source: NostrHomeFeedSource::Following { count },
        }
    }

    pub const fn no_contacts() -> Self {
        Self {
            authors: None,
            source: NostrHomeFeedSource::NoContacts,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NostrProfileSummary {
    pub about: Option<String>,
    pub display_name: Option<String>,
    pub metadata_event_id: Option<String>,
    pub nip05: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NostrThreadContext {
    pub parent: Option<NostrEvent>,
    pub replies: Vec<NostrEvent>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NostrHomeCacheState {
    pub feed_scope: NostrHomeFeedScope,
    pub notes: Vec<NostrEvent>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NostrExploreProfileEntry {
    pub latest_note_preview: String,
    pub note_count: usize,
    pub profile: NostrProfileSummary,
    pub pubkey: String,
    pub updated_at: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NostrExploreCacheState {
    pub notes: Vec<NostrEvent>,
    pub profiles: Vec<NostrExploreProfileEntry>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NostrProfileCacheState {
    pub summary: NostrProfileSummary,
    pub notes: Vec<NostrEvent>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NostrNoteCacheState {
    pub note: Option<NostrEvent>,
    pub profile: NostrProfileSummary,
    pub thread: NostrThreadContext,
}

#[derive(Debug, Clone)]
pub struct NostrHomeRefreshRequest {
    pub account_npub: String,
    pub limit: usize,
    pub relay_urls: Vec<String>,
}

#[derive(Debug)]
pub struct NostrHomeRefreshOutcome {
    pub feed_scope: NostrHomeFeedScope,
    pub fetched_count: usize,
    pub imported_count: usize,
    pub notes: Vec<NostrEvent>,
}

#[derive(Debug, Clone)]
pub struct NostrExploreSyncRequest {
    pub limit: usize,
    pub relay_urls: Vec<String>,
}

#[derive(Debug)]
pub struct NostrExploreSyncOutcome {
    pub fetched_count: usize,
    pub imported_count: usize,
}

#[derive(Debug, Clone)]
pub struct NostrThreadSyncRequest {
    pub note_id: String,
    pub parent_ids: Vec<String>,
    pub relay_urls: Vec<String>,
}

#[derive(Debug)]
pub struct NostrThreadSyncOutcome {
    pub fetched_count: usize,
    pub imported_count: usize,
}

#[derive(Debug, Clone)]
pub struct NostrContactListUpdateRequest {
    pub account_npub: String,
    pub action: NostrContactListUpdateAction,
    pub relay_urls: Vec<String>,
}

#[derive(Debug, Clone)]
pub enum NostrContactListUpdateAction {
    Add { npub: String },
    Remove { npub: String },
}

#[derive(Debug)]
pub struct NostrContactListUpdateOutcome {
    pub receipt: NostrPublishReceipt,
}

#[derive(Debug, Clone)]
pub struct NostrReplyPublishRequest {
    pub content: String,
    pub relay_urls: Vec<String>,
    pub reply_to_event_id: String,
    pub root_event_id: Option<String>,
}

#[derive(Debug)]
pub struct NostrReplyPublishOutcome {
    pub receipt: NostrPublishReceipt,
}

pub fn load_home_feed_scope_for_account(
    npub: impl AsRef<str>,
) -> Result<NostrHomeFeedScope, NostrError> {
    let Some(contact_list) = load_contact_list_event_for_account(npub.as_ref())? else {
        return Ok(NostrHomeFeedScope::no_contacts());
    };
    let mut authors = Vec::new();
    for reference in contact_list.public_keys {
        if authors.iter().all(|author| author != &reference.public_key) {
            authors.push(reference.public_key);
        }
    }
    if authors.is_empty() {
        Ok(NostrHomeFeedScope::no_contacts())
    } else {
        Ok(NostrHomeFeedScope::following(authors))
    }
}

pub fn load_cached_home_notes(
    limit: usize,
    feed_scope: &NostrHomeFeedScope,
) -> Result<Vec<NostrEvent>, NostrError> {
    let Some(authors) = feed_scope.authors.clone() else {
        return Ok(Vec::new());
    };
    query(NostrQuery {
        ids: None,
        authors: Some(authors),
        kinds: Some(vec![1]),
        referenced_ids: None,
        reply_to_ids: None,
        since: None,
        until: None,
        limit: Some(limit),
    })
}

pub fn load_home_cache_state_for_account(
    npub: impl AsRef<str>,
    limit: usize,
) -> Result<NostrHomeCacheState, NostrError> {
    let feed_scope = load_home_feed_scope_for_account(npub)?;
    let notes = load_cached_home_notes(limit, &feed_scope)?;
    Ok(NostrHomeCacheState { feed_scope, notes })
}

pub fn load_explore_notes(limit: usize) -> Result<Vec<NostrEvent>, NostrError> {
    query(NostrQuery {
        ids: None,
        authors: None,
        kinds: Some(vec![1]),
        referenced_ids: None,
        reply_to_ids: None,
        since: None,
        until: None,
        limit: Some(limit),
    })
}

pub fn load_explore_cache_state(limit: usize) -> Result<NostrExploreCacheState, NostrError> {
    let notes = load_explore_notes(limit)?;
    let profiles = build_explore_profile_entries(&notes)?;
    Ok(NostrExploreCacheState { notes, profiles })
}

pub fn load_contact_references_for_account(
    npub: impl AsRef<str>,
) -> Result<Vec<NostrPublicKeyReference>, NostrError> {
    Ok(load_contact_list_event_for_account(npub.as_ref())?
        .map(|event| event.public_keys)
        .unwrap_or_default())
}

pub fn load_profile_summary(pubkey: impl AsRef<str>) -> Result<NostrProfileSummary, NostrError> {
    let Some(event) = get_replaceable(NostrReplaceableQuery {
        kind: 0,
        pubkey: pubkey.as_ref().to_owned(),
        identifier: None,
    })?
    else {
        return Ok(NostrProfileSummary::default());
    };

    let Ok(metadata) = serde_json::from_str::<Value>(&event.content) else {
        return Ok(NostrProfileSummary {
            metadata_event_id: Some(event.id),
            ..NostrProfileSummary::default()
        });
    };

    Ok(NostrProfileSummary {
        about: metadata
            .get("about")
            .and_then(Value::as_str)
            .map(str::to_owned),
        display_name: metadata
            .get("display_name")
            .and_then(Value::as_str)
            .or_else(|| metadata.get("displayName").and_then(Value::as_str))
            .or_else(|| metadata.get("name").and_then(Value::as_str))
            .map(str::to_owned),
        metadata_event_id: Some(event.id),
        nip05: metadata
            .get("nip05")
            .and_then(Value::as_str)
            .map(str::to_owned),
    })
}

pub fn load_profile_cache_state(
    pubkey: impl AsRef<str>,
    limit: usize,
) -> Result<NostrProfileCacheState, NostrError> {
    let pubkey = pubkey.as_ref();
    let summary = load_profile_summary(pubkey)?;
    let notes = load_profile_notes(pubkey, limit)?;
    Ok(NostrProfileCacheState { summary, notes })
}

pub fn load_thread_context(note: &NostrEvent) -> Result<NostrThreadContext, NostrError> {
    let parent = note
        .reply_to_event_id
        .as_ref()
        .and_then(|event_id| get_event(event_id).ok().flatten());
    let replies = query(NostrQuery {
        ids: None,
        authors: None,
        kinds: Some(vec![1]),
        referenced_ids: None,
        reply_to_ids: Some(vec![note.id.clone()]),
        since: None,
        until: None,
        limit: Some(24),
    })?;

    Ok(NostrThreadContext { parent, replies })
}

pub fn load_note_cache_state(note_id: impl AsRef<str>) -> Result<NostrNoteCacheState, NostrError> {
    let Some(note) = get_event(note_id.as_ref())? else {
        return Ok(NostrNoteCacheState::default());
    };
    let profile = load_profile_summary(&note.pubkey)?;
    let thread = load_thread_context(&note)?;
    Ok(NostrNoteCacheState {
        note: Some(note),
        profile,
        thread,
    })
}

pub fn thread_parent_ids(note: &NostrEvent) -> Vec<String> {
    let mut parent_ids = Vec::new();
    if let Some(reply_to_event_id) = note.reply_to_event_id.as_ref() {
        parent_ids.push(reply_to_event_id.clone());
    }
    if let Some(root_event_id) = note.root_event_id.as_ref() {
        if !parent_ids.iter().any(|id| id == root_event_id) {
            parent_ids.push(root_event_id.clone());
        }
    }
    parent_ids
}

pub fn refresh_home_feed(
    request: NostrHomeRefreshRequest,
) -> Result<NostrHomeRefreshOutcome, NostrError> {
    let relay_urls = (!request.relay_urls.is_empty()).then_some(request.relay_urls.clone());
    let mut fetched_count = 0_usize;
    let mut imported_count = 0_usize;

    let account_receipt = sync(NostrSyncRequest {
        query: NostrQuery {
            ids: None,
            authors: Some(vec![request.account_npub.clone()]),
            kinds: Some(vec![0, 3]),
            referenced_ids: None,
            reply_to_ids: None,
            since: None,
            until: None,
            limit: Some(4),
        },
        relay_urls: relay_urls.clone(),
        timeout_ms: Some(8_000),
    })?;
    fetched_count += account_receipt.fetched_count;
    imported_count += account_receipt.imported_count;

    let feed_scope = load_home_feed_scope_for_account(&request.account_npub)?;
    if let Some(authors) = feed_scope.authors.clone() {
        let profile_receipt = sync(NostrSyncRequest {
            query: NostrQuery {
                ids: None,
                authors: Some(authors.clone()),
                kinds: Some(vec![0]),
                referenced_ids: None,
                reply_to_ids: None,
                since: None,
                until: None,
                limit: Some(authors.len().max(1)),
            },
            relay_urls: relay_urls.clone(),
            timeout_ms: Some(8_000),
        })?;
        fetched_count += profile_receipt.fetched_count;
        imported_count += profile_receipt.imported_count;

        let note_receipt = sync(NostrSyncRequest {
            query: NostrQuery {
                ids: None,
                authors: Some(authors),
                kinds: Some(vec![1]),
                referenced_ids: None,
                reply_to_ids: None,
                since: None,
                until: None,
                limit: Some(request.limit),
            },
            relay_urls,
            timeout_ms: Some(8_000),
        })?;
        fetched_count += note_receipt.fetched_count;
        imported_count += note_receipt.imported_count;
    }

    let notes = load_cached_home_notes(request.limit, &feed_scope)?;

    Ok(NostrHomeRefreshOutcome {
        feed_scope,
        fetched_count,
        imported_count,
        notes,
    })
}

pub fn sync_explore_feed(
    request: NostrExploreSyncRequest,
) -> Result<NostrExploreSyncOutcome, NostrError> {
    let relay_urls = (!request.relay_urls.is_empty()).then_some(request.relay_urls.clone());
    let note_receipt = sync(NostrSyncRequest {
        query: NostrQuery {
            ids: None,
            authors: None,
            kinds: Some(vec![1]),
            referenced_ids: None,
            reply_to_ids: None,
            since: None,
            until: None,
            limit: Some(request.limit),
        },
        relay_urls: relay_urls.clone(),
        timeout_ms: Some(8_000),
    })?;
    let notes = load_explore_notes(request.limit)?;
    let authors = notes
        .iter()
        .map(|note| note.pubkey.clone())
        .collect::<Vec<_>>();
    let mut fetched_count = note_receipt.fetched_count;
    let mut imported_count = note_receipt.imported_count;
    if !authors.is_empty() {
        let profile_receipt = sync(NostrSyncRequest {
            query: NostrQuery {
                ids: None,
                authors: Some(authors),
                kinds: Some(vec![0]),
                referenced_ids: None,
                reply_to_ids: None,
                since: None,
                until: None,
                limit: Some(request.limit),
            },
            relay_urls,
            timeout_ms: Some(8_000),
        })?;
        fetched_count += profile_receipt.fetched_count;
        imported_count += profile_receipt.imported_count;
    }

    Ok(NostrExploreSyncOutcome {
        fetched_count,
        imported_count,
    })
}

pub fn sync_thread(
    request: NostrThreadSyncRequest,
) -> Result<NostrThreadSyncOutcome, NostrError> {
    let mut fetched_count = 0_usize;
    let mut imported_count = 0_usize;
    let relay_urls = (!request.relay_urls.is_empty()).then_some(request.relay_urls.clone());

    if !request.parent_ids.is_empty() {
        let receipt = sync(NostrSyncRequest {
            query: NostrQuery {
                ids: Some(request.parent_ids.clone()),
                authors: None,
                kinds: Some(vec![1]),
                referenced_ids: None,
                reply_to_ids: None,
                since: None,
                until: None,
                limit: Some(request.parent_ids.len()),
            },
            relay_urls: relay_urls.clone(),
            timeout_ms: Some(8_000),
        })?;
        fetched_count += receipt.fetched_count;
        imported_count += receipt.imported_count;
    }

    let receipt = sync(NostrSyncRequest {
        query: NostrQuery {
            ids: None,
            authors: None,
            kinds: Some(vec![1]),
            referenced_ids: Some(vec![request.note_id]),
            reply_to_ids: None,
            since: None,
            until: None,
            limit: Some(48),
        },
        relay_urls,
        timeout_ms: Some(8_000),
    })?;
    fetched_count += receipt.fetched_count;
    imported_count += receipt.imported_count;

    Ok(NostrThreadSyncOutcome {
        fetched_count,
        imported_count,
    })
}

pub fn update_contact_list(
    request: NostrContactListUpdateRequest,
) -> Result<NostrContactListUpdateOutcome, NostrError> {
    let relay_urls = (!request.relay_urls.is_empty()).then_some(request.relay_urls.clone());
    let _ = sync(NostrSyncRequest {
        query: NostrQuery {
            ids: None,
            authors: Some(vec![request.account_npub.clone()]),
            kinds: Some(vec![3]),
            referenced_ids: None,
            reply_to_ids: None,
            since: None,
            until: None,
            limit: Some(1),
        },
        relay_urls: relay_urls.clone(),
        timeout_ms: Some(8_000),
    })
    .map_err(|error| NostrHostError::from(format!(
        "Could not refresh the latest contact list: {error}"
    )))
    .map_err(NostrError::from)?;

    let mut public_keys = load_contact_references_for_account(&request.account_npub)?;
    match request.action {
        NostrContactListUpdateAction::Add { npub } => {
            if public_keys
                .iter()
                .all(|reference| reference.public_key != npub)
            {
                public_keys.push(NostrPublicKeyReference {
                    public_key: npub,
                    relay_url: None,
                    alias: None,
                });
            }
        }
        NostrContactListUpdateAction::Remove { npub } => {
            public_keys.retain(|reference| reference.public_key != npub);
        }
    }

    let receipt = publish(NostrPublishRequest::ContactList {
        public_keys,
        relay_urls,
        timeout_ms: Some(12_000),
    })?;

    Ok(NostrContactListUpdateOutcome { receipt })
}

pub fn publish_reply(
    request: NostrReplyPublishRequest,
) -> Result<NostrReplyPublishOutcome, NostrError> {
    let receipt = publish(NostrPublishRequest::TextNote {
        content: request.content,
        root_event_id: request.root_event_id,
        reply_to_event_id: Some(request.reply_to_event_id),
        relay_urls: (!request.relay_urls.is_empty()).then_some(request.relay_urls),
        timeout_ms: Some(12_000),
    })?;

    Ok(NostrReplyPublishOutcome { receipt })
}

fn load_contact_list_event_for_account(
    npub: &str,
) -> Result<Option<NostrEvent>, NostrError> {
    get_replaceable(NostrReplaceableQuery {
        kind: 3,
        pubkey: npub.to_owned(),
        identifier: None,
    })
}

fn load_profile_notes(pubkey: &str, limit: usize) -> Result<Vec<NostrEvent>, NostrError> {
    query(NostrQuery {
        ids: None,
        authors: Some(vec![pubkey.to_owned()]),
        kinds: Some(vec![1]),
        referenced_ids: None,
        reply_to_ids: None,
        since: None,
        until: None,
        limit: Some(limit.max(24)),
    })
}

fn build_explore_profile_entries(
    notes: &[NostrEvent],
) -> Result<Vec<NostrExploreProfileEntry>, NostrError> {
    let mut note_counts = BTreeMap::new();
    for note in notes {
        *note_counts.entry(note.pubkey.clone()).or_insert(0_usize) += 1;
    }

    let mut seen = BTreeSet::new();
    let mut entries = Vec::new();
    for note in notes {
        if !seen.insert(note.pubkey.clone()) {
            continue;
        }
        entries.push(NostrExploreProfileEntry {
            latest_note_preview: note_preview(&note.content),
            note_count: *note_counts.get(&note.pubkey).unwrap_or(&1),
            profile: load_profile_summary(&note.pubkey).unwrap_or_default(),
            pubkey: note.pubkey.clone(),
            updated_at: note.created_at,
        });
    }
    Ok(entries)
}

fn note_preview(content: &str) -> String {
    let preview = content.lines().next().unwrap_or("").trim();
    if preview.is_empty() {
        String::from("No preview available.")
    } else {
        preview.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::{
        load_home_cache_state_for_account, load_home_feed_scope_for_account,
        load_note_cache_state, load_profile_summary, load_thread_context,
        thread_parent_ids, NostrHomeFeedSource,
    };
    use crate::services::nostr::{
        NostrEvent, SqliteNostrService, NOSTR_ACCOUNT_NSEC_ENV, NOSTR_ACCOUNT_PATH_ENV,
        NOSTR_DB_PATH_ENV, NOSTR_SERVICE_SOCKET_ENV,
    };
    use crate::services::test_env_lock;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn with_temp_db<T>(f: impl FnOnce() -> T) -> T {
        let _guard = test_env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time")
            .as_nanos();
        let db_path = std::env::temp_dir().join(format!("shadow-sdk-nostr-timeline-{timestamp}.sqlite"));
        let account_path =
            db_path.with_file_name(format!("shadow-sdk-nostr-timeline-{timestamp}.json"));
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

    #[test]
    fn home_feed_scope_uses_unique_public_keys_from_cached_contact_list() {
        with_temp_db(|| {
            let service = SqliteNostrService::from_env().expect("open sqlite service");
            service
                .store_event(&NostrEvent {
                    content: String::new(),
                    created_at: 1_700_000_000,
                    id: String::from("contact-list"),
                    kind: 3,
                    pubkey: String::from("npub-owner"),
                    identifier: None,
                    root_event_id: None,
                    reply_to_event_id: None,
                    references: Vec::new(),
                    public_keys: vec![
                        crate::services::nostr::NostrPublicKeyReference {
                            public_key: String::from("npub-follow-a"),
                            relay_url: None,
                            alias: None,
                        },
                        crate::services::nostr::NostrPublicKeyReference {
                            public_key: String::from("npub-follow-b"),
                            relay_url: None,
                            alias: None,
                        },
                        crate::services::nostr::NostrPublicKeyReference {
                            public_key: String::from("npub-follow-a"),
                            relay_url: None,
                            alias: None,
                        },
                    ],
                })
                .expect("store contact list");

            let scope =
                load_home_feed_scope_for_account("npub-owner").expect("load home feed scope");

            assert_eq!(scope.source, NostrHomeFeedSource::Following { count: 2 });
            assert_eq!(
                scope.authors,
                Some(vec![
                    String::from("npub-follow-a"),
                    String::from("npub-follow-b")
                ])
            );
        });
    }

    #[test]
    fn home_cache_state_reads_followed_notes() {
        with_temp_db(|| {
            let service = SqliteNostrService::from_env().expect("open sqlite service");
            service
                .store_event(&NostrEvent {
                    content: String::new(),
                    created_at: 1_700_000_000,
                    id: String::from("contact-list"),
                    kind: 3,
                    pubkey: String::from("npub-owner"),
                    identifier: None,
                    root_event_id: None,
                    reply_to_event_id: None,
                    references: Vec::new(),
                    public_keys: vec![crate::services::nostr::NostrPublicKeyReference {
                        public_key: String::from("npub-follow-a"),
                        relay_url: None,
                        alias: None,
                    }],
                })
                .expect("store contact list");
            service
                .store_event(&NostrEvent {
                    content: String::from("followed note"),
                    created_at: 1_700_000_001,
                    id: String::from("note-a"),
                    kind: 1,
                    pubkey: String::from("npub-follow-a"),
                    identifier: None,
                    root_event_id: None,
                    reply_to_event_id: None,
                    references: Vec::new(),
                    public_keys: Vec::new(),
                })
                .expect("store followed note");

            let cache =
                load_home_cache_state_for_account("npub-owner", 20).expect("load home cache");

            assert_eq!(cache.feed_scope.source, NostrHomeFeedSource::Following { count: 1 });
            assert_eq!(cache.notes.len(), 1);
            assert_eq!(cache.notes[0].id, "note-a");
        });
    }

    #[test]
    fn load_profile_summary_reads_metadata_json() {
        with_temp_db(|| {
            let service = SqliteNostrService::from_env().expect("open sqlite service");
            service
                .store_event(&NostrEvent {
                    content: String::from(
                        r#"{"display_name":"alice","about":"hello","nip05":"alice@example.com"}"#,
                    ),
                    created_at: 1_700_000_001,
                    id: String::from("metadata"),
                    kind: 0,
                    pubkey: String::from("npub-alice"),
                    identifier: None,
                    root_event_id: None,
                    reply_to_event_id: None,
                    references: Vec::new(),
                    public_keys: Vec::new(),
                })
                .expect("store metadata");

            let summary = load_profile_summary("npub-alice").expect("load profile summary");

            assert_eq!(summary.display_name.as_deref(), Some("alice"));
            assert_eq!(summary.about.as_deref(), Some("hello"));
            assert_eq!(summary.nip05.as_deref(), Some("alice@example.com"));
            assert_eq!(summary.metadata_event_id.as_deref(), Some("metadata"));
        });
    }

    #[test]
    fn load_thread_context_only_uses_direct_reply_ids() {
        with_temp_db(|| {
            let service = SqliteNostrService::from_env().expect("open sqlite service");
            service
                .store_event(&NostrEvent {
                    content: String::from("root"),
                    created_at: 1_700_000_000,
                    id: String::from("root"),
                    kind: 1,
                    pubkey: String::from("npub-owner"),
                    identifier: None,
                    root_event_id: None,
                    reply_to_event_id: None,
                    references: Vec::new(),
                    public_keys: Vec::new(),
                })
                .expect("store root");
            service
                .store_event(&NostrEvent {
                    content: String::from("reply"),
                    created_at: 1_700_000_001,
                    id: String::from("reply"),
                    kind: 1,
                    pubkey: String::from("npub-reply"),
                    identifier: None,
                    root_event_id: Some(String::from("root")),
                    reply_to_event_id: Some(String::from("root")),
                    references: Vec::new(),
                    public_keys: Vec::new(),
                })
                .expect("store direct reply");
            service
                .store_event(&NostrEvent {
                    content: String::from("mention only"),
                    created_at: 1_700_000_002,
                    id: String::from("mention"),
                    kind: 1,
                    pubkey: String::from("npub-mention"),
                    identifier: None,
                    root_event_id: Some(String::from("root")),
                    reply_to_event_id: None,
                    references: vec![crate::services::nostr::NostrEventReference {
                        event_id: String::from("root"),
                        marker: Some(String::from("mention")),
                    }],
                    public_keys: Vec::new(),
                })
                .expect("store mention");

            let context = load_thread_context(&NostrEvent {
                content: String::from("root"),
                created_at: 1_700_000_000,
                id: String::from("root"),
                kind: 1,
                pubkey: String::from("npub-owner"),
                identifier: None,
                root_event_id: None,
                reply_to_event_id: None,
                references: Vec::new(),
                public_keys: Vec::new(),
            })
            .expect("load thread context");

            assert_eq!(context.parent, None);
            assert_eq!(context.replies.len(), 1);
            assert_eq!(context.replies[0].id, "reply");
        });
    }

    #[test]
    fn load_note_cache_state_reads_note_profile_and_thread() {
        with_temp_db(|| {
            let service = SqliteNostrService::from_env().expect("open sqlite service");
            service
                .store_event(&NostrEvent {
                    content: String::from(r#"{"display_name":"alice"}"#),
                    created_at: 1_700_000_000,
                    id: String::from("metadata"),
                    kind: 0,
                    pubkey: String::from("npub-alice"),
                    identifier: None,
                    root_event_id: None,
                    reply_to_event_id: None,
                    references: Vec::new(),
                    public_keys: Vec::new(),
                })
                .expect("store metadata");
            service
                .store_event(&NostrEvent {
                    content: String::from("root"),
                    created_at: 1_700_000_001,
                    id: String::from("root"),
                    kind: 1,
                    pubkey: String::from("npub-alice"),
                    identifier: None,
                    root_event_id: None,
                    reply_to_event_id: None,
                    references: Vec::new(),
                    public_keys: Vec::new(),
                })
                .expect("store root");
            service
                .store_event(&NostrEvent {
                    content: String::from("reply"),
                    created_at: 1_700_000_002,
                    id: String::from("reply"),
                    kind: 1,
                    pubkey: String::from("npub-bob"),
                    identifier: None,
                    root_event_id: Some(String::from("root")),
                    reply_to_event_id: Some(String::from("root")),
                    references: Vec::new(),
                    public_keys: Vec::new(),
                })
                .expect("store reply");

            let cache = load_note_cache_state("root").expect("load note cache");

            assert_eq!(
                cache.note.as_ref().map(|note| note.id.as_str()),
                Some("root")
            );
            assert_eq!(cache.profile.display_name.as_deref(), Some("alice"));
            assert!(cache.thread.parent.is_none());
            assert_eq!(cache.thread.replies.len(), 1);
            assert_eq!(cache.thread.replies[0].id, "reply");
        });
    }

    #[test]
    fn thread_parent_ids_deduplicates_root_and_reply() {
        let ids = thread_parent_ids(&NostrEvent {
            content: String::new(),
            created_at: 1_700_000_000,
            id: String::from("note"),
            kind: 1,
            pubkey: String::from("npub-owner"),
            identifier: None,
            root_event_id: Some(String::from("root")),
            reply_to_event_id: Some(String::from("root")),
            references: Vec::new(),
            public_keys: Vec::new(),
        });

        assert_eq!(ids, vec![String::from("root")]);
    }
}
