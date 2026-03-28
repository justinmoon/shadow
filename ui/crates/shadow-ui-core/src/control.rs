use crate::app::{self, AppId};

#[cfg(unix)]
use std::{
    io::{self, Write},
    os::unix::net::UnixStream,
};

pub const COMPOSITOR_CONTROL_ENV: &str = "SHADOW_COMPOSITOR_CONTROL";
pub const COMPOSITOR_CONTROL_SOCKET: &str = "shadow-control.sock";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ControlRequest {
    Launch { app_id: AppId },
    Home,
    Switcher,
}

impl ControlRequest {
    pub fn encode(self) -> String {
        match self {
            Self::Launch { app_id } => format!("launch {}\n", app_id.as_str()),
            Self::Home => "home\n".to_string(),
            Self::Switcher => "switcher\n".to_string(),
        }
    }

    pub fn parse(input: &str) -> Option<Self> {
        let mut parts = input.split_whitespace();
        match (parts.next(), parts.next(), parts.next()) {
            (Some("launch"), Some(app_id), None) => Some(Self::Launch {
                app_id: app::find_app_by_str(app_id)?.id,
            }),
            (Some("home"), None, None) => Some(Self::Home),
            (Some("switcher"), None, None) => Some(Self::Switcher),
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
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::ControlRequest;
    use crate::app::COUNTER_APP_ID;

    #[test]
    fn launch_request_round_trips() {
        let request = ControlRequest::Launch {
            app_id: COUNTER_APP_ID,
        };

        assert_eq!(request.encode(), "launch counter\n");
        assert_eq!(ControlRequest::parse("launch counter"), Some(request));
    }

    #[test]
    fn simple_requests_round_trip() {
        assert_eq!(ControlRequest::parse("home"), Some(ControlRequest::Home));
        assert_eq!(
            ControlRequest::parse("switcher"),
            Some(ControlRequest::Switcher)
        );
    }
}
