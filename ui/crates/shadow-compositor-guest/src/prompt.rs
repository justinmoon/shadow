use std::{io, path::Path};

use shadow_compositor_common::control::{self, SystemPromptLogMessages};
use shadow_runtime_protocol::system_prompt_socket_path;
use smithay::reexports::calloop::EventLoop;

use crate::ShadowGuestCompositor;

pub fn init_listener(
    event_loop: &mut EventLoop<ShadowGuestCompositor>,
    control_socket_path: &Path,
) -> io::Result<std::path::PathBuf> {
    let runtime_dir = control_socket_path
        .parent()
        .unwrap_or_else(|| Path::new("."));
    control::init_system_prompt_listener(
        event_loop,
        system_prompt_socket_path(runtime_dir),
        SystemPromptLogMessages {
            accept_failed: "[shadow-guest-compositor] system-prompt-accept failed",
            decode_failed: "[shadow-guest-compositor] system-prompt-decode failed",
            response_failed: "[shadow-guest-compositor] system-prompt-response failed",
            request_failed: "[shadow-guest-compositor] system-prompt-request failed",
            read_failed: "[shadow-guest-compositor] system-prompt-read failed",
        },
        |state, request, stream| state.handle_system_prompt_request(request, stream),
    )
}
