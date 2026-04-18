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

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeAudioControlAction {
    PlayPause,
    Play,
    Pause,
    Next,
    Previous,
    VolumeUp,
    VolumeDown,
}

impl RuntimeAudioControlAction {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::PlayPause => "play_pause",
            Self::Play => "play",
            Self::Pause => "pause",
            Self::Next => "next",
            Self::Previous => "previous",
            Self::VolumeUp => "volume_up",
            Self::VolumeDown => "volume_down",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value.trim() {
            "play-pause" | "play_pause" => Some(Self::PlayPause),
            "play" => Some(Self::Play),
            "pause" => Some(Self::Pause),
            "next" => Some(Self::Next),
            "previous" => Some(Self::Previous),
            "volume-up" | "volume_up" => Some(Self::VolumeUp),
            "volume-down" | "volume_down" => Some(Self::VolumeDown),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AppLifecycleState {
    Foreground,
    Background,
}

impl AppLifecycleState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Foreground => "foreground",
            Self::Background => "background",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value.trim() {
            "foreground" => Some(Self::Foreground),
            "background" => Some(Self::Background),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum AppPlatformRequest {
    Lifecycle { state: AppLifecycleState },
    Media { action: RuntimeAudioControlAction },
}

impl AppPlatformRequest {
    pub fn encode_line(self) -> String {
        match self {
            Self::Lifecycle { state } => format!("lifecycle {}\n", state.as_str()),
            Self::Media { action } => format!("media {}\n", action.as_str()),
        }
    }

    pub fn parse_line(input: &str) -> Option<Self> {
        let trimmed = input.trim();
        if let Some(state) = AppLifecycleState::parse(
            trimmed
                .strip_prefix("lifecycle ")
                .or_else(|| trimmed.strip_prefix("lifecycle\t"))
                .unwrap_or(""),
        ) {
            return Some(Self::Lifecycle { state });
        }
        if let Some(action) = RuntimeAudioControlAction::parse(
            trimmed
                .strip_prefix("media ")
                .or_else(|| trimmed.strip_prefix("media\t"))
                .unwrap_or(trimmed),
        ) {
            return Some(Self::Media { action });
        }
        None
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum SessionRequest {
    Render,
    RenderIfDirty,
    Dispatch { event: RuntimeDispatchEvent },
    PlatformAudioControl { action: RuntimeAudioControlAction },
    PlatformLifecycleChange { state: AppLifecycleState },
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
    use super::{
        AppLifecycleState, AppPlatformRequest, RuntimeAudioControlAction, RuntimeDocumentPayload,
    };

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

    #[test]
    fn app_platform_request_round_trips_lifecycle_lines() {
        assert_eq!(
            AppPlatformRequest::parse_line("lifecycle foreground"),
            Some(AppPlatformRequest::Lifecycle {
                state: AppLifecycleState::Foreground,
            })
        );
        assert_eq!(
            AppPlatformRequest::Lifecycle {
                state: AppLifecycleState::Background,
            }
            .encode_line(),
            "lifecycle background\n"
        );
    }

    #[test]
    fn app_platform_request_accepts_legacy_media_tokens() {
        assert_eq!(
            AppPlatformRequest::parse_line("play-pause"),
            Some(AppPlatformRequest::Media {
                action: RuntimeAudioControlAction::PlayPause,
            })
        );
        assert_eq!(
            AppPlatformRequest::parse_line("media volume-up"),
            Some(AppPlatformRequest::Media {
                action: RuntimeAudioControlAction::VolumeUp,
            })
        );
    }
}
