mod relay_publish;
mod relay_sync;

use deno_core::{extension, op2, Extension, OpState};
use deno_error::JsErrorBox;
use shadow_sdk::services::nostr::{
    Kind1Event, ListKind1Query, NostrEvent, NostrQuery, NostrReplaceableQuery, PublishKind1Request,
    SqliteNostrService,
};

use self::relay_publish::{PublishEphemeralKind1Request, PublishedKind1Receipt};
use self::relay_sync::{SyncKind1Request, SyncedKind1Receipt};

#[derive(Debug)]
struct NostrHostState {
    service: Result<SqliteNostrService, String>,
}

impl NostrHostState {
    fn from_env() -> Self {
        Self {
            service: SqliteNostrService::from_env().map_err(|error| error.to_string()),
        }
    }

    fn service(&self) -> Result<&SqliteNostrService, JsErrorBox> {
        self.service
            .as_ref()
            .map_err(|error| JsErrorBox::generic(error.clone()))
    }
}

#[op2]
#[serde]
fn op_runtime_nostr_query(
    state: &mut OpState,
    #[serde] query: NostrQuery,
) -> Result<Vec<NostrEvent>, JsErrorBox> {
    state
        .borrow::<NostrHostState>()
        .service()?
        .query(query)
        .map_err(|error| JsErrorBox::generic(error.to_string()))
}

#[op2]
#[serde]
fn op_runtime_nostr_count(
    state: &mut OpState,
    #[serde] query: NostrQuery,
) -> Result<usize, JsErrorBox> {
    state
        .borrow::<NostrHostState>()
        .service()?
        .count(query)
        .map_err(|error| JsErrorBox::generic(error.to_string()))
}

#[op2]
#[serde]
fn op_runtime_nostr_get_event(
    state: &mut OpState,
    #[string] id: String,
) -> Result<Option<NostrEvent>, JsErrorBox> {
    state
        .borrow::<NostrHostState>()
        .service()?
        .get_event(&id)
        .map_err(|error| JsErrorBox::generic(error.to_string()))
}

#[op2]
#[serde]
fn op_runtime_nostr_get_replaceable(
    state: &mut OpState,
    #[serde] query: NostrReplaceableQuery,
) -> Result<Option<NostrEvent>, JsErrorBox> {
    state
        .borrow::<NostrHostState>()
        .service()?
        .get_replaceable(query)
        .map_err(|error| JsErrorBox::generic(error.to_string()))
}

#[op2]
#[serde]
fn op_runtime_nostr_list_kind1(
    state: &mut OpState,
    #[serde] query: ListKind1Query,
) -> Result<Vec<Kind1Event>, JsErrorBox> {
    state
        .borrow::<NostrHostState>()
        .service()?
        .list_kind1(query)
        .map_err(|error| JsErrorBox::generic(error.to_string()))
}

#[op2]
#[serde]
fn op_runtime_nostr_publish_kind1(
    state: &mut OpState,
    #[serde] request: PublishKind1Request,
) -> Result<Kind1Event, JsErrorBox> {
    state
        .borrow::<NostrHostState>()
        .service()?
        .publish_kind1(request)
        .map_err(|error| JsErrorBox::generic(error.to_string()))
}

#[op2]
#[serde]
async fn op_runtime_nostr_sync_kind1(
    #[serde] request: SyncKind1Request,
) -> Result<SyncedKind1Receipt, JsErrorBox> {
    let fetched = relay_sync::sync_kind1(request)
        .await
        .map_err(JsErrorBox::generic)?;
    let service =
        SqliteNostrService::from_env().map_err(|error| JsErrorBox::generic(error.to_string()))?;
    let mut imported_count = 0_usize;
    for event in fetched.events.iter() {
        if service
            .store_kind1_event(event)
            .map_err(|error| JsErrorBox::generic(error.to_string()))?
        {
            imported_count += 1;
        }
    }

    Ok(SyncedKind1Receipt {
        relay_urls: fetched.relay_urls,
        fetched_count: fetched.events.len(),
        imported_count,
    })
}

#[op2]
#[serde]
async fn op_runtime_nostr_publish_ephemeral_kind1(
    #[serde] request: PublishEphemeralKind1Request,
) -> Result<PublishedKind1Receipt, JsErrorBox> {
    let published = relay_publish::publish_ephemeral_kind1(request)
        .await
        .map_err(JsErrorBox::generic)?;

    if let Ok(service) = SqliteNostrService::from_env() {
        let _ = service.store_event(&NostrEvent {
            content: published.content.clone(),
            created_at: published.created_at,
            id: published.event_id_hex.clone(),
            kind: 1,
            pubkey: published.npub.clone(),
            identifier: None,
        });
    }

    Ok(published)
}

extension!(
    shadow_system_nostr_extension,
    ops = [
        op_runtime_nostr_query,
        op_runtime_nostr_count,
        op_runtime_nostr_get_event,
        op_runtime_nostr_get_replaceable,
        op_runtime_nostr_list_kind1,
        op_runtime_nostr_publish_kind1,
        op_runtime_nostr_sync_kind1,
        op_runtime_nostr_publish_ephemeral_kind1
    ],
    state = |state| {
        state.put(NostrHostState::from_env());
    },
);

pub fn init_extension() -> Extension {
    shadow_system_nostr_extension::init()
}
