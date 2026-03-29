use std::{
    ffi::OsStr,
    io,
    path::{Path, PathBuf},
    process::{Child, Command},
};

use shadow_ui_core::{app, control};

pub fn launch_app(
    app_id: app::AppId,
    socket_name: &OsStr,
    control_socket_path: &OsStr,
) -> io::Result<Child> {
    let app = app::find_app(app_id).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            format!("unknown app id: {}", app_id.as_str()),
        )
    })?;
    let mut command = launch_command(app.binary_name, app.prefer_cargo_run, "SHADOW_APP_CLIENT")?;
    tracing::info!(
        app_id = app_id.as_str(),
        binary = app.binary_name,
        program = %command.get_program().to_string_lossy(),
        args = ?command.get_args().map(|arg| arg.to_string_lossy().into_owned()).collect::<Vec<_>>(),
        "shadow-compositor: spawning app"
    );
    command
        .env("WAYLAND_DISPLAY", socket_name)
        .env(control::COMPOSITOR_CONTROL_ENV, control_socket_path)
        .spawn()
}

fn sibling_binary_path(name: &str) -> Option<PathBuf> {
    let current = std::env::current_exe().ok()?;
    Some(current.with_file_name(name))
}

fn launch_command(
    binary_name: &str,
    prefer_cargo_run: bool,
    override_var: &str,
) -> io::Result<Command> {
    if let Ok(explicit) = std::env::var(override_var) {
        return Ok(Command::new(explicit));
    }

    if prefer_cargo_run {
        if let Some(manifest) = workspace_manifest() {
            let mut command = Command::new("cargo");
            command.args([
                "run",
                "--manifest-path",
                manifest.to_string_lossy().as_ref(),
                "-p",
                binary_name,
            ]);
            return Ok(command);
        }
    }

    if let Some(sibling) = sibling_binary_path(binary_name) {
        if sibling.exists() {
            return Ok(Command::new(sibling));
        }

        if let Some(manifest) = workspace_manifest() {
            let mut command = Command::new("cargo");
            command.args([
                "run",
                "--manifest-path",
                manifest.to_string_lossy().as_ref(),
                "-p",
                binary_name,
            ]);
            return Ok(command);
        }
    }

    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "could not locate requested binary or workspace manifest",
    ))
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

    roots
        .into_iter()
        .find_map(|root| find_manifest_upwards(&root))
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
