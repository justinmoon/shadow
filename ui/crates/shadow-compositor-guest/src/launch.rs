use std::{
    ffi::OsStr,
    io,
    path::Path,
    process::{Child, Command},
};

use shadow_compositor_common::launch::first_env_value;
use shadow_ui_core::{
    app::{launch_spec, AppId},
    control,
};

use crate::ShadowGuestCompositor;

pub fn launch_app(state: &mut ShadowGuestCompositor, app_id: AppId) -> io::Result<Child> {
    let Some(app) = launch_spec(app_id) else {
        return Err(io::Error::new(io::ErrorKind::NotFound, "unknown demo app"));
    };
    let runtime_bundle_path = app
        .typescript_runtime()
        .map(|runtime| {
            std::env::var(runtime.bundle_env).map_err(|_| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("missing runtime bundle env {}", runtime.bundle_env),
                )
            })
        })
        .transpose()?;

    let client_path = first_env_value(&["SHADOW_APP_CLIENT", "SHADOW_GUEST_CLIENT"])
        .unwrap_or_else(|| state.client_config.app_client_path.clone());
    let mut command = Command::new(&client_path);
    for (key, value) in app.launch_env {
        command.env(key, value);
    }
    configure_guest_client_command(
        &mut command,
        &state.client_config,
        state.control_socket_path.as_os_str(),
    )?;
    command
        .env("SHADOW_APP_TITLE", app.window_title)
        .env("SHADOW_BLITZ_APP_TITLE", app.window_title)
        .env("SHADOW_APP_WAYLAND_APP_ID", app.wayland_app_id)
        .env("SHADOW_BLITZ_WAYLAND_APP_ID", app.wayland_app_id)
        .env("SHADOW_APP_WAYLAND_INSTANCE_NAME", app.id.as_str())
        .env("SHADOW_APP_LIFECYCLE_STATE", "foreground")
        .env(
            control::APP_PLATFORM_CONTROL_ENV,
            control::platform_control_socket_path(
                state
                    .control_socket_path
                    .parent()
                    .unwrap_or_else(|| Path::new(".")),
                app_id,
            ),
        )
        .env(
            control::LEGACY_APP_PLATFORM_CONTROL_ENV,
            control::platform_control_socket_path(
                state
                    .control_socket_path
                    .parent()
                    .unwrap_or_else(|| Path::new(".")),
                app_id,
            ),
        );
    if let Some(runtime_bundle_path) = runtime_bundle_path {
        command.env("SHADOW_RUNTIME_APP_BUNDLE_PATH", runtime_bundle_path);
    }
    apply_software_keyboard_policy(&mut command);

    state.spawn_wayland_command(command, &client_path)
}
pub fn spawn_client(state: &mut ShadowGuestCompositor) -> io::Result<Child> {
    let client_path = state.client_config.app_client_path.clone();
    let mut command = Command::new(&client_path);
    configure_guest_client_command(
        &mut command,
        &state.client_config,
        state.control_socket_path.as_os_str(),
    )?;
    state.spawn_wayland_command(command, &client_path)
}

fn apply_software_keyboard_policy(command: &mut Command) {
    let enabled = std::env::var("SHADOW_BLITZ_SOFTWARE_KEYBOARD")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| String::from("1"));
    command
        .env("SHADOW_GUEST_KEYBOARD_SEAT", "0")
        .env("SHADOW_BLITZ_SOFTWARE_KEYBOARD", enabled);
}

fn configure_guest_client_command(
    command: &mut Command,
    client_config: &crate::config::GuestClientConfig,
    control_socket_path: &OsStr,
) -> io::Result<()> {
    command
        .env("XDG_RUNTIME_DIR", &client_config.runtime_dir)
        .env(control::COMPOSITOR_CONTROL_ENV, control_socket_path);

    if let Some(value) = &client_config.system_binary_path {
        command.env("SHADOW_SYSTEM_BINARY_PATH", value);
    }
    for (key, value) in &client_config.env_assignments {
        command.env(key, value);
    }
    if client_config.exit_on_configure {
        command.env("SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE", "1");
    }
    if let Some(value) = client_config.linger_ms {
        command.env("SHADOW_GUEST_CLIENT_LINGER_MS", value.to_string());
    }

    Ok(())
}
