mod cache;
mod commands;

pub use cache::{
    load_cached_home_notes, load_contact_references_for_account, load_explore_cache_state,
    load_explore_notes, load_home_cache_state_for_account, load_home_feed_scope_for_account,
    load_note_cache_state, load_profile_cache_state, load_profile_summary, load_thread_context,
    thread_parent_ids,
};
pub use commands::{
    publish_note_or_reply, publish_reply, publish_text_note, refresh_home_feed, sync_explore_feed,
    sync_thread, update_contact_list,
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
    pub parent: Option<super::NostrEvent>,
    pub replies: Vec<super::NostrEvent>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NostrHomeCacheState {
    pub feed_scope: NostrHomeFeedScope,
    pub notes: Vec<super::NostrEvent>,
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
    pub notes: Vec<super::NostrEvent>,
    pub profiles: Vec<NostrExploreProfileEntry>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NostrProfileCacheState {
    pub summary: NostrProfileSummary,
    pub notes: Vec<super::NostrEvent>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NostrNoteCacheState {
    pub note: Option<super::NostrEvent>,
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
    pub notes: Vec<super::NostrEvent>,
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
    pub receipt: super::NostrPublishReceipt,
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
    pub receipt: super::NostrPublishReceipt,
}

#[derive(Debug, Clone)]
pub struct NostrTextNotePublishRequest {
    pub content: String,
    pub relay_urls: Vec<String>,
}

#[derive(Debug, Clone)]
pub enum NostrTimelinePublishRequest {
    Note(NostrTextNotePublishRequest),
    Reply(NostrReplyPublishRequest),
}

impl NostrTimelinePublishRequest {
    pub fn note(content: String, relay_urls: Vec<String>) -> Self {
        Self::Note(NostrTextNotePublishRequest {
            content,
            relay_urls,
        })
    }

    pub fn reply(
        content: String,
        relay_urls: Vec<String>,
        reply_to_event_id: String,
        root_event_id: Option<String>,
    ) -> Self {
        Self::Reply(NostrReplyPublishRequest {
            content,
            relay_urls,
            reply_to_event_id,
            root_event_id,
        })
    }

    pub fn content(&self) -> &str {
        match self {
            Self::Note(request) => &request.content,
            Self::Reply(request) => &request.content,
        }
    }

    pub fn is_note(&self) -> bool {
        matches!(self, Self::Note(_))
    }

    pub fn is_reply_to(&self, note_id: &str) -> bool {
        matches!(
            self,
            Self::Reply(request) if request.reply_to_event_id == note_id
        )
    }
}

pub fn run_refresh_home_feed_task(
    request: NostrHomeRefreshRequest,
) -> Result<NostrHomeRefreshOutcome, String> {
    refresh_home_feed(request).map_err(|error| error.to_string())
}

pub fn run_sync_explore_feed_task(
    request: NostrExploreSyncRequest,
) -> Result<NostrExploreSyncOutcome, String> {
    sync_explore_feed(request).map_err(|error| error.to_string())
}

pub fn run_sync_thread_task(
    request: NostrThreadSyncRequest,
) -> Result<NostrThreadSyncOutcome, String> {
    sync_thread(request).map_err(|error| error.to_string())
}

pub fn run_update_contact_list_task(
    request: NostrContactListUpdateRequest,
) -> Result<NostrContactListUpdateOutcome, String> {
    update_contact_list(request).map_err(|error| error.to_string())
}

#[derive(Debug)]
pub struct NostrTextNotePublishOutcome {
    pub receipt: super::NostrPublishReceipt,
}

#[cfg(test)]
mod tests;
