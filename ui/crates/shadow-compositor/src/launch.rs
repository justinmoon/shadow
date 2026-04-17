use std::{
    ffi::OsStr,
    io,
    path::Path,
    process::{Child, Command},
};

use shadow_compositor_common::launch::{first_env_value, sibling_binary_path, workspace_manifest};
use shadow_ui_core::{
    app::{find_app, AppId},
    control,
    scene::{APP_VIEWPORT_HEIGHT_PX, APP_VIEWPORT_WIDTH_PX},
};

const ALLOW_WORKSPACE_CARGO_LAUNCH_ENV: &str = "SHADOW_ALLOW_WORKSPACE_CARGO_LAUNCH";

pub fn launch_app(
    app_id: AppId,
    socket_name: &OsStr,
    control_socket_path: &OsStr,
) -> io::Result<Child> {
    let Some(app) = find_app(app_id) else {
        return Err(io::Error::new(io::ErrorKind::NotFound, "unknown demo app"));
    };
    let binary_name = app.binary_name;
    let runtime_bundle_path = std::env::var(app.runtime_bundle_env).map_err(|_| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!("missing runtime bundle env {}", app.runtime_bundle_env),
        )
    })?;

    let mut command = if let Some(explicit) =
        first_env_value(&["SHADOW_APP_CLIENT", "SHADOW_DEMO_CLIENT"])
    {
        Command::new(explicit)
    } else if let Some(sibling) = sibling_binary_path(binary_name) {
        if sibling.exists() {
            Command::new(sibling)
        } else if std::env::var_os(ALLOW_WORKSPACE_CARGO_LAUNCH_ENV).is_some() {
            let manifest = workspace_manifest().ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    "workspace cargo launch enabled but no workspace manifest was found",
                )
            })?;
            let mut command = Command::new("cargo");
            command.args([
                "run",
                "--manifest-path",
                manifest.to_string_lossy().as_ref(),
                "-p",
                binary_name,
            ]);
            if binary_name == "shadow-blitz-demo" {
                command.args(["--features", "host_system_fonts"]);
            }
            command
        } else {
            return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    format!(
                        "could not locate demo app binary {}; set SHADOW_APP_CLIENT or {} for dev cargo fallback",
                        binary_name, ALLOW_WORKSPACE_CARGO_LAUNCH_ENV
                    ),
                ));
        }
    } else {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "could not locate compositor executable path",
        ));
    };

    command
        .env("WAYLAND_DISPLAY", socket_name)
        .env(control::COMPOSITOR_CONTROL_ENV, control_socket_path)
        .env(
            control::APP_PLATFORM_CONTROL_ENV,
            control::platform_control_socket_path(
                Path::new(control_socket_path)
                    .parent()
                    .unwrap_or_else(|| Path::new(".")),
                app_id,
            ),
        )
        .env("SHADOW_BLITZ_APP_TITLE", app.window_title)
        .env("SHADOW_BLITZ_WAYLAND_APP_ID", app.wayland_app_id)
        .env("SHADOW_BLITZ_WAYLAND_INSTANCE_NAME", app.id.as_str())
        .env(
            "SHADOW_BLITZ_SURFACE_WIDTH",
            runtime_surface_width().to_string(),
        )
        .env(
            "SHADOW_BLITZ_SURFACE_HEIGHT",
            runtime_surface_height().to_string(),
        )
        .env("SHADOW_RUNTIME_APP_BUNDLE_PATH", runtime_bundle_path);

    command.spawn()
}

fn runtime_surface_width() -> u32 {
    APP_VIEWPORT_WIDTH_PX
}

fn runtime_surface_height() -> u32 {
    APP_VIEWPORT_HEIGHT_PX
}

#[cfg(test)]
mod tests {
    use super::{runtime_surface_height, runtime_surface_width};
    use shadow_ui_core::scene::{APP_VIEWPORT_HEIGHT_PX, APP_VIEWPORT_WIDTH_PX};

    #[test]
    fn runtime_surface_dimensions_match_shell_viewport() {
        assert_eq!(runtime_surface_width(), APP_VIEWPORT_WIDTH_PX);
        assert_eq!(runtime_surface_height(), APP_VIEWPORT_HEIGHT_PX);
    }
}
