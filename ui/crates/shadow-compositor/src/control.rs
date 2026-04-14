#![cfg(target_os = "linux")]

use std::{io, path::PathBuf};

use shadow_compositor_common::{
    control::{self, ControlLogMessages},
    launch,
};
use smithay::reexports::calloop::EventLoop;

use crate::state::ShadowCompositor;

pub fn init_listener(event_loop: &mut EventLoop<ShadowCompositor>) -> io::Result<PathBuf> {
    control::init_control_listener(
        event_loop,
        control::control_socket_path(launch::runtime_dir_from_env_or(std::env::temp_dir)),
        ControlLogMessages {
            accept_failed: "failed to accept control request",
            malformed_request: "ignoring malformed control request",
            response_failed: "failed to write control response",
            request_failed: "failed to handle control request",
            read_failed: "failed to read control request",
        },
        |state, request| state.handle_control_request(request),
    )
}
