use serde::{Deserialize, Deserializer, Serialize};

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
pub struct NostrPublicKeyReference {
    #[serde(rename = "publicKey")]
    pub public_key: String,
    #[serde(skip_serializing_if = "Option::is_none", rename = "relayUrl")]
    pub relay_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub alias: Option<String>,
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
    #[serde(default, skip_serializing_if = "Vec::is_empty", rename = "publicKeys")]
    pub public_keys: Vec<NostrPublicKeyReference>,
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

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NostrPublishRequest {
    TextNote {
        content: String,
        #[serde(skip_serializing_if = "Option::is_none", rename = "rootEventId")]
        root_event_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none", rename = "replyToEventId")]
        reply_to_event_id: Option<String>,
        #[serde(rename = "relayUrls")]
        relay_urls: Option<Vec<String>>,
        #[serde(rename = "timeoutMs")]
        timeout_ms: Option<u64>,
    },
    ContactList {
        #[serde(rename = "publicKeys")]
        public_keys: Vec<NostrPublicKeyReference>,
        #[serde(rename = "relayUrls")]
        relay_urls: Option<Vec<String>>,
        #[serde(rename = "timeoutMs")]
        timeout_ms: Option<u64>,
    },
}

impl NostrPublishRequest {
    pub fn kind(&self) -> u32 {
        match self {
            Self::TextNote { .. } => 1,
            Self::ContactList { .. } => 3,
        }
    }

    pub fn operation_name(&self) -> &'static str {
        match self {
            Self::TextNote { .. } => "text_note",
            Self::ContactList { .. } => "contact_list",
        }
    }

    pub fn relay_urls(&self) -> Option<&Vec<String>> {
        match self {
            Self::TextNote { relay_urls, .. } | Self::ContactList { relay_urls, .. } => {
                relay_urls.as_ref()
            }
        }
    }

    pub fn timeout_ms(&self) -> Option<u64> {
        match self {
            Self::TextNote { timeout_ms, .. } | Self::ContactList { timeout_ms, .. } => *timeout_ms,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum TaggedNostrPublishRequest {
    TextNote {
        content: String,
        #[serde(skip_serializing_if = "Option::is_none", rename = "rootEventId")]
        root_event_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none", rename = "replyToEventId")]
        reply_to_event_id: Option<String>,
        #[serde(rename = "relayUrls")]
        relay_urls: Option<Vec<String>>,
        #[serde(rename = "timeoutMs")]
        timeout_ms: Option<u64>,
    },
    ContactList {
        #[serde(rename = "publicKeys")]
        public_keys: Vec<NostrPublicKeyReference>,
        #[serde(rename = "relayUrls")]
        relay_urls: Option<Vec<String>>,
        #[serde(rename = "timeoutMs")]
        timeout_ms: Option<u64>,
    },
}

#[derive(Debug, Deserialize)]
struct LegacyNostrPublishRequest {
    kind: u32,
    #[serde(default)]
    content: String,
    #[serde(default, rename = "rootEventId")]
    root_event_id: Option<String>,
    #[serde(default, rename = "replyToEventId")]
    reply_to_event_id: Option<String>,
    #[serde(default, rename = "publicKeys")]
    public_keys: Vec<NostrPublicKeyReference>,
    #[serde(default, rename = "relayUrls")]
    relay_urls: Option<Vec<String>>,
    #[serde(default, rename = "timeoutMs")]
    timeout_ms: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum NostrPublishRequestWire {
    Tagged(TaggedNostrPublishRequest),
    Legacy(LegacyNostrPublishRequest),
}

impl From<TaggedNostrPublishRequest> for NostrPublishRequest {
    fn from(value: TaggedNostrPublishRequest) -> Self {
        match value {
            TaggedNostrPublishRequest::TextNote {
                content,
                root_event_id,
                reply_to_event_id,
                relay_urls,
                timeout_ms,
            } => Self::TextNote {
                content,
                root_event_id,
                reply_to_event_id,
                relay_urls,
                timeout_ms,
            },
            TaggedNostrPublishRequest::ContactList {
                public_keys,
                relay_urls,
                timeout_ms,
            } => Self::ContactList {
                public_keys,
                relay_urls,
                timeout_ms,
            },
        }
    }
}

impl TryFrom<LegacyNostrPublishRequest> for NostrPublishRequest {
    type Error = String;

    fn try_from(value: LegacyNostrPublishRequest) -> Result<Self, Self::Error> {
        match value.kind {
            1 => Ok(Self::TextNote {
                content: value.content,
                root_event_id: value.root_event_id,
                reply_to_event_id: value.reply_to_event_id,
                relay_urls: value.relay_urls,
                timeout_ms: value.timeout_ms,
            }),
            3 => Ok(Self::ContactList {
                public_keys: value.public_keys,
                relay_urls: value.relay_urls,
                timeout_ms: value.timeout_ms,
            }),
            other => Err(format!(
                "nostr.publish legacy request currently supports kinds 1 and 3, got {other}"
            )),
        }
    }
}

impl<'de> Deserialize<'de> for NostrPublishRequest {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        match NostrPublishRequestWire::deserialize(deserializer)? {
            NostrPublishRequestWire::Tagged(request) => Ok(request.into()),
            NostrPublishRequestWire::Legacy(request) => {
                Self::try_from(request).map_err(serde::de::Error::custom)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{NostrPublicKeyReference, NostrPublishRequest};

    #[test]
    fn deserialize_legacy_text_note_publish_request() {
        let request: NostrPublishRequest = serde_json::from_str(
            r#"{
                "kind": 1,
                "content": "gm",
                "replyToEventId": "note-1",
                "timeoutMs": 8000
            }"#,
        )
        .expect("deserialize legacy text note publish request");

        assert_eq!(
            request,
            NostrPublishRequest::TextNote {
                content: String::from("gm"),
                root_event_id: None,
                reply_to_event_id: Some(String::from("note-1")),
                relay_urls: None,
                timeout_ms: Some(8_000),
            }
        );
    }

    #[test]
    fn deserialize_legacy_contact_list_publish_request() {
        let request: NostrPublishRequest = serde_json::from_str(
            r#"{
                "kind": 3,
                "content": "",
                "publicKeys": [{"publicKey": "npub1follow"}]
            }"#,
        )
        .expect("deserialize legacy contact list publish request");

        assert_eq!(
            request,
            NostrPublishRequest::ContactList {
                public_keys: vec![NostrPublicKeyReference {
                    public_key: String::from("npub1follow"),
                    relay_url: None,
                    alias: None,
                }],
                relay_urls: None,
                timeout_ms: None,
            }
        );
    }

    #[test]
    fn serialize_tagged_text_note_publish_request() {
        let request = NostrPublishRequest::TextNote {
            content: String::from("gm"),
            root_event_id: Some(String::from("root")),
            reply_to_event_id: Some(String::from("reply")),
            relay_urls: Some(vec![String::from("ws://relay.example")]),
            timeout_ms: Some(12_000),
        };

        let value = serde_json::to_value(&request).expect("serialize tagged text note");
        assert_eq!(value["type"], "text_note");
        assert_eq!(value["content"], "gm");
        assert_eq!(value["rootEventId"], "root");
        assert_eq!(value["replyToEventId"], "reply");
        assert_eq!(value["relayUrls"][0], "ws://relay.example");
        assert_eq!(value["timeoutMs"], 12_000);
    }

    #[test]
    fn serialize_tagged_contact_list_publish_request() {
        let request = NostrPublishRequest::ContactList {
            public_keys: vec![NostrPublicKeyReference {
                public_key: String::from("npub1test"),
                relay_url: Some(String::from("wss://relay.example")),
                alias: Some(String::from("test")),
            }],
            relay_urls: Some(vec![String::from("ws://relay.example")]),
            timeout_ms: Some(12_000),
        };

        let value = serde_json::to_value(&request).expect("serialize tagged contact list");
        assert_eq!(value["type"], "contact_list");
        assert_eq!(value["publicKeys"][0]["publicKey"], "npub1test");
        assert_eq!(value["publicKeys"][0]["relayUrl"], "wss://relay.example");
        assert_eq!(value["publicKeys"][0]["alias"], "test");
        assert_eq!(value["relayUrls"][0], "ws://relay.example");
        assert_eq!(value["timeoutMs"], 12_000);
    }
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct NostrPublishedRelayFailure {
    #[serde(rename = "relayUrl")]
    pub relay_url: String,
    pub error: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct NostrPublishReceipt {
    pub event: NostrEvent,
    #[serde(rename = "relayUrls")]
    pub relay_urls: Vec<String>,
    #[serde(rename = "publishedRelays")]
    pub published_relays: Vec<String>,
    #[serde(rename = "failedRelays")]
    pub failed_relays: Vec<NostrPublishedRelayFailure>,
}
