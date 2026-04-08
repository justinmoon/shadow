use crate::app::{self, AppId};

#[cfg(unix)]
use std::{
    io::{self, Read, Write},
    os::unix::net::UnixStream,
};

pub const COMPOSITOR_CONTROL_ENV: &str = "SHADOW_COMPOSITOR_CONTROL";
pub const COMPOSITOR_CONTROL_SOCKET: &str = "shadow-control.sock";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ControlRequest {
    Launch { app_id: AppId },
    Tap { x: i32, y: i32 },
    Home,
    Switcher,
    State,
}

impl ControlRequest {
    pub fn encode(self) -> String {
        match self {
            Self::Launch { app_id } => format!("launch {}\n", app_id.as_str()),
            Self::Tap { x, y } => format!("tap {x} {y}\n"),
            Self::Home => "home\n".to_string(),
            Self::Switcher => "switcher\n".to_string(),
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

#[cfg(test)]
mod tests {
    use super::ControlRequest;
    use crate::app::{COUNTER_APP_ID, TIMELINE_APP_ID};

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
        assert_eq!(ControlRequest::parse("state"), Some(ControlRequest::State));
    }
}
