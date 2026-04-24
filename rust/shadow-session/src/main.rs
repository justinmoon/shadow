use std::env;
use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::process::{self, Command};
use std::thread;
use std::time::{Duration, Instant};

const GUEST_RUNTIME_CLIENT_BIN: &str = "/shadow-blitz-demo";
const GUEST_COMPOSITOR_LOADER_ENV: &str = "SHADOW_GUEST_COMPOSITOR_LOADER";
const GUEST_COMPOSITOR_LIBRARY_PATH_ENV: &str = "SHADOW_GUEST_COMPOSITOR_LIBRARY_PATH";

fn log_stdio(message: &str) {
    let line = format!("[shadow-session] {message}\n");
    let _ = std::io::stdout().write_all(line.as_bytes());
    let _ = std::io::stderr().write_all(line.as_bytes());
}

fn log_line(message: &str) {
    log_stdio(message);

    if let Ok(mut file) = OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = file.write_all(format!("<6>[shadow-session] {message}\n").as_bytes());
        let _ = file.flush();
    }
}

fn path_exists(path: &str) -> bool {
    let c_path = CString::new(path).expect("path cstring");
    unsafe { libc::access(c_path.as_ptr(), libc::F_OK) == 0 }
}

fn parse_octal_mode_from_env(var: &str, default: u32) -> u32 {
    let Ok(raw_value) = env::var(var) else {
        return default;
    };

    let trimmed = raw_value.trim();
    let normalized = trimmed
        .strip_prefix("0o")
        .or_else(|| trimmed.strip_prefix("0O"))
        .or_else(|| trimmed.strip_prefix('0'))
        .filter(|value| !value.is_empty())
        .unwrap_or(trimmed);

    match u32::from_str_radix(normalized, 8) {
        Ok(mode) => mode,
        Err(error) => {
            log_line(&format!(
                "invalid {var}={trimmed:?}: {error}; falling back to {default:o}"
            ));
            default
        }
    }
}

fn describe_path_state(path: &str) -> String {
    match fs::metadata(path) {
        Ok(metadata) => {
            if metadata.is_dir() {
                "directory present".into()
            } else {
                "file present".into()
            }
        }
        Err(error) => format!("{} ({:?})", error, error.kind()),
    }
}

fn log_dir_snapshot(path: &str) {
    match fs::read_dir(path) {
        Ok(entries) => {
            let mut names = Vec::new();
            for entry in entries.flatten().take(16) {
                names.push(entry.file_name().to_string_lossy().into_owned());
            }
            log_line(&format!("{path} entries: {}", names.join(", ")));
        }
        Err(error) => {
            log_line(&format!("failed to read {path}: {error}"));
        }
    }
}

fn wait_for_path(path: &str, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    let mut last_state = String::new();

    while Instant::now() < deadline {
        match fs::metadata(path) {
            Ok(_) => {
                log_line(&format!("path ready: {path}"));
                return true;
            }
            Err(error) => {
                let state = format!("waiting for {path}: {error} ({:?})", error.kind());
                if state != last_state {
                    log_line(&state);
                    last_state = state;
                }
            }
        }
        thread::sleep(Duration::from_millis(250));
    }

    log_line(&format!(
        "timed out waiting for {path}; final state: {}",
        describe_path_state(path)
    ));
    false
}

fn ensure_directory_mode(path: &str, mode: u32) -> Result<(), String> {
    fs::create_dir_all(path).map_err(|error| format!("create_dir_all({path}) failed: {error}"))?;

    match fs::set_permissions(path, fs::Permissions::from_mode(mode)) {
        Ok(()) => Ok(()),
        Err(error) => {
            let current_mode = fs::metadata(path)
                .map(|metadata| metadata.permissions().mode() & 0o777)
                .ok();
            if error.kind() == std::io::ErrorKind::PermissionDenied
                && current_mode == Some(mode & 0o777)
            {
                log_line(&format!(
                    "set_permissions({path}) denied but mode already {:o}; continuing",
                    mode & 0o777
                ));
                Ok(())
            } else {
                Err(format!("set_permissions({path}) failed: {error}"))
            }
        }
    }
}

fn run_command(mut command: Command, label: &str) -> ! {
    log_line(&format!("starting {label}"));
    match command.status() {
        Ok(status) => {
            log_line(&format!("{label} exited with {status}"));
            process::exit(status.code().unwrap_or(1));
        }
        Err(error) => {
            log_line(&format!("{label} launch failed: {error}"));
            process::exit(1);
        }
    }
}

fn build_compositor_command_with_loader(
    compositor_bin: &str,
    loader: Option<&str>,
    library_path: Option<&str>,
) -> Command {
    let Some(loader) = loader.filter(|value| !value.is_empty()) else {
        return Command::new(compositor_bin);
    };

    let mut command = Command::new(loader);
    if let Some(library_path) = library_path.filter(|value| !value.is_empty()) {
        command.arg("--library-path").arg(library_path);
    }
    command.arg(compositor_bin);
    command
}

fn build_compositor_command(compositor_bin: &str) -> Command {
    let loader = env::var(GUEST_COMPOSITOR_LOADER_ENV).ok();
    let library_path = env::var(GUEST_COMPOSITOR_LIBRARY_PATH_ENV).ok();
    build_compositor_command_with_loader(compositor_bin, loader.as_deref(), library_path.as_deref())
}

fn prepare_guest_runtime_dir() -> Result<&'static str, String> {
    let runtime_dir =
        env::var("SHADOW_RUNTIME_DIR").unwrap_or_else(|_| "/shadow-runtime".to_string());
    let runtime_dir_mode = parse_octal_mode_from_env("SHADOW_RUNTIME_DIR_MODE", 0o700);

    ensure_directory_mode(&runtime_dir, runtime_dir_mode)?;

    Ok(Box::leak(runtime_dir.into_boxed_str()))
}

fn detect_guest_ui_mode() -> Result<(), String> {
    match env::var("SHADOW_SESSION_MODE").ok().as_deref() {
        Some("guest-ui") => Ok(()),
        Some(other) => Err(format!("unknown SHADOW_SESSION_MODE={other}")),
        None if path_exists("/shadow-compositor-guest")
            && path_exists(GUEST_RUNTIME_CLIENT_BIN) =>
        {
            Ok(())
        }
        None => Err("could not detect a guest UI session".into()),
    }
}

fn run_guest_ui() -> ! {
    let drm_enabled = env::var_os("SHADOW_GUEST_COMPOSITOR_ENABLE_DRM").is_some();
    if drm_enabled {
        let found = wait_for_path("/dev/dri/card0", Duration::from_secs(180));
        if !found {
            log_dir_snapshot("/dev");
            log_dir_snapshot("/dev/dri");
            log_dir_snapshot("/dev/graphics");
        }
    }

    let runtime_dir = match prepare_guest_runtime_dir() {
        Ok(path) => path,
        Err(error) => {
            log_line(&error);
            process::exit(1);
        }
    };

    let compositor_bin = env::var("SHADOW_GUEST_COMPOSITOR_BIN")
        .unwrap_or_else(|_| "/shadow-compositor-guest".into());
    let guest_client =
        env::var("SHADOW_GUEST_CLIENT").unwrap_or_else(|_| GUEST_RUNTIME_CLIENT_BIN.into());
    let mut command = build_compositor_command(&compositor_bin);
    if let Ok(loader) = env::var(GUEST_COMPOSITOR_LOADER_ENV) {
        if !loader.is_empty() {
            log_line(&format!("launching {compositor_bin} via {loader}"));
        }
    }
    // Command inherits the current process environment by default, so only
    // set the values this wrapper owns: runtime-dir overrides plus defaults.
    command
        .env("XDG_RUNTIME_DIR", runtime_dir)
        .env("TMPDIR", runtime_dir)
        .env("SHADOW_GUEST_CLIENT", &guest_client)
        .env(
            "RUST_LOG",
            env::var("RUST_LOG").unwrap_or_else(|_| {
                "shadow_compositor_guest=info,shadow_blitz_demo=info,smithay=warn".into()
            }),
        );

    run_command(command, &compositor_bin);
}

fn main() {
    log_stdio("session bootstrapping");

    if let Err(error) = detect_guest_ui_mode() {
        log_line(&error);
        process::exit(1);
    }

    log_line("mode GuestUi");
    run_guest_ui()
}

#[cfg(test)]
mod tests {
    use super::{build_compositor_command_with_loader, ensure_directory_mode};
    use std::ffi::{OsStr, OsString};
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn unique_temp_dir() -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        std::env::temp_dir().join(format!("shadow-session-test-{nanos}"))
    }

    #[test]
    fn ensure_directory_mode_sets_requested_mode() {
        let dir = unique_temp_dir();

        ensure_directory_mode(dir.to_str().expect("utf8 path"), 0o700).expect("ensure mode");

        let mode = fs::metadata(&dir).expect("metadata").permissions().mode() & 0o777;
        assert_eq!(mode, 0o700);

        fs::remove_dir_all(&dir).expect("cleanup");
    }

    fn command_args(command: &Command) -> Vec<OsString> {
        command.get_args().map(|arg| arg.to_os_string()).collect()
    }

    #[test]
    fn compositor_command_runs_binary_directly_without_loader() {
        let command =
            build_compositor_command_with_loader("/orange-gpu/shadow-compositor-guest", None, None);

        assert_eq!(
            command.get_program(),
            OsStr::new("/orange-gpu/shadow-compositor-guest")
        );
        assert!(command_args(&command).is_empty());
    }

    #[test]
    fn compositor_command_can_run_dynamic_binary_through_staged_loader() {
        let command = build_compositor_command_with_loader(
            "/orange-gpu/shadow-compositor-guest",
            Some("/orange-gpu/lib/ld-linux-aarch64.so.1"),
            Some("/orange-gpu/lib"),
        );

        assert_eq!(
            command.get_program(),
            OsStr::new("/orange-gpu/lib/ld-linux-aarch64.so.1")
        );
        assert_eq!(
            command_args(&command),
            vec![
                OsString::from("--library-path"),
                OsString::from("/orange-gpu/lib"),
                OsString::from("/orange-gpu/shadow-compositor-guest"),
            ]
        );
    }
}
