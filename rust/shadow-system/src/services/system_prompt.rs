use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;

use shadow_runtime_protocol::{
    system_prompt_socket_path, SystemPromptRequest, SystemPromptResponse, SystemPromptSocketResponse,
};

const COMPOSITOR_CONTROL_ENV: &str = "SHADOW_COMPOSITOR_CONTROL";

pub fn request(request: &SystemPromptRequest) -> Result<SystemPromptResponse, String> {
    validate_request(request)?;
    let socket_path = prompt_socket_path().ok_or_else(|| {
        format!(
            "system prompt is unavailable: missing {COMPOSITOR_CONTROL_ENV} runtime context"
        )
    })?;
    let mut stream = UnixStream::connect(&socket_path)
        .map_err(|error| format!("system prompt connect {}: {error}", socket_path.display()))?;
    let encoded = serde_json::to_string(request)
        .map_err(|error| format!("system prompt encode request: {error}"))?;
    writeln!(stream, "{encoded}")
        .and_then(|_| stream.flush())
        .map_err(|error| format!("system prompt write request {}: {error}", socket_path.display()))?;
    stream
        .shutdown(std::net::Shutdown::Write)
        .map_err(|error| format!("system prompt shutdown write {}: {error}", socket_path.display()))?;

    let mut response_line = String::new();
    let mut reader = BufReader::new(stream);
    let bytes = reader
        .read_line(&mut response_line)
        .map_err(|error| format!("system prompt read response {}: {error}", socket_path.display()))?;
    if bytes == 0 {
        return Err(format!(
            "system prompt {} closed without a response",
            socket_path.display()
        ));
    }

    match serde_json::from_str::<SystemPromptSocketResponse>(response_line.trim_end())
        .map_err(|error| format!("system prompt decode response: {error}"))?
    {
        SystemPromptSocketResponse::Ok { payload } => Ok(payload),
        SystemPromptSocketResponse::Error { message } => Err(message),
    }
}

fn prompt_socket_path() -> Option<std::path::PathBuf> {
    let control_socket = std::env::var(COMPOSITOR_CONTROL_ENV)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())?;
    let runtime_dir = Path::new(&control_socket)
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())?;
    Some(system_prompt_socket_path(runtime_dir))
}

fn validate_request(request: &SystemPromptRequest) -> Result<(), String> {
    if request.source_app_id.trim().is_empty() {
        return Err(String::from("system prompt requires a non-empty source app id"));
    }
    if request.title.trim().is_empty() {
        return Err(String::from("system prompt requires a non-empty title"));
    }
    if request.message.trim().is_empty() {
        return Err(String::from("system prompt requires a non-empty message"));
    }
    if request.actions.is_empty() {
        return Err(String::from("system prompt requires at least one action"));
    }
    if request
        .actions
        .iter()
        .any(|action| action.id.trim().is_empty() || action.label.trim().is_empty())
    {
        return Err(String::from(
            "system prompt actions require non-empty ids and labels",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::validate_request;
    use shadow_runtime_protocol::{SystemPromptAction, SystemPromptActionStyle, SystemPromptRequest};

    #[test]
    fn validate_request_rejects_empty_actions() {
        let error = validate_request(&SystemPromptRequest {
            source_app_id: String::from("timeline"),
            source_app_title: None,
            title: String::from("Allow publish?"),
            message: String::from("Sign and publish."),
            detail_lines: Vec::new(),
            actions: Vec::new(),
        })
        .expect_err("empty actions should fail");

        assert!(error.contains("at least one action"));
    }

    #[test]
    fn validate_request_accepts_well_formed_prompt() {
        validate_request(&SystemPromptRequest {
            source_app_id: String::from("timeline"),
            source_app_title: Some(String::from("Timeline")),
            title: String::from("Allow publish?"),
            message: String::from("Sign and publish."),
            detail_lines: vec![String::from("Account: npub1test")],
            actions: vec![SystemPromptAction {
                id: String::from("allow_once"),
                label: String::from("Allow Once"),
                style: SystemPromptActionStyle::Default,
            }],
        })
        .expect("well formed prompt");
    }
}
