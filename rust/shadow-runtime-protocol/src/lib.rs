use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
pub struct RuntimeDocumentPayload {
    pub html: String,
    pub css: Option<String>,
    #[serde(default, rename = "textInput", skip_serializing_if = "Option::is_none")]
    pub text_input: Option<RuntimeTextInputPayload>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
pub struct RuntimeTextInputPayload {
    #[serde(rename = "targetId")]
    pub target_id: String,
    #[serde(default)]
    pub value: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selection: Option<RuntimeSelectionEvent>,
    #[serde(default, rename = "inputMode", skip_serializing_if = "Option::is_none")]
    pub input_mode: Option<String>,
    #[serde(default)]
    pub multiline: bool,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
pub struct RuntimeDispatchEvent {
    #[serde(rename = "targetId")]
    pub target_id: String,
    #[serde(rename = "type")]
    pub event_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub checked: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selection: Option<RuntimeSelectionEvent>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pointer: Option<RuntimePointerEvent>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keyboard: Option<RuntimeKeyboardEvent>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
pub struct RuntimeSelectionEvent {
    #[serde(rename = "start", skip_serializing_if = "Option::is_none")]
    pub start: Option<u32>,
    #[serde(rename = "end", skip_serializing_if = "Option::is_none")]
    pub end: Option<u32>,
    #[serde(rename = "direction", skip_serializing_if = "Option::is_none")]
    pub direction: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
pub struct RuntimePointerEvent {
    #[serde(rename = "clientX", skip_serializing_if = "Option::is_none")]
    pub client_x: Option<f32>,
    #[serde(rename = "clientY", skip_serializing_if = "Option::is_none")]
    pub client_y: Option<f32>,
    #[serde(rename = "isPrimary", skip_serializing_if = "Option::is_none")]
    pub is_primary: Option<bool>,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
pub struct RuntimeKeyboardEvent {
    #[serde(rename = "key", skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    #[serde(rename = "code", skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(rename = "altKey", skip_serializing_if = "Option::is_none")]
    pub alt_key: Option<bool>,
    #[serde(rename = "ctrlKey", skip_serializing_if = "Option::is_none")]
    pub ctrl_key: Option<bool>,
    #[serde(rename = "metaKey", skip_serializing_if = "Option::is_none")]
    pub meta_key: Option<bool>,
    #[serde(rename = "shiftKey", skip_serializing_if = "Option::is_none")]
    pub shift_key: Option<bool>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum SessionRequest {
    Render,
    RenderIfDirty,
    Dispatch { event: RuntimeDispatchEvent },
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum SessionResponse {
    Ok { payload: RuntimeDocumentPayload },
    NoUpdate,
    Error { message: String },
}

#[cfg(test)]
mod tests {
    use super::RuntimeDocumentPayload;

    #[test]
    fn runtime_document_payload_preserves_text_input() {
        let payload = serde_json::from_str::<RuntimeDocumentPayload>(
            r#"{
                "html":"<input data-shadow-id=\"draft\" />",
                "css":null,
                "textInput":{
                    "targetId":"draft",
                    "value":"gm",
                    "selection":{"start":2,"end":2,"direction":"none"},
                    "inputMode":"text",
                    "multiline":false
                }
            }"#,
        )
        .expect("decode payload");

        let text_input = payload.text_input.expect("text input payload");
        assert_eq!(text_input.target_id, "draft");
        assert_eq!(text_input.value, "gm");
        assert_eq!(text_input.input_mode.as_deref(), Some("text"));
        assert!(!text_input.multiline);
    }
}
