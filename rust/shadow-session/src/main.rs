use std::env;
use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::process::{self, Command};
use std::thread;
use std::time::{Duration, Instant};

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

fn prepare_guest_runtime_dir() -> Result<&'static str, String> {
    let runtime_dir =
        env::var("SHADOW_RUNTIME_DIR").unwrap_or_else(|_| "/shadow-runtime".to_string());

    fs::create_dir_all(&runtime_dir)
        .map_err(|error| format!("create_dir_all({runtime_dir}) failed: {error}"))?;
    fs::set_permissions(&runtime_dir, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("set_permissions({runtime_dir}) failed: {error}"))?;

    Ok(Box::leak(runtime_dir.into_boxed_str()))
}

#[derive(Clone, Copy, Debug)]
enum SessionMode {
    DrmRect,
    GuestUi,
}

impl SessionMode {
    fn detect() -> Result<Self, String> {
        match env::var("SHADOW_SESSION_MODE").ok().as_deref() {
            Some("drm-rect") => Ok(Self::DrmRect),
            Some("guest-ui") => Ok(Self::GuestUi),
            Some(other) => Err(format!("unknown SHADOW_SESSION_MODE={other}")),
            None if path_exists("/shadow-compositor-guest")
                && path_exists("/shadow-counter-guest") =>
            {
                Ok(Self::GuestUi)
            }
            None if path_exists("/drm-rect") => Ok(Self::DrmRect),
            None => Err("could not detect a session mode".into()),
        }
    }
}

fn run_drm_rect() -> ! {
    let drm_rect_bin = env::var("SHADOW_DRM_RECT_BIN").unwrap_or_else(|_| "/drm-rect".into());
    let found = wait_for_path("/dev/dri/card0", Duration::from_secs(180));
    if !found {
        log_dir_snapshot("/dev");
        log_dir_snapshot("/dev/dri");
        log_dir_snapshot("/dev/graphics");
    }

    run_command(Command::new(&drm_rect_bin), &drm_rect_bin);
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
    let mut command = Command::new(&compositor_bin);
    command
        .env("XDG_RUNTIME_DIR", runtime_dir)
        .env("TMPDIR", runtime_dir)
        .env(
            "SHADOW_GUEST_CLIENT",
            env::var("SHADOW_GUEST_CLIENT").unwrap_or_else(|_| "/shadow-counter-guest".into()),
        )
        .env(
            "RUST_LOG",
            env::var("RUST_LOG").unwrap_or_else(|_| {
                "shadow_compositor_guest=info,shadow_counter_guest=info,smithay=warn".into()
            }),
        );

    if let Some(value) = env::var_os("SHADOW_GUEST_COMPOSITOR_ENABLE_DRM") {
        command.env("SHADOW_GUEST_COMPOSITOR_ENABLE_DRM", value);
    }
    if let Some(value) = env::var_os("SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME") {
        command.env("SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME", value);
    }
    if let Some(value) = env::var_os("SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_WINDOW") {
        command.env("SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_WINDOW", value);
    }
    if let Some(value) = env::var_os("SHADOW_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT") {
        command.env("SHADOW_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT", value);
    }
    if let Some(value) = env::var_os("SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE") {
        command.env("SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE", value);
    }
    if let Some(value) = env::var_os("SHADOW_GUEST_COUNTER_LINGER_MS") {
        command.env("SHADOW_GUEST_COUNTER_LINGER_MS", value);
    }
    if let Some(value) = env::var_os("SHADOW_GUEST_FRAME_PATH") {
        command.env("SHADOW_GUEST_FRAME_PATH", value);
    }
    if let Some(value) = env::var_os("SHADOW_GUEST_CLIENT_ENV") {
        command.env("SHADOW_GUEST_CLIENT_ENV", value);
    }
    if let Some(value) = env::var_os("SHADOW_GUEST_COMPOSITOR_SELFTEST_DRM") {
        command.env("SHADOW_GUEST_COMPOSITOR_SELFTEST_DRM", value);
    }

    run_command(command, &compositor_bin);
}

fn main() {
    log_stdio("session bootstrapping");

    let mode = match SessionMode::detect() {
        Ok(mode) => mode,
        Err(error) => {
            log_line(&error);
            process::exit(1);
        }
    };

    log_line(&format!("mode {mode:?}"));

    match mode {
        SessionMode::DrmRect => run_drm_rect(),
        SessionMode::GuestUi => run_guest_ui(),
    }
}
