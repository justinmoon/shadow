use std::time::Duration;

use nostr::prelude::{Filter, Kind, PublicKey, RelayUrl, Timestamp, ToBech32};
use nostr_sdk::prelude::Client;
use serde::{Deserialize, Serialize};

use crate::Kind1Event;

const DEFAULT_SYNC_TIMEOUT_MS: u64 = 8_000;
const DEFAULT_SYNC_LIMIT: usize = 12;

#[derive(Debug, Default, Deserialize)]
pub struct SyncKind1Request {
    #[serde(rename = "relayUrls")]
    pub relay_urls: Option<Vec<String>>,
    pub authors: Option<Vec<String>>,
    pub since: Option<u64>,
    pub until: Option<u64>,
    pub limit: Option<usize>,
    #[serde(rename = "timeoutMs")]
    pub timeout_ms: Option<u64>,
}

#[derive(Debug)]
pub struct FetchedKind1Batch {
    pub relay_urls: Vec<String>,
    pub events: Vec<Kind1Event>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SyncedKind1Receipt {
    #[serde(rename = "relayUrls")]
    pub relay_urls: Vec<String>,
    #[serde(rename = "fetchedCount")]
    pub fetched_count: usize,
    #[serde(rename = "importedCount")]
    pub imported_count: usize,
}

pub async fn sync_kind1(request: SyncKind1Request) -> Result<FetchedKind1Batch, String> {
    let filter = build_kind1_filter(&request)?;
    let relay_urls = normalize_relay_urls(request.relay_urls)?;
    let timeout = Duration::from_millis(
        request
            .timeout_ms
            .filter(|timeout_ms| *timeout_ms > 0)
            .unwrap_or(DEFAULT_SYNC_TIMEOUT_MS),
    );

    let client = Client::default();
    for relay_url in relay_urls.iter() {
        client
            .add_relay(relay_url)
            .await
            .map_err(|error| format!("nostr.syncKind1 add relay {relay_url}: {error}"))?;
    }

    let connect_output = client.try_connect(Duration::from_secs(4)).await;
    if connect_output.success.is_empty() {
        let mut failed_relays = connect_output
            .failed
            .iter()
            .map(|(relay_url, error)| format!("{relay_url} ({error})"))
            .collect::<Vec<_>>();
        failed_relays.sort();
        client.shutdown().await;
        if failed_relays.is_empty() {
            return Err(String::from(
                "nostr.syncKind1 could not connect to any relay",
            ));
        }
        return Err(format!(
            "nostr.syncKind1 could not connect to any relay: {}",
            failed_relays.join(", ")
        ));
    }

    let events = client
        .fetch_events(filter, timeout)
        .await
        .map_err(|error| format!("nostr.syncKind1 fetch events: {error}"))?;
    client.shutdown().await;

    let mut events = events
        .into_iter()
        .filter(|event| event.kind == Kind::TextNote)
        .map(|event| {
            let npub = event
                .pubkey
                .to_bech32()
                .map_err(|error| format!("nostr.syncKind1 encode npub: {error}"))?;
            Ok(Kind1Event {
                content: event.content,
                created_at: event.created_at.as_secs(),
                id: event.id.to_string(),
                kind: 1,
                pubkey: npub,
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    events.sort_by(|left, right| {
        right
            .created_at
            .cmp(&left.created_at)
            .then_with(|| left.id.cmp(&right.id))
    });

    Ok(FetchedKind1Batch { relay_urls, events })
}

fn build_kind1_filter(request: &SyncKind1Request) -> Result<Filter, String> {
    let mut filter = Filter::new().kind(Kind::TextNote);
    if let Some(authors) = request
        .authors
        .as_ref()
        .filter(|authors| !authors.is_empty())
    {
        let authors = authors
            .iter()
            .map(|author| {
                PublicKey::parse(author.trim())
                    .map_err(|error| format!("nostr.syncKind1 invalid author {author}: {error}"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        filter = filter.authors(authors);
    }
    if let Some(since) = request.since {
        filter = filter.since(Timestamp::from_secs(since));
    }
    if let Some(until) = request.until {
        filter = filter.until(Timestamp::from_secs(until));
    }
    filter = filter.limit(request.limit.unwrap_or(DEFAULT_SYNC_LIMIT));
    Ok(filter)
}

fn normalize_relay_urls(relay_urls: Option<Vec<String>>) -> Result<Vec<String>, String> {
    let relay_urls = relay_urls.unwrap_or_else(default_relay_urls);
    if relay_urls.is_empty() {
        return Err(String::from(
            "nostr.syncKind1 requires at least one relay URL",
        ));
    }

    relay_urls
        .into_iter()
        .map(|relay_url| {
            let relay_url = relay_url.trim().to_owned();
            if relay_url.is_empty() {
                return Err(String::from("nostr.syncKind1 relay URL cannot be empty"));
            }

            RelayUrl::parse(&relay_url)
                .map_err(|error| format!("nostr.syncKind1 invalid relay URL {relay_url}: {error}"))
                .map(|relay_url| relay_url.to_string())
        })
        .collect()
}

fn default_relay_urls() -> Vec<String> {
    vec![
        String::from("wss://relay.primal.net/"),
        String::from("wss://relay.damus.io/"),
    ]
}
