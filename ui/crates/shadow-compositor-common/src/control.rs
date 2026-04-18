use std::{
    env,
    io::{self, Read, Write},
    os::unix::fs::PermissionsExt,
    os::unix::net::UnixListener,
    path::PathBuf,
};

use shadow_ui_core::control::{ControlRequest, COMPOSITOR_CONTROL_SOCKET};
use smithay::reexports::calloop::{generic::Generic, EventLoop, Interest, Mode, PostAction};

#[derive(Clone, Copy, Debug)]
pub struct ControlLogMessages {
    pub accept_failed: &'static str,
    pub malformed_request: &'static str,
    pub response_failed: &'static str,
    pub request_failed: &'static str,
    pub read_failed: &'static str,
}

fn parse_octal_mode_from_env(var: &str) -> io::Result<Option<u32>> {
    let Ok(raw_value) = env::var(var) else {
        return Ok(None);
    };

    let trimmed = raw_value.trim();
    let normalized = trimmed
        .strip_prefix("0o")
        .or_else(|| trimmed.strip_prefix("0O"))
        .or_else(|| trimmed.strip_prefix('0'))
        .filter(|value| !value.is_empty())
        .unwrap_or(trimmed);
    let mode = u32::from_str_radix(normalized, 8).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("invalid {var}={trimmed:?}: {error}"),
        )
    })?;
    Ok(Some(mode))
}

pub fn init_control_listener<State, F>(
    event_loop: &mut EventLoop<State>,
    path: PathBuf,
    log: ControlLogMessages,
    mut handle_request: F,
) -> io::Result<PathBuf>
where
    F: FnMut(&mut State, ControlRequest) -> io::Result<String> + 'static,
{
    if path.exists() {
        let _ = std::fs::remove_file(&path);
    }

    let listener = UnixListener::bind(&path)?;
    if let Some(mode) = parse_octal_mode_from_env("SHADOW_COMPOSITOR_CONTROL_SOCKET_MODE")? {
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode))?;
    }
    listener.set_nonblocking(true)?;

    event_loop
        .handle()
        .insert_source(
            Generic::new(listener, Interest::READ, Mode::Level),
            move |_, listener, state| {
                loop {
                    let mut stream = match unsafe { listener.get_mut() }.accept() {
                        Ok((stream, _)) => stream,
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                        Err(error) => {
                            tracing::warn!("{}: {error}", log.accept_failed);
                            break;
                        }
                    };

                    let mut request = String::new();
                    match stream.read_to_string(&mut request) {
                        Ok(_) => {
                            let Some(request) = ControlRequest::parse(&request) else {
                                tracing::warn!("{}", log.malformed_request);
                                continue;
                            };
                            match handle_request(state, request) {
                                Ok(response) => {
                                    if let Err(error) = stream.write_all(response.as_bytes()) {
                                        tracing::warn!("{}: {error}", log.response_failed);
                                    }
                                }
                                Err(error) => {
                                    let _ = stream.write_all(
                                        format!("error={}\n", error.to_string().replace('\n', " "))
                                            .as_bytes(),
                                    );
                                    tracing::warn!("{}: {error}", log.request_failed);
                                }
                            }
                        }
                        Err(error) => {
                            let _ = stream.write_all(
                                format!("error={}\n", error.to_string().replace('\n', " "))
                                    .as_bytes(),
                            );
                            tracing::warn!("{}: {error}", log.read_failed);
                        }
                    }
                }

                Ok(PostAction::Continue)
            },
        )
        .map_err(|error| io::Error::other(error.to_string()))?;

    Ok(path)
}

pub fn control_socket_path(runtime_dir: PathBuf) -> PathBuf {
    runtime_dir.join(COMPOSITOR_CONTROL_SOCKET)
}
