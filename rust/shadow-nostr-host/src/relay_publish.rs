use std::collections::BTreeSet;
use std::time::Duration;
use std::time::Instant;

use nostr::nips::nip10::Marker;
use nostr::prelude::{Contact, EventBuilder, EventId, Kind, PublicKey, RelayUrl, Tag, TagStandard};
use nostr_sdk::prelude::Client;

use shadow_sdk::services::nostr::{
    NostrPublicKeyReference, NostrPublishReceipt, NostrPublishRequest, NostrPublishedRelayFailure,
    SqliteNostrService,
};

use super::{relay_sync, signer};

const DEFAULT_PUBLISH_TIMEOUT_MS: u64 = 12_000;

pub async fn publish_with_client(
    client: &Client,
    relay_registry: &mut BTreeSet<String>,
    service: &SqliteNostrService,
    caller_app_id: Option<String>,
    caller_app_title: Option<String>,
    request: NostrPublishRequest,
) -> Result<NostrPublishReceipt, String> {
    let publish_start = Instant::now();
    let relay_urls =
        relay_sync::normalize_relay_urls(request.relay_urls().cloned(), "nostr.publish")?;
    let timeout_ms = request
        .timeout_ms()
        .filter(|timeout_ms| *timeout_ms > 0)
        .unwrap_or(DEFAULT_PUBLISH_TIMEOUT_MS);
    let request_kind = request.kind();
    let content_len = match &request {
        NostrPublishRequest::TextNote { content, .. } => content.trim().len(),
        NostrPublishRequest::ContactList { public_keys, .. } => public_keys.len(),
    };
    let caller_app_id_for_log = caller_app_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("<missing>")
        .to_owned();
    eprintln!(
        "runtime-nostr: publish-start app_id={caller_app_id_for_log} operation={} kind={} relays={} timeout_ms={} payload_size={}",
        request.operation_name(),
        request_kind,
        relay_urls.join(","),
        timeout_ms,
        content_len,
    );

    let result = tokio::time::timeout(
        Duration::from_millis(timeout_ms),
        publish_with_client_inner(
            client,
            relay_registry,
            service,
            caller_app_id,
            caller_app_title,
            request,
            relay_urls.clone(),
        ),
    )
    .await
    .map_err(|_| format!("nostr.publish timed out after {timeout_ms}ms"))?
    .map(|mut receipt| {
        receipt.relay_urls = relay_urls;
        receipt
    });
    match &result {
        Ok(receipt) => eprintln!(
            "runtime-nostr: publish-finish app_id={caller_app_id_for_log} elapsed_ms={} published_relays={} failed_relays={}",
            publish_start.elapsed().as_millis(),
            receipt.published_relays.len(),
            receipt.failed_relays.len(),
        ),
        Err(error) => eprintln!(
            "runtime-nostr: publish-finish app_id={caller_app_id_for_log} elapsed_ms={} error={error}",
            publish_start.elapsed().as_millis(),
        ),
    }
    result
}

async fn publish_with_client_inner(
    client: &Client,
    relay_registry: &mut BTreeSet<String>,
    service: &SqliteNostrService,
    caller_app_id: Option<String>,
    caller_app_title: Option<String>,
    request: NostrPublishRequest,
    relay_urls: Vec<String>,
) -> Result<NostrPublishReceipt, String> {
    let event_builder = build_event(&request)?;
    let approval_start = Instant::now();
    let caller_app_id = caller_app_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            String::from("nostr.publish requires caller app identity for signer approval")
        })?;
    signer::ensure_publish_approved(
        service,
        caller_app_id,
        caller_app_title.as_deref(),
        &request,
    )?;
    eprintln!(
        "runtime-nostr: publish-approval-done app_id={caller_app_id} elapsed_ms={}",
        approval_start.elapsed().as_millis(),
    );

    let connect_start = Instant::now();
    relay_sync::ensure_relays(client, relay_registry, &relay_urls).await?;
    let connected_relays =
        relay_sync::reconnect_requested_relays(client, &relay_urls, Duration::from_secs(6)).await?;
    eprintln!(
        "runtime-nostr: publish-connect-done app_id={caller_app_id} elapsed_ms={} success_relays={} connected_relays={}",
        connect_start.elapsed().as_millis(),
        connected_relays.len(),
        connected_relays.len(),
    );
    if connected_relays.is_empty() {
        let statuses = relay_sync::requested_relay_statuses(client, &relay_urls).await;
        if statuses.is_empty() {
            return Err(String::from("nostr.publish could not connect to any relay"));
        }
        return Err(format!(
            "nostr.publish could not connect to any relay: {}",
            statuses.join(", ")
        ));
    }

    let keys = service
        .active_account_keys()
        .map_err(|error| error.to_string())?;
    let event = event_builder
        .sign_with_keys(&keys)
        .map_err(|error| format!("nostr.publish sign event: {error}"))?;

    let send_start = Instant::now();
    let output = client
        .send_event_to(relay_urls.clone(), &event)
        .await
        .map_err(|error| format!("nostr.publish send event: {error}"))?;
    eprintln!(
        "runtime-nostr: publish-send-done app_id={caller_app_id} elapsed_ms={} success_relays={} failed_relays={}",
        send_start.elapsed().as_millis(),
        output.success.len(),
        output.failed.len(),
    );
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

fn build_event(request: &NostrPublishRequest) -> Result<EventBuilder, String> {
    match request {
        NostrPublishRequest::TextNote { .. } => build_text_note_event(request),
        NostrPublishRequest::ContactList { .. } => build_contact_list_event(request),
    }
}

fn build_text_note_event(request: &NostrPublishRequest) -> Result<EventBuilder, String> {
    let NostrPublishRequest::TextNote {
        content,
        reply_to_event_id,
        root_event_id,
        ..
    } = request
    else {
        return Err(String::from(
            "nostr.publish text note builder received the wrong request variant",
        ));
    };
    let content = content.trim();
    if content.is_empty() {
        return Err(String::from(
            "nostr.publish text_note requires non-empty content",
        ));
    }
    Ok(
        EventBuilder::new(Kind::TextNote, content.to_owned()).tags(build_reply_tags(
            reply_to_event_id.as_deref(),
            root_event_id.as_deref(),
        )?),
    )
}

fn build_contact_list_event(request: &NostrPublishRequest) -> Result<EventBuilder, String> {
    let NostrPublishRequest::ContactList { public_keys, .. } = request else {
        return Err(String::from(
            "nostr.publish contact list builder received the wrong request variant",
        ));
    };
    let contacts = normalize_contacts(public_keys)?;
    Ok(EventBuilder::contact_list(contacts))
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

fn normalize_contacts(public_keys: &[NostrPublicKeyReference]) -> Result<Vec<Contact>, String> {
    let mut contacts = Vec::new();
    let mut seen = BTreeSet::new();
    for reference in public_keys {
        let normalized = reference.public_key.trim();
        if normalized.is_empty() {
            continue;
        }
        let public_key = PublicKey::parse(normalized)
            .map_err(|error| format!("nostr.publish invalid public key {normalized}: {error}"))?;
        if !seen.insert(public_key.clone()) {
            continue;
        }
        let relay_url = reference
            .relay_url
            .as_ref()
            .map(|relay_url| {
                RelayUrl::parse(relay_url.trim()).map_err(|error| {
                    format!("nostr.publish invalid relay URL {relay_url}: {error}")
                })
            })
            .transpose()?;
        contacts.push(Contact {
            public_key,
            relay_url,
            alias: reference.alias.clone(),
        });
    }
    Ok(contacts)
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
    use super::{build_contact_list_event, build_reply_tags};
    use nostr::nips::nip10::Marker;
    use nostr::prelude::{Keys, Kind, TagStandard, ToBech32};
    use shadow_sdk::services::nostr::{NostrPublicKeyReference, NostrPublishRequest};

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

    #[test]
    fn build_contact_list_event_deduplicates_public_keys() {
        let followed = Keys::generate()
            .public_key()
            .to_bech32()
            .expect("encode followed npub");
        let builder = build_contact_list_event(&NostrPublishRequest::ContactList {
            public_keys: vec![
                NostrPublicKeyReference {
                    public_key: followed.clone(),
                    relay_url: None,
                    alias: None,
                },
                NostrPublicKeyReference {
                    public_key: followed,
                    relay_url: None,
                    alias: None,
                },
            ],
            relay_urls: None,
            timeout_ms: None,
        })
        .expect("build contact list");
        let author = Keys::generate();
        let event = builder.sign_with_keys(&author).expect("sign contact list");

        assert_eq!(event.kind, Kind::ContactList);
        assert_eq!(event.tags.public_keys().count(), 1);
    }
}
