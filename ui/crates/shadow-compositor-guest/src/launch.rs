use std::{
    ffi::OsStr,
    io,
    process::{Child, Command},
};

use shadow_compositor_common::launch::{
    apply_env_assignments, first_env_value, runtime_dir_from_env_or,
};
use shadow_ui_core::{
    app::{find_app, AppId},
    control,
};

use crate::ShadowGuestCompositor;

pub fn launch_app(state: &mut ShadowGuestCompositor, app_id: AppId) -> io::Result<Child> {
    let Some(app) = find_app(app_id) else {
        return Err(io::Error::new(io::ErrorKind::NotFound, "unknown demo app"));
    };
    let runtime_bundle_path = std::env::var(app.runtime_bundle_env).map_err(|_| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!("missing runtime bundle env {}", app.runtime_bundle_env),
        )
    })?;

    let client_path = app_client_path();
    let mut command = Command::new(&client_path);
    configure_guest_client_command(&mut command, state.control_socket_path.as_os_str())?;
    command
        .env("SHADOW_BLITZ_APP_TITLE", app.window_title)
        .env("SHADOW_BLITZ_WAYLAND_APP_ID", app.wayland_app_id)
        .env("SHADOW_RUNTIME_APP_BUNDLE_PATH", runtime_bundle_path);

    state.spawn_wayland_command(command, &client_path)
}

pub fn spawn_client(state: &mut ShadowGuestCompositor) -> io::Result<Child> {
    let client_path = app_client_path();
    let mut command = Command::new(&client_path);
    configure_guest_client_command(&mut command, state.control_socket_path.as_os_str())?;
    state.spawn_wayland_command(command, &client_path)
}

fn app_client_path() -> String {
    first_env_value(&["SHADOW_APP_CLIENT", "SHADOW_GUEST_CLIENT"])
        .unwrap_or_else(crate::default_guest_client_path)
}

fn configure_guest_client_command(
    command: &mut Command,
    control_socket_path: &OsStr,
) -> io::Result<()> {
    command
        .env(
            "XDG_RUNTIME_DIR",
            runtime_dir_from_env_or(|| "/data/local/tmp/shadow-runtime".into()),
        )
        .env(control::COMPOSITOR_CONTROL_ENV, control_socket_path);

    if let Some(value) = std::env::var_os("SHADOW_RUNTIME_HOST_BINARY_PATH") {
        command.env("SHADOW_RUNTIME_HOST_BINARY_PATH", value);
    }
    if let Some(value) = std::env::var("SHADOW_GUEST_CLIENT_ENV").ok() {
        apply_env_assignments(command, &value).map_err(io::Error::other)?;
    }
    if let Some(value) = std::env::var_os("SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE") {
        command.env("SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE", value);
    }
    if let Some(value) = std::env::var_os("SHADOW_GUEST_CLIENT_LINGER_MS") {
        command.env("SHADOW_GUEST_CLIENT_LINGER_MS", value);
    }

    Ok(())
}
