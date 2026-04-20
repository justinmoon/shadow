use std::collections::BTreeSet;
use std::time::Duration;

use nostr::nips::nip10::Marker;
use nostr::prelude::{EventBuilder, EventId, Kind, Tag, TagStandard};
use nostr_sdk::prelude::Client;

use shadow_sdk::services::nostr::{
    NostrPublishReceipt, NostrPublishRequest, NostrPublishedRelayFailure, SqliteNostrService,
};

use super::relay_sync;

const DEFAULT_PUBLISH_TIMEOUT_MS: u64 = 12_000;

pub async fn publish_with_client(
    client: &Client,
    relay_registry: &mut BTreeSet<String>,
    service: &SqliteNostrService,
    request: NostrPublishRequest,
) -> Result<NostrPublishReceipt, String> {
    let relay_urls = relay_sync::normalize_relay_urls(request.relay_urls.clone(), "nostr.publish")?;
    let timeout_ms = request
        .timeout_ms
        .filter(|timeout_ms| *timeout_ms > 0)
        .unwrap_or(DEFAULT_PUBLISH_TIMEOUT_MS);

    tokio::time::timeout(
        Duration::from_millis(timeout_ms),
        publish_with_client_inner(client, relay_registry, service, request, relay_urls.clone()),
    )
    .await
    .map_err(|_| format!("nostr.publish timed out after {timeout_ms}ms"))?
    .map(|mut receipt| {
        receipt.relay_urls = relay_urls;
        receipt
    })
}

async fn publish_with_client_inner(
    client: &Client,
    relay_registry: &mut BTreeSet<String>,
    service: &SqliteNostrService,
    request: NostrPublishRequest,
    relay_urls: Vec<String>,
) -> Result<NostrPublishReceipt, String> {
    let content = request.content.trim();
    if content.is_empty() {
        return Err(String::from("nostr.publish requires non-empty content"));
    }
    if request.kind != 1 {
        return Err(format!(
            "nostr.publish currently supports kind 1 only, got {}",
            request.kind
        ));
    }

    relay_sync::ensure_relays(client, relay_registry, &relay_urls).await?;
    let connect_output = client.try_connect(Duration::from_secs(6)).await;
    if connect_output.success.is_empty() {
        let failed_relays = normalize_failed_relays(&connect_output.failed);
        return Err(format!(
            "nostr.publish could not connect to any relay: {}",
            format_failed_relays(&failed_relays)
        ));
    }

    let keys = service
        .active_account_keys()
        .map_err(|error| error.to_string())?;
    let event = EventBuilder::new(Kind::TextNote, content.to_owned())
        .tags(build_reply_tags(
            request.reply_to_event_id.as_deref(),
            request.root_event_id.as_deref(),
        )?)
        .sign_with_keys(&keys)
        .map_err(|error| format!("nostr.publish sign event: {error}"))?;

    let output = client
        .send_event(&event)
        .await
        .map_err(|error| format!("nostr.publish send event: {error}"))?;
    let published_relays = output
        .success
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>();
    let failed_relays = normalize_failed_relays(&output.failed);
    if published_relays.is_empty() {
        return Err(format!(
            "nostr.publish was rejected by every relay: {}",
            format_failed_relays(&failed_relays)
        ));
    }

    let event = relay_sync::event_to_nostr_event(&event, "nostr.publish")?;
    service
        .store_event(&event)
        .map_err(|error| format!("nostr.publish store event {}: {error}", event.id))?;

    Ok(NostrPublishReceipt {
        event,
        relay_urls: Vec::new(),
        published_relays,
        failed_relays,
    })
}

fn build_reply_tags(
    reply_to_event_id: Option<&str>,
    root_event_id: Option<&str>,
) -> Result<Vec<Tag>, String> {
    let Some(reply_to_event_id) = normalize_id(reply_to_event_id).transpose()? else {
        return Ok(Vec::new());
    };
    let root_event_id = normalize_id(root_event_id).transpose()?;

    let mut tags = Vec::new();
    let root_id = root_event_id.unwrap_or(reply_to_event_id);
    if root_id != reply_to_event_id {
        tags.push(Tag::from_standardized_without_cell(TagStandard::Event {
            event_id: root_id,
            relay_url: None,
            marker: Some(Marker::Root),
            public_key: None,
            uppercase: false,
        }));
    }
    tags.push(Tag::from_standardized_without_cell(TagStandard::Event {
        event_id: reply_to_event_id,
        relay_url: None,
        marker: Some(Marker::Reply),
        public_key: None,
        uppercase: false,
    }));
    Ok(tags)
}

fn normalize_id(id: Option<&str>) -> Option<Result<EventId, String>> {
    id.map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| {
            EventId::parse(value)
                .map_err(|error| format!("nostr.publish invalid event id {value}: {error}"))
        })
}

fn normalize_failed_relays(
    failed_relays: &std::collections::HashMap<nostr::prelude::RelayUrl, String>,
) -> Vec<NostrPublishedRelayFailure> {
    let mut failed_relays = failed_relays
        .iter()
        .map(|(relay_url, error)| NostrPublishedRelayFailure {
            relay_url: relay_url.to_string(),
            error: error.clone(),
        })
        .collect::<Vec<_>>();
    failed_relays.sort_by(|left, right| left.relay_url.cmp(&right.relay_url));
    failed_relays
}

fn format_failed_relays(failed_relays: &[NostrPublishedRelayFailure]) -> String {
    failed_relays
        .iter()
        .map(|failed| format!("{} ({})", failed.relay_url, failed.error))
        .collect::<Vec<_>>()
        .join(", ")
}

#[cfg(test)]
mod tests {
    use super::build_reply_tags;
    use nostr::nips::nip10::Marker;
    use nostr::prelude::TagStandard;

    #[test]
    fn build_reply_tags_marks_root_and_reply() {
        let tags = build_reply_tags(
            Some("b3e392b11f5d4f28321cedd09303a748acfd0487aea5a7450b3481c60b6e4f87"),
            Some("a3e392b11f5d4f28321cedd09303a748acfd0487aea5a7450b3481c60b6e4f87"),
        )
        .expect("build reply tags");

        assert_eq!(tags.len(), 2);
        assert!(tags.iter().any(|tag| matches!(
            tag.as_standardized(),
            Some(TagStandard::Event {
                marker: Some(Marker::Root),
                ..
            })
        )));
        assert!(tags.iter().any(|tag| matches!(
            tag.as_standardized(),
            Some(TagStandard::Event {
                marker: Some(Marker::Reply),
                ..
            })
        )));
    }
}
