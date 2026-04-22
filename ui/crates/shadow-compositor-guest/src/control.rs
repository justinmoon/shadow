use std::{io, path::PathBuf};

use shadow_compositor_common::control::{self, ControlLogMessages};
use smithay::reexports::calloop::EventLoop;

use crate::ShadowGuestCompositor;

pub fn init_listener(
    event_loop: &mut EventLoop<ShadowGuestCompositor>,
    runtime_dir: PathBuf,
) -> io::Result<PathBuf> {
    std::fs::create_dir_all(&runtime_dir)?;
    control::init_control_listener(
        event_loop,
        control::control_socket_path(runtime_dir),
        ControlLogMessages {
            accept_failed: "[shadow-guest-compositor] control-accept failed",
            malformed_request: "[shadow-guest-compositor] ignoring malformed control request",
            response_failed: "[shadow-guest-compositor] control-response failed",
            request_failed: "[shadow-guest-compositor] control-request failed",
            read_failed: "[shadow-guest-compositor] control-read failed",
        },
        |state, request| state.handle_control_request(request),
    )
}
