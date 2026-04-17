use crate::app::{self, AppId};
use std::path::{Path, PathBuf};

#[cfg(unix)]
use std::{
    io::{self, Read, Write},
    os::unix::net::UnixStream,
};

pub const COMPOSITOR_CONTROL_ENV: &str = "SHADOW_COMPOSITOR_CONTROL";
pub const COMPOSITOR_CONTROL_SOCKET: &str = "shadow-control.sock";
pub const APP_PLATFORM_CONTROL_ENV: &str = "SHADOW_BLITZ_PLATFORM_CONTROL_SOCKET";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaAction {
    PlayPause,
    Play,
    Pause,
    Next,
    Previous,
}

impl MediaAction {
    pub const fn as_token(self) -> &'static str {
        match self {
            Self::PlayPause => "play-pause",
            Self::Play => "play",
            Self::Pause => "pause",
            Self::Next => "next",
            Self::Previous => "previous",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "play-pause" | "play_pause" => Some(Self::PlayPause),
            "play" => Some(Self::Play),
            "pause" => Some(Self::Pause),
            "next" => Some(Self::Next),
            "previous" => Some(Self::Previous),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ControlRequest {
    Launch { app_id: AppId },
    Tap { x: i32, y: i32 },
    Home,
    Switcher,
    Media { action: MediaAction },
    Snapshot { path: Option<String> },
    State,
}

impl ControlRequest {
    pub fn encode(&self) -> String {
        match self {
            Self::Launch { app_id } => format!("launch {}\n", app_id.as_str()),
            Self::Tap { x, y } => format!("tap {x} {y}\n"),
            Self::Home => "home\n".to_string(),
            Self::Switcher => "switcher\n".to_string(),
            Self::Media { action } => format!("media {}\n", action.as_token()),
            Self::Snapshot { path: Some(path) } => format!("snapshot {path}\n"),
            Self::Snapshot { path: None } => "snapshot\n".to_string(),
            Self::State => "state\n".to_string(),
        }
    }

    pub fn parse(input: &str) -> Option<Self> {
        let mut parts = input.split_whitespace();
        match (parts.next(), parts.next(), parts.next(), parts.next()) {
            (Some("launch"), Some(app_id), None, None) => Some(Self::Launch {
                app_id: app::find_app_by_str(app_id)?.id,
            }),
            (Some("tap"), Some(x), Some(y), None) => Some(Self::Tap {
                x: x.parse().ok()?,
                y: y.parse().ok()?,
            }),
            (Some("home"), None, None, None) => Some(Self::Home),
            (Some("switcher"), None, None, None) => Some(Self::Switcher),
            (Some("media"), Some(action), None, None) => Some(Self::Media {
                action: MediaAction::parse(action)?,
            }),
            (Some("snapshot"), None, None, None) => Some(Self::Snapshot { path: None }),
            (Some("snapshot"), Some(path), None, None) => Some(Self::Snapshot {
                path: Some(path.to_string()),
            }),
            (Some("state"), None, None, None) => Some(Self::State),
            _ => None,
        }
    }
}

#[cfg(unix)]
pub fn request(request: ControlRequest) -> io::Result<bool> {
    let Ok(socket_path) = std::env::var(COMPOSITOR_CONTROL_ENV) else {
        return Ok(false);
    };

    let mut stream = UnixStream::connect(socket_path)?;
    stream.write_all(request.encode().as_bytes())?;
    let _ = stream.shutdown(std::net::Shutdown::Write);
    Ok(true)
}

#[cfg(unix)]
pub fn request_response(request: ControlRequest) -> io::Result<Option<String>> {
    let Ok(socket_path) = std::env::var(COMPOSITOR_CONTROL_ENV) else {
        return Ok(None);
    };

    let mut stream = UnixStream::connect(socket_path)?;
    stream.write_all(request.encode().as_bytes())?;
    stream.shutdown(std::net::Shutdown::Write)?;

    let mut response = String::new();
    stream.read_to_string(&mut response)?;
    Ok(Some(response))
}

pub fn platform_control_socket_path(runtime_dir: &Path, app_id: AppId) -> PathBuf {
    runtime_dir.join(format!("shadow-{}-platform.sock", app_id.as_str()))
}

#[cfg(test)]
mod tests {
    use super::{ControlRequest, MediaAction};
    use crate::app::{COUNTER_APP_ID, PODCAST_APP_ID, TIMELINE_APP_ID};
    use std::path::PathBuf;

    #[test]
    fn launch_request_round_trips() {
        let request = ControlRequest::Launch {
            app_id: COUNTER_APP_ID,
        };

        assert_eq!(request.encode(), "launch counter\n");
        assert_eq!(ControlRequest::parse("launch counter"), Some(request));
    }

    #[test]
    fn timeline_launch_request_round_trips() {
        let request = ControlRequest::Launch {
            app_id: TIMELINE_APP_ID,
        };

        assert_eq!(request.encode(), "launch timeline\n");
        assert_eq!(ControlRequest::parse("launch timeline"), Some(request));
    }

    #[test]
    fn tap_request_round_trips() {
        let request = ControlRequest::Tap { x: 270, y: 768 };

        assert_eq!(request.encode(), "tap 270 768\n");
        assert_eq!(ControlRequest::parse("tap 270 768"), Some(request));
    }

    #[test]
    fn simple_requests_round_trip() {
        assert_eq!(ControlRequest::parse("home"), Some(ControlRequest::Home));
        assert_eq!(
            ControlRequest::parse("switcher"),
            Some(ControlRequest::Switcher)
        );
        assert_eq!(
            ControlRequest::parse("media play-pause"),
            Some(ControlRequest::Media {
                action: MediaAction::PlayPause
            })
        );
        assert_eq!(
            ControlRequest::parse("media previous"),
            Some(ControlRequest::Media {
                action: MediaAction::Previous
            })
        );
        assert_eq!(
            ControlRequest::parse("snapshot"),
            Some(ControlRequest::Snapshot { path: None })
        );
        assert_eq!(
            ControlRequest::parse("snapshot /data/local/tmp/frame.ppm"),
            Some(ControlRequest::Snapshot {
                path: Some("/data/local/tmp/frame.ppm".to_string())
            })
        );
        assert_eq!(ControlRequest::parse("state"), Some(ControlRequest::State));
    }

    #[test]
    fn platform_control_socket_path_uses_app_id() {
        let path = super::platform_control_socket_path(
            std::path::Path::new("/tmp/shadow-runtime"),
            PODCAST_APP_ID,
        );

        assert_eq!(
            path,
            PathBuf::from("/tmp/shadow-runtime/shadow-podcast-platform.sock")
        );
    }
}
