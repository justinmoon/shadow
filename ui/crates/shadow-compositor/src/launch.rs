use std::{
    ffi::OsStr,
    io,
    path::{Path, PathBuf},
    process::{Child, Command},
};

use shadow_ui_core::{
    app::{find_app, AppId},
    control,
    scene::{APP_VIEWPORT_HEIGHT, APP_VIEWPORT_WIDTH},
};

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

    let mut command = if let Ok(explicit) = std::env::var("SHADOW_APP_CLIENT") {
        Command::new(explicit)
    } else if let Ok(explicit) = std::env::var("SHADOW_DEMO_CLIENT") {
        Command::new(explicit)
    } else if let Some(sibling) = sibling_binary_path(binary_name) {
        if sibling.exists() {
            Command::new(sibling)
        } else if let Some(manifest) = workspace_manifest() {
            let mut command = Command::new("cargo");
            command.args([
                "run",
                "--manifest-path",
                manifest.to_string_lossy().as_ref(),
                "-p",
                binary_name,
            ]);
            command
        } else {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "could not locate demo app binary or workspace manifest",
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
        .env("SHADOW_BLITZ_APP_TITLE", app.window_title)
        .env("SHADOW_BLITZ_WAYLAND_APP_ID", app.wayland_app_id)
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

fn sibling_binary_path(name: &str) -> Option<PathBuf> {
    let current = std::env::current_exe().ok()?;
    Some(current.with_file_name(name))
}

fn workspace_manifest() -> Option<PathBuf> {
    let mut roots = Vec::new();
    roots.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")));
    if let Ok(current) = std::env::current_dir() {
        roots.push(current);
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            roots.push(parent.to_path_buf());
        }
    }

    for root in roots {
        if let Some(manifest) = find_manifest_upwards(&root) {
            return Some(manifest);
        }
    }

    None
}

fn find_manifest_upwards(start: &Path) -> Option<PathBuf> {
    for ancestor in start.ancestors() {
        let manifest = ancestor.join("Cargo.toml");
        if manifest.exists() {
            let contents = std::fs::read_to_string(&manifest).ok()?;
            if contents.contains("[workspace]") {
                return Some(manifest);
            }
        }
    }

    None
}

fn runtime_surface_width() -> u32 {
    APP_VIEWPORT_WIDTH.round() as u32
}

fn runtime_surface_height() -> u32 {
    APP_VIEWPORT_HEIGHT.round() as u32
}

#[cfg(test)]
mod tests {
    use super::{runtime_surface_height, runtime_surface_width};

    #[test]
    fn runtime_surface_dimensions_match_shell_viewport() {
        assert_eq!(runtime_surface_width(), 492);
        assert_eq!(runtime_surface_height(), 910);
    }
}
