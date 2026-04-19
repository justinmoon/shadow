use std::collections::BTreeSet;
use std::time::Duration;

use nostr::prelude::{
    Event, EventId, Filter, Kind, PublicKey, RelayUrl, TagStandard, Timestamp, ToBech32,
};
use nostr_sdk::prelude::Client;

use shadow_sdk::services::nostr::{NostrEvent, NostrEventReference, NostrQuery, NostrSyncRequest};

const DEFAULT_SYNC_TIMEOUT_MS: u64 = 8_000;
const DEFAULT_SYNC_LIMIT: usize = 12;

#[derive(Debug)]
pub struct FetchedEventBatch {
    pub relay_urls: Vec<String>,
    pub events: Vec<NostrEvent>,
}

pub async fn sync_with_client(
    client: &Client,
    relay_registry: &mut BTreeSet<String>,
    request: NostrSyncRequest,
) -> Result<FetchedEventBatch, String> {
    let filter = build_filter(&request.query)?;
    let relay_urls = normalize_relay_urls(request.relay_urls)?;
    ensure_relays(client, relay_registry, &relay_urls).await?;
    let timeout = Duration::from_millis(
        request
            .timeout_ms
            .filter(|timeout_ms| *timeout_ms > 0)
            .unwrap_or(DEFAULT_SYNC_TIMEOUT_MS),
    );

    let connect_output = client.try_connect(Duration::from_secs(4)).await;
    if connect_output.success.is_empty() {
        let mut failed_relays = connect_output
            .failed
            .iter()
            .map(|(relay_url, error)| format!("{relay_url} ({error})"))
            .collect::<Vec<_>>();
        failed_relays.sort();
        if failed_relays.is_empty() {
            return Err(String::from("nostr.sync could not connect to any relay"));
        }
        return Err(format!(
            "nostr.sync could not connect to any relay: {}",
            failed_relays.join(", ")
        ));
    }

    let events = client
        .fetch_events(filter, timeout)
        .await
        .map_err(|error| format!("nostr.sync fetch events: {error}"))?;

    let mut events = events
        .into_iter()
        .map(|event| {
            let npub = event
                .pubkey
                .to_bech32()
                .map_err(|error| format!("nostr.sync encode npub: {error}"))?;
            let references = extract_event_references(&event);
            let (root_event_id, reply_to_event_id) = derive_thread_links(&references);
            Ok(NostrEvent {
                content: event.content,
                created_at: event.created_at.as_secs(),
                id: event.id.to_string(),
                kind: event.kind.as_u16() as u32,
                pubkey: npub,
                identifier: event.tags.identifier().map(str::to_owned),
                root_event_id,
                reply_to_event_id,
                references,
            })
        })
        .collect::<Result<Vec<_>, String>>()?;
    events.sort_by(|left, right| {
        right
            .created_at
            .cmp(&left.created_at)
            .then_with(|| left.id.cmp(&right.id))
    });

    Ok(FetchedEventBatch { relay_urls, events })
}

fn build_filter(query: &NostrQuery) -> Result<Filter, String> {
    let mut filter = Filter::new();
    if query
        .reply_to_ids
        .as_ref()
        .is_some_and(|reply_to_ids| !reply_to_ids.is_empty())
    {
        return Err(String::from(
            "nostr.sync does not yet support reply-to filters; query the local cache instead",
        ));
    }
    if let Some(ids) = query.ids.as_ref().filter(|ids| !ids.is_empty()) {
        let ids = ids
            .iter()
            .map(|id| {
                EventId::parse(id.trim())
                    .map_err(|error| format!("nostr.sync invalid event id {id}: {error}"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        filter = filter.ids(ids);
    }
    if let Some(referenced_ids) = query
        .referenced_ids
        .as_ref()
        .filter(|referenced_ids| !referenced_ids.is_empty())
    {
        let referenced_ids = referenced_ids
            .iter()
            .map(|id| {
                EventId::parse(id.trim()).map_err(|error| {
                    format!("nostr.sync invalid referenced event id {id}: {error}")
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        filter = filter.events(referenced_ids);
    }
    if let Some(authors) = query.authors.as_ref().filter(|authors| !authors.is_empty()) {
        let authors = authors
            .iter()
            .map(|author| {
                PublicKey::parse(author.trim())
                    .map_err(|error| format!("nostr.sync invalid author {author}: {error}"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        filter = filter.authors(authors);
    }
    if let Some(kinds) = query.kinds.as_ref().filter(|kinds| !kinds.is_empty()) {
        let kinds = kinds
            .iter()
            .map(|kind| {
                u16::try_from(*kind)
                    .map(Kind::from)
                    .map_err(|_| format!("nostr.sync invalid kind {kind}: out of range"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        filter = filter.kinds(kinds);
    }
    if let Some(since) = query.since {
        filter = filter.since(Timestamp::from_secs(since));
    }
    if let Some(until) = query.until {
        filter = filter.until(Timestamp::from_secs(until));
    }
    filter = filter.limit(query.limit.unwrap_or(DEFAULT_SYNC_LIMIT));
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

async fn ensure_relays(
    client: &Client,
    relay_registry: &mut BTreeSet<String>,
    relay_urls: &[String],
) -> Result<(), String> {
    for relay_url in relay_urls.iter() {
        if relay_registry.contains(relay_url) {
            continue;
        }

        client
            .add_relay(relay_url)
            .await
            .map_err(|error| format!("nostr.sync add relay {relay_url}: {error}"))?;
        relay_registry.insert(relay_url.clone());
    }

    Ok(())
}

fn default_relay_urls() -> Vec<String> {
    vec![
        String::from("wss://relay.primal.net/"),
        String::from("wss://relay.damus.io/"),
    ]
}

fn extract_event_references(event: &Event) -> Vec<NostrEventReference> {
    event
        .tags
        .iter()
        .filter_map(|tag| match tag.as_standardized() {
            Some(TagStandard::Event {
                event_id, marker, ..
            }) => Some(NostrEventReference {
                event_id: event_id.to_string(),
                marker: marker.map(|marker| marker.to_string()),
            }),
            _ => None,
        })
        .collect()
}

fn derive_thread_links(references: &[NostrEventReference]) -> (Option<String>, Option<String>) {
    let explicit_root = references
        .iter()
        .find(|reference| reference.marker.as_deref() == Some("root"))
        .map(|reference| reference.event_id.clone());
    let explicit_reply = references
        .iter()
        .find(|reference| reference.marker.as_deref() == Some("reply"))
        .map(|reference| reference.event_id.clone());
    let reply_to_event_id = explicit_reply.or_else(|| {
        references
            .last()
            .map(|reference| reference.event_id.clone())
    });
    let root_event_id = explicit_root.or_else(|| {
        if references.len() > 1 {
            references
                .first()
                .map(|reference| reference.event_id.clone())
        } else {
            reply_to_event_id.clone()
        }
    });

    (root_event_id, reply_to_event_id)
}
