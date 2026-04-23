use std::env;
use std::fmt;
use std::fs;
use std::path::PathBuf;
#[cfg(test)]
use std::sync::{Mutex, OnceLock};

use copypasta::{ClipboardContext, ClipboardProvider};

pub const CLIPBOARD_MOCK_PATH_ENV: &str = "SHADOW_CLIPBOARD_MOCK_PATH";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClipboardErrorKind {
    Other,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClipboardError {
    kind: ClipboardErrorKind,
    message: String,
}

impl ClipboardError {
    fn other(message: impl Into<String>) -> Self {
        Self {
            kind: ClipboardErrorKind::Other,
            message: message.into(),
        }
    }

    pub fn kind(&self) -> ClipboardErrorKind {
        self.kind
    }
}

impl fmt::Display for ClipboardError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ClipboardError {}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClipboardWriteRequest {
    text: String,
}

impl ClipboardWriteRequest {
    pub fn new(text: impl Into<String>) -> Self {
        Self { text: text.into() }
    }
}

pub fn write_text(text: impl AsRef<str>) -> Result<(), ClipboardError> {
    let text = text.as_ref();

    if let Some(path) = mock_path() {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| {
                ClipboardError::other(format!(
                    "clipboard.writeText create mock dir {}: {error}",
                    parent.display()
                ))
            })?;
        }
        fs::write(&path, text).map_err(|error| {
            ClipboardError::other(format!(
                "clipboard.writeText write mock file {}: {error}",
                path.display()
            ))
        })?;
        return Ok(());
    }

    let mut clipboard = ClipboardContext::new().map_err(|error| {
        ClipboardError::other(format!("clipboard.writeText open provider: {error}"))
    })?;
    clipboard.set_contents(text.to_owned()).map_err(|error| {
        ClipboardError::other(format!("clipboard.writeText set contents: {error}"))
    })
}

pub fn run_write_text_task(request: ClipboardWriteRequest) -> Result<(), String> {
    write_text(request.text).map_err(|error| error.to_string())
}

fn mock_path() -> Option<PathBuf> {
    env::var(CLIPBOARD_MOCK_PATH_ENV)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

#[cfg(test)]
pub(crate) fn test_env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

#[cfg(test)]
mod tests {
    use super::{
        run_write_text_task, test_env_lock, write_text, ClipboardWriteRequest, CLIPBOARD_MOCK_PATH_ENV,
    };
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn write_text_writes_mock_file_when_env_is_set() {
        let _guard = test_env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time")
            .as_nanos();
        let mock_path = std::env::temp_dir().join(format!("shadow-clipboard-mock-{timestamp}.txt"));
        std::env::set_var(CLIPBOARD_MOCK_PATH_ENV, &mock_path);

        write_text("npub1shadowtest").expect("write clipboard text");

        let stored = fs::read_to_string(&mock_path).expect("read mock clipboard file");
        assert_eq!(stored, "npub1shadowtest");

        std::env::remove_var(CLIPBOARD_MOCK_PATH_ENV);
        let _ = fs::remove_file(&mock_path);
    }

    #[test]
    fn run_write_text_task_uses_shared_clipboard_task_surface() {
        let _guard = test_env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time")
            .as_nanos();
        let mock_path =
            std::env::temp_dir().join(format!("shadow-clipboard-task-mock-{timestamp}.txt"));
        std::env::set_var(CLIPBOARD_MOCK_PATH_ENV, &mock_path);

        run_write_text_task(ClipboardWriteRequest::new("npub1shadowtask"))
            .expect("write clipboard text through task helper");

        let stored = fs::read_to_string(&mock_path).expect("read mock clipboard file");
        assert_eq!(stored, "npub1shadowtask");

        std::env::remove_var(CLIPBOARD_MOCK_PATH_ENV);
        let _ = fs::remove_file(&mock_path);
    }
}
