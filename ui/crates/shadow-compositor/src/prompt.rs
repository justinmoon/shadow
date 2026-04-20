#![cfg(target_os = "linux")]

use std::{io, path::Path};

use shadow_compositor_common::control::{self, SystemPromptLogMessages};
use shadow_runtime_protocol::system_prompt_socket_path;
use smithay::reexports::calloop::EventLoop;

use crate::state::ShadowCompositor;

pub fn init_listener(
    event_loop: &mut EventLoop<ShadowCompositor>,
    control_socket_path: &Path,
) -> io::Result<std::path::PathBuf> {
    let runtime_dir = control_socket_path
        .parent()
        .unwrap_or_else(|| Path::new("."));
    control::init_system_prompt_listener(
        event_loop,
        system_prompt_socket_path(runtime_dir),
        SystemPromptLogMessages {
            accept_failed: "failed to accept system prompt request",
            decode_failed: "failed to decode system prompt request",
            response_failed: "failed to write system prompt response",
            request_failed: "failed to handle system prompt request",
            read_failed: "failed to read system prompt request",
        },
        |state, request, stream| state.handle_system_prompt_request(request, stream),
    )
}
