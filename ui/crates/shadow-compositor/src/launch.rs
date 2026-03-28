use std::{
    ffi::OsStr,
    io,
    path::{Path, PathBuf},
    process::{Child, Command},
};

use shadow_ui_core::{
    app::{binary_name_for, AppId},
    control,
};

pub fn launch_app(
    app_id: AppId,
    socket_name: &OsStr,
    control_socket_path: &OsStr,
) -> io::Result<Child> {
    let Some(binary_name) = binary_name_for(app_id) else {
        return Err(io::Error::new(io::ErrorKind::NotFound, "unknown demo app"));
    };

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
        .spawn()
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
