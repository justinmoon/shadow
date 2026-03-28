#![cfg(target_os = "linux")]

use std::{
    io::{self, Read},
    os::unix::net::UnixListener,
    path::PathBuf,
};

use shadow_ui_core::control::ControlRequest;
use smithay::reexports::calloop::{generic::Generic, EventLoop, Interest, Mode, PostAction};

use crate::state::ShadowCompositor;

pub fn init_listener(event_loop: &mut EventLoop<ShadowCompositor>) -> io::Result<PathBuf> {
    let path = control_socket_path();
    if path.exists() {
        let _ = std::fs::remove_file(&path);
    }

    let listener = UnixListener::bind(&path)?;
    listener.set_nonblocking(true)?;

    event_loop
        .handle()
        .insert_source(
            Generic::new(listener, Interest::READ, Mode::Level),
            |_, listener, state| {
                loop {
                    let mut stream = match unsafe { listener.get_mut() }.accept() {
                        Ok((stream, _)) => stream,
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                        Err(error) => {
                            tracing::warn!("failed to accept control request: {error}");
                            break;
                        }
                    };

                    let mut request = String::new();
                    match stream.read_to_string(&mut request) {
                        Ok(_) => {
                            let Some(request) = ControlRequest::parse(&request) else {
                                tracing::warn!("ignoring malformed control request");
                                continue;
                            };
                            if let Err(error) = state.handle_control_request(request) {
                                tracing::warn!("failed to handle control request: {error}");
                            }
                        }
                        Err(error) => tracing::warn!("failed to read control request: {error}"),
                    }
                }

                Ok(PostAction::Continue)
            },
        )
        .map_err(|error| io::Error::other(error.to_string()))?;

    Ok(path)
}

fn control_socket_path() -> PathBuf {
    let runtime_dir = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    runtime_dir.join(shadow_ui_core::control::COMPOSITOR_CONTROL_SOCKET)
}
