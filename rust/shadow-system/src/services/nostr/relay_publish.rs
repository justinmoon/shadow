use std::time::Duration;

use nostr::prelude::{EventBuilder, Keys, RelayUrl, ToBech32};
use nostr_sdk::prelude::Client;
use qrcodegen::{QrCode, QrCodeEcc};
use serde::{Deserialize, Serialize};

const DEFAULT_PUBLISH_TIMEOUT_MS: u64 = 12_000;
const DEFAULT_PRIMAL_URL_PREFIX: &str = "https://primal.net/e/";

#[derive(Debug, Default, Deserialize)]
pub struct PublishEphemeralKind1Request {
    pub content: Option<String>,
    #[serde(rename = "relayUrls")]
    pub relay_urls: Option<Vec<String>>,
    #[serde(rename = "timeoutMs")]
    pub timeout_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct PublishedRelayFailure {
    #[serde(rename = "relayUrl")]
    pub relay_url: String,
    pub error: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct PublishedKind1Receipt {
    pub content: String,
    #[serde(rename = "id")]
    pub event_id_hex: String,
    #[serde(rename = "noteId")]
    pub note_id: String,
    #[serde(rename = "primalUrl")]
    pub primal_url: String,
    pub npub: String,
    #[serde(rename = "relayUrls")]
    pub relay_urls: Vec<String>,
    #[serde(rename = "publishedRelays")]
    pub published_relays: Vec<String>,
    #[serde(rename = "failedRelays")]
    pub failed_relays: Vec<PublishedRelayFailure>,
    #[serde(rename = "createdAt")]
    pub created_at: u64,
    #[serde(rename = "qrRows")]
    pub qr_rows: Vec<String>,
}

pub async fn publish_ephemeral_kind1(
    request: PublishEphemeralKind1Request,
) -> Result<PublishedKind1Receipt, String> {
    let content = request
        .content
        .as_deref()
        .map(str::trim)
        .filter(|content| !content.is_empty())
        .ok_or_else(|| String::from("nostr.publishEphemeralKind1 requires non-empty content"))?
        .to_owned();
    let relay_urls = normalize_relay_urls(request.relay_urls)?;
    let timeout_ms = request
        .timeout_ms
        .filter(|timeout_ms| *timeout_ms > 0)
        .unwrap_or(DEFAULT_PUBLISH_TIMEOUT_MS);

    tokio::time::timeout(Duration::from_millis(timeout_ms), async move {
        publish_ephemeral_kind1_inner(content, relay_urls).await
    })
    .await
    .map_err(|_| format!("nostr.publishEphemeralKind1 timed out after {timeout_ms}ms"))?
}

async fn publish_ephemeral_kind1_inner(
    content: String,
    relay_urls: Vec<String>,
) -> Result<PublishedKind1Receipt, String> {
    let keys = Keys::generate();
    let npub = keys
        .public_key()
        .to_bech32()
        .map_err(|error| format!("nostr.publishEphemeralKind1 encode npub: {error}"))?;

    let client = Client::new(keys.clone());
    for relay_url in relay_urls.iter() {
        client.add_relay(relay_url).await.map_err(|error| {
            format!("nostr.publishEphemeralKind1 add relay {relay_url}: {error}")
        })?;
    }

    let connect_output = client.try_connect(Duration::from_secs(6)).await;
    if connect_output.success.is_empty() {
        let failed_relays = normalize_failed_relays(&connect_output.failed);
        client.shutdown().await;
        return Err(format!(
            "nostr.publishEphemeralKind1 could not connect to any relay: {}",
            format_failed_relays(&failed_relays)
        ));
    }

    let event = EventBuilder::text_note(content.clone())
        .sign_with_keys(&keys)
        .map_err(|error| format!("nostr.publishEphemeralKind1 sign note: {error}"))?;

    let output = client
        .send_event(&event)
        .await
        .map_err(|error| format!("nostr.publishEphemeralKind1 send note: {error}"))?;
    client.shutdown().await;

    let published_relays = output
        .success
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>();
    let failed_relays = normalize_failed_relays(&output.failed);
    if published_relays.is_empty() {
        return Err(format!(
            "nostr.publishEphemeralKind1 was rejected by every relay: {}",
            format_failed_relays(&failed_relays)
        ));
    }

    let note_id = event
        .id
        .to_bech32()
        .map_err(|error| format!("nostr.publishEphemeralKind1 encode note id: {error}"))?;
    let primal_url = format!("{DEFAULT_PRIMAL_URL_PREFIX}{note_id}");
    let qr_rows = build_qr_rows(&primal_url)?;

    Ok(PublishedKind1Receipt {
        content,
        event_id_hex: event.id.to_string(),
        note_id,
        primal_url,
        npub,
        relay_urls,
        published_relays,
        failed_relays,
        created_at: event.created_at.as_secs(),
        qr_rows,
    })
}

fn normalize_relay_urls(relay_urls: Option<Vec<String>>) -> Result<Vec<String>, String> {
    let relay_urls = relay_urls.unwrap_or_else(default_relay_urls);
    if relay_urls.is_empty() {
        return Err(String::from(
            "nostr.publishEphemeralKind1 requires at least one relay URL",
        ));
    }

    relay_urls
        .into_iter()
        .map(|relay_url| {
            let relay_url = relay_url.trim().to_owned();
            if relay_url.is_empty() {
                return Err(String::from(
                    "nostr.publishEphemeralKind1 relay URL cannot be empty",
                ));
            }

            RelayUrl::parse(&relay_url)
                .map_err(|error| {
                    format!("nostr.publishEphemeralKind1 invalid relay URL {relay_url}: {error}")
                })
                .map(|relay_url| relay_url.to_string())
        })
        .collect()
}

fn normalize_failed_relays(
    failed_relays: &std::collections::HashMap<RelayUrl, String>,
) -> Vec<PublishedRelayFailure> {
    let mut failed_relays = failed_relays
        .iter()
        .map(|(relay_url, error)| PublishedRelayFailure {
            relay_url: relay_url.to_string(),
            error: error.clone(),
        })
        .collect::<Vec<_>>();
    failed_relays.sort_by(|left, right| left.relay_url.cmp(&right.relay_url));
    failed_relays
}

fn format_failed_relays(failed_relays: &[PublishedRelayFailure]) -> String {
    failed_relays
        .iter()
        .map(|failed| format!("{} ({})", failed.relay_url, failed.error))
        .collect::<Vec<_>>()
        .join(", ")
}

fn build_qr_rows(data: &str) -> Result<Vec<String>, String> {
    let qr = QrCode::encode_text(data, QrCodeEcc::Medium)
        .map_err(|error| format!("nostr.publishEphemeralKind1 generate QR: {error:?}"))?;
    let size = qr.size();
    let mut rows = Vec::with_capacity(size as usize);

    for y in 0..size {
        let mut row = String::with_capacity(size as usize);
        for x in 0..size {
            row.push(if qr.get_module(x, y) { '1' } else { '0' });
        }
        rows.push(row);
    }

    Ok(rows)
}

fn default_relay_urls() -> Vec<String> {
    vec![
        String::from("wss://relay.primal.net/"),
        String::from("wss://relay.damus.io/"),
    ]
}
