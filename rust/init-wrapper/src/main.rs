use std::env;
use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::process;
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

fn log_stdio(message: &str) {
    let line = format!("[shadow-init] {message}\n");
    let _ = std::io::stdout().write_all(line.as_bytes());
    let _ = std::io::stderr().write_all(line.as_bytes());
}

fn log_line(message: &str) {
    log_stdio(message);

    if let Ok(mut file) = OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = file.write_all(format!("<6>[shadow-init] {message}\n").as_bytes());
        let _ = file.flush();
    }
}

fn access_x_ok(path: &str) -> bool {
    let c_path = CString::new(path).expect("path cstring");
    unsafe { libc::access(c_path.as_ptr(), libc::X_OK) == 0 }
}

fn path_exists(path: &str) -> bool {
    let c_path = CString::new(path).expect("path cstring");
    unsafe { libc::access(c_path.as_ptr(), libc::F_OK) == 0 }
}

fn late_session_rc_present() -> bool {
    path_exists("/init.shadow.rc") || path_exists("/system/etc/init/shadow-session.rc")
}

fn restore_stock_init() {
    if let Err(error) = fs::rename("/init", "/init.wrapper") {
        log_line(&format!("rename(/init -> /init.wrapper) failed: {error}"));
        process::exit(124);
    }

    if let Err(error) = fs::rename("/init.stock", "/init") {
        log_line(&format!("rename(/init.stock -> /init) failed: {error}"));
        if let Err(rollback_error) = fs::rename("/init.wrapper", "/init") {
            log_line(&format!(
                "rollback rename(/init.wrapper -> /init) failed: {rollback_error}"
            ));
        }
        process::exit(124);
    }
}

fn handoff_to_stock() -> ! {
    log_line("restoring stock /init");
    restore_stock_init();
    log_line("handing off to restored /init");

    let args_os: Vec<_> = env::args_os().collect();
    let mut argv = Vec::with_capacity(args_os.len().max(1));

    if args_os.is_empty() {
        argv.push(CString::new("/init").expect("argv0 cstring"));
    } else {
        for arg in &args_os {
            match CString::new(arg.as_os_str().as_bytes()) {
                Ok(value) => argv.push(value),
                Err(_) => {
                    log_line("argv contained NUL byte");
                    process::exit(125);
                }
            }
        }
    }

    let mut argv_ptrs: Vec<*const libc::c_char> = argv.iter().map(|arg| arg.as_ptr()).collect();
    argv_ptrs.push(std::ptr::null());

    let init_stock = CString::new("/init").expect("init cstring");
    unsafe {
        libc::execv(init_stock.as_ptr(), argv_ptrs.as_ptr());
    }

    let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(-1);
    log_line(&format!("execv(/init) failed: {errno}"));
    process::exit(127);
}

enum BackgroundPayload {
    Binary(&'static str),
    GuestUi,
}

impl BackgroundPayload {
    fn label(&self) -> &'static str {
        match self {
            Self::Binary(path) => path,
            Self::GuestUi => "/shadow-compositor-guest",
        }
    }
}

fn background_payload() -> Option<BackgroundPayload> {
    if late_session_rc_present() {
        return None;
    }
    if path_exists("/shadow-bootstrap") {
        return Some(BackgroundPayload::Binary("/shadow-bootstrap"));
    }
    if path_exists("/shadow-compositor-guest") && path_exists("/shadow-counter-guest") {
        return Some(BackgroundPayload::GuestUi);
    }
    if path_exists("/drm-rect") {
        return Some(BackgroundPayload::Binary("/drm-rect"));
    }
    None
}

fn wait_for_path(path: &str, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if unsafe {
            libc::access(
                CString::new(path).expect("path cstring").as_ptr(),
                libc::F_OK,
            )
        } == 0
        {
            return true;
        }
        thread::sleep(Duration::from_millis(250));
    }
    false
}

fn run_command(mut command: Command, label: &str) -> ! {
    log_line(&format!("background payload starting {label}"));
    match command.status() {
        Ok(status) => {
            log_line(&format!("background payload exited with {status}"));
            process::exit(status.code().unwrap_or(1));
        }
        Err(error) => {
            log_line(&format!("background payload launch failed: {error}"));
            process::exit(1);
        }
    }
}

fn prepare_guest_ui_runtime_dir() -> Result<&'static str, String> {
    const RUNTIME_DIR: &str = "/shadow-runtime";

    fs::create_dir_all(RUNTIME_DIR)
        .map_err(|error| format!("create_dir_all({RUNTIME_DIR}) failed: {error}"))?;
    fs::set_permissions(RUNTIME_DIR, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("set_permissions({RUNTIME_DIR}) failed: {error}"))?;

    Ok(RUNTIME_DIR)
}

fn run_background_payload(payload: BackgroundPayload) -> ! {
    match payload {
        BackgroundPayload::Binary("/drm-rect") => {
            log_line("background payload waiting for /dev/dri/card0");
            if !wait_for_path("/dev/dri/card0", Duration::from_secs(120)) {
                log_line("background payload timed out waiting for /dev/dri/card0");
                process::exit(1);
            }
            run_command(Command::new("/drm-rect"), "/drm-rect");
        }
        BackgroundPayload::Binary(path) => run_command(Command::new(path), path),
        BackgroundPayload::GuestUi => {
            let runtime_dir = match prepare_guest_ui_runtime_dir() {
                Ok(path) => path,
                Err(error) => {
                    log_line(&error);
                    process::exit(1);
                }
            };

            let mut command = Command::new("/shadow-compositor-guest");
            command
                .env("XDG_RUNTIME_DIR", runtime_dir)
                .env("TMPDIR", runtime_dir)
                .env("SHADOW_GUEST_CLIENT", "/shadow-counter-guest")
                .env(
                    "RUST_LOG",
                    "shadow_compositor_guest=info,shadow_counter_guest=info,smithay=warn",
                );
            run_command(command, "/shadow-compositor-guest");
        }
    }
}

fn maybe_launch_background_payload() {
    if late_session_rc_present() {
        log_line("shadow-session rc present; skipping first-stage background payload");
        return;
    }

    let Some(payload) = background_payload() else {
        return;
    };

    log_line(&format!("forking background payload {}", payload.label()));
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        log_line("fork() failed for background payload");
        return;
    }
    if pid == 0 {
        run_background_payload(payload);
    }
}

fn main() {
    log_stdio("wrapper bootstrapping");

    log_line("wrapper starting");

    if !access_x_ok("/init.stock") {
        log_line("init.stock missing or not executable");
        process::exit(126);
    }

    maybe_launch_background_payload();
    handoff_to_stock();
}
