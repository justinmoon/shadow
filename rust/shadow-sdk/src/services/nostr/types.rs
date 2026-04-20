use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum NostrAccountSource {
    Generated,
    Imported,
    Env,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct NostrAccountSummary {
    pub npub: String,
    pub source: NostrAccountSource,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct NostrEventReference {
    #[serde(rename = "eventId")]
    pub event_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub marker: Option<String>,
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
    #[serde(skip_serializing_if = "Option::is_none", rename = "rootEventId")]
    pub root_event_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "replyToEventId")]
    pub reply_to_event_id: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub references: Vec<NostrEventReference>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct NostrQuery {
    pub ids: Option<Vec<String>>,
    pub authors: Option<Vec<String>>,
    pub kinds: Option<Vec<u32>>,
    #[serde(rename = "referencedIds")]
    pub referenced_ids: Option<Vec<String>>,
    #[serde(rename = "replyToIds")]
    pub reply_to_ids: Option<Vec<String>>,
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
pub struct NostrSyncRequest {
    #[serde(flatten)]
    pub query: NostrQuery,
    #[serde(rename = "relayUrls")]
    pub relay_urls: Option<Vec<String>>,
    #[serde(rename = "timeoutMs")]
    pub timeout_ms: Option<u64>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct NostrSyncReceipt {
    #[serde(rename = "relayUrls")]
    pub relay_urls: Vec<String>,
    #[serde(rename = "fetchedCount")]
    pub fetched_count: usize,
    #[serde(rename = "importedCount")]
    pub imported_count: usize,
}
