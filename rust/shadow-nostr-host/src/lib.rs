mod daemon;
mod relay_publish;
mod relay_sync;
mod signer;
mod system_prompt;

use std::path::PathBuf;

use deno_core::{extension, op2, Extension};
use deno_error::JsErrorBox;
use shadow_sdk::services::nostr::{
    self as sdk_nostr, Kind1Event, ListKind1Query, NostrAccountSummary, NostrEvent,
    NostrPublishReceipt, NostrPublishRequest, NostrQuery, NostrReplaceableQuery, NostrSyncReceipt,
    NostrSyncRequest,
};

#[op2]
#[serde]
fn op_runtime_nostr_current_account() -> Result<Option<NostrAccountSummary>, JsErrorBox> {
    ensure_nostr_service_running()?;
    sdk_nostr::current_account().map_err(to_js_error)
}

#[op2]
#[serde]
fn op_runtime_nostr_generate_account() -> Result<NostrAccountSummary, JsErrorBox> {
    ensure_nostr_service_running()?;
    sdk_nostr::generate_account().map_err(to_js_error)
}

#[op2]
#[serde]
fn op_runtime_nostr_import_account_nsec(
    #[string] nsec: String,
) -> Result<NostrAccountSummary, JsErrorBox> {
    ensure_nostr_service_running()?;
    sdk_nostr::import_account_nsec(nsec).map_err(to_js_error)
}

#[op2]
#[serde]
fn op_runtime_nostr_query(#[serde] query: NostrQuery) -> Result<Vec<NostrEvent>, JsErrorBox> {
    ensure_nostr_service_running()?;
    sdk_nostr::query(query).map_err(to_js_error)
}

#[op2]
#[serde]
fn op_runtime_nostr_count(#[serde] query: NostrQuery) -> Result<usize, JsErrorBox> {
    ensure_nostr_service_running()?;
    sdk_nostr::count(query).map_err(to_js_error)
}

#[op2]
#[serde]
fn op_runtime_nostr_get_event(#[string] id: String) -> Result<Option<NostrEvent>, JsErrorBox> {
    ensure_nostr_service_running()?;
    sdk_nostr::get_event(id).map_err(to_js_error)
}

#[op2]
#[serde]
fn op_runtime_nostr_get_replaceable(
    #[serde] query: NostrReplaceableQuery,
) -> Result<Option<NostrEvent>, JsErrorBox> {
    ensure_nostr_service_running()?;
    sdk_nostr::get_replaceable(query).map_err(to_js_error)
}

#[op2]
#[serde]
fn op_runtime_nostr_list_kind1(
    #[serde] query: ListKind1Query,
) -> Result<Vec<Kind1Event>, JsErrorBox> {
    ensure_nostr_service_running()?;
    sdk_nostr::list_kind1(query).map_err(to_js_error)
}

#[op2]
#[serde]
async fn op_runtime_nostr_sync(
    #[serde] request: NostrSyncRequest,
) -> Result<NostrSyncReceipt, JsErrorBox> {
    sync_nostr_request(request).await
}

#[op2]
#[serde]
async fn op_runtime_nostr_sync_kind1(
    #[serde] request: NostrSyncRequest,
) -> Result<NostrSyncReceipt, JsErrorBox> {
    let mut request = request;
    request.query.kinds = Some(vec![1]);
    sync_nostr_request(request).await
}

async fn sync_nostr_request(request: NostrSyncRequest) -> Result<NostrSyncReceipt, JsErrorBox> {
    tokio::task::spawn_blocking(move || {
        ensure_nostr_service_running()?;
        sdk_nostr::sync(request).map_err(to_js_error)
    })
    .await
    .map_err(|error| JsErrorBox::generic(format!("nostr.sync join blocking task: {error}")))?
}

#[op2]
#[serde]
async fn op_runtime_nostr_publish(
    #[serde] request: NostrPublishRequest,
) -> Result<NostrPublishReceipt, JsErrorBox> {
    tokio::task::spawn_blocking(move || {
        ensure_nostr_service_running()?;
        sdk_nostr::publish(request).map_err(to_js_error)
    })
    .await
    .map_err(|error| JsErrorBox::generic(format!("nostr.publish join blocking task: {error}")))?
}

extension!(
    shadow_system_nostr_extension,
    ops = [
        op_runtime_nostr_current_account,
        op_runtime_nostr_generate_account,
        op_runtime_nostr_import_account_nsec,
        op_runtime_nostr_query,
        op_runtime_nostr_count,
        op_runtime_nostr_get_event,
        op_runtime_nostr_get_replaceable,
        op_runtime_nostr_list_kind1,
        op_runtime_nostr_publish,
        op_runtime_nostr_sync,
        op_runtime_nostr_sync_kind1
    ],
);

pub fn init_extension() -> Extension {
    shadow_system_nostr_extension::init()
}

pub fn run_service(socket_path: PathBuf) -> Result<(), String> {
    daemon::run(socket_path)
}

fn ensure_nostr_service_running() -> Result<(), JsErrorBox> {
    sdk_nostr::ipc::ensure_service_running().map_err(|error| JsErrorBox::generic(error.to_string()))
}

fn to_js_error(error: sdk_nostr::NostrError) -> JsErrorBox {
    JsErrorBox::generic(error.to_string())
}

#[cfg(test)]
pub(crate) fn test_env_lock() -> &'static std::sync::Mutex<()> {
    static LOCK: std::sync::OnceLock<std::sync::Mutex<()>> = std::sync::OnceLock::new();
    LOCK.get_or_init(|| std::sync::Mutex::new(()))
}
