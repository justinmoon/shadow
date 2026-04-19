use deno_core::{extension, op2, Extension};
use deno_error::JsErrorBox;
use shadow_sdk::services::clipboard;

#[op2]
async fn op_runtime_clipboard_write_text(#[string] text: String) -> Result<(), JsErrorBox> {
    tokio::task::spawn_blocking(move || clipboard::write_text(text))
        .await
        .map_err(|error| JsErrorBox::generic(format!("clipboard.writeText join: {error}")))?
        .map_err(|error| JsErrorBox::generic(error.to_string()))
}

extension!(
    shadow_system_clipboard_extension,
    ops = [op_runtime_clipboard_write_text],
);

pub fn init_extension() -> Extension {
    shadow_system_clipboard_extension::init()
}
