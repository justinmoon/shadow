use std::env;
use std::ffi::{CString, OsString};
use std::fs::{self, OpenOptions, Permissions};
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process;

const INIT_PATH: &str = "/init";
const STOCK_INIT_PATH: &str = "/init.stock";
const WRAPPER_MARKER_ROOT: &str = "/.shadow-init-wrapper";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum WrapperMode {
    Standard,
    Minimal,
}

impl WrapperMode {
    fn current() -> Self {
        Self::from_build_mode(option_env!("SHADOW_INIT_WRAPPER_MODE"))
    }

    fn from_build_mode(value: Option<&str>) -> Self {
        match value.unwrap_or("standard") {
            "standard" => Self::Standard,
            "minimal" => Self::Minimal,
            other => panic!("unsupported SHADOW_INIT_WRAPPER_MODE: {other}"),
        }
    }

    fn exec_path(self) -> &'static str {
        match self {
            Self::Standard => INIT_PATH,
            Self::Minimal => STOCK_INIT_PATH,
        }
    }

    fn restores_init_path(self) -> bool {
        matches!(self, Self::Standard)
    }

    fn writes_persistent_markers(self) -> bool {
        matches!(self, Self::Standard)
    }
}

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

fn wrapper_mode_sentinel() -> &'static str {
    match option_env!("SHADOW_INIT_WRAPPER_MODE").unwrap_or("standard") {
        "standard" => "shadow-init-wrapper-mode:standard",
        "minimal" => "shadow-init-wrapper-mode:minimal",
        other => panic!("unsupported SHADOW_INIT_WRAPPER_MODE sentinel: {other}"),
    }
}

fn access_x_ok(path: &str) -> bool {
    let c_path = CString::new(path).expect("path cstring");
    unsafe { libc::access(c_path.as_ptr(), libc::X_OK) == 0 }
}

fn write_marker_file(name: &str, contents: &str) {
    let marker_root = Path::new(WRAPPER_MARKER_ROOT);
    let _ = fs::create_dir_all(marker_root);
    let _ = fs::set_permissions(marker_root, Permissions::from_mode(0o755));

    let marker_path = marker_root.join(name);
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&marker_path)
    {
        let _ = file.write_all(contents.as_bytes());
        let _ = file.flush();
        let _ = fs::set_permissions(&marker_path, Permissions::from_mode(0o644));
    }
}

fn append_marker_event(message: &str) {
    let marker_root = Path::new(WRAPPER_MARKER_ROOT);
    let _ = fs::create_dir_all(marker_root);
    let _ = fs::set_permissions(marker_root, Permissions::from_mode(0o755));

    let marker_path = marker_root.join("events.log");
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&marker_path)
    {
        let _ = writeln!(file, "{message}");
        let _ = file.flush();
        let _ = fs::set_permissions(&marker_path, Permissions::from_mode(0o644));
    }
}

fn current_boot_id() -> Option<String> {
    fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .ok()
        .map(|boot_id| boot_id.trim().to_owned())
        .filter(|boot_id| !boot_id.is_empty())
}

fn record_wrapper_marker(mode: WrapperMode, stage: &str, message: &str) {
    if !mode.writes_persistent_markers() {
        return;
    }

    write_marker_file("status.txt", &format!("{stage}\n"));
    write_marker_file("pid.txt", &format!("{}\n", process::id()));
    if let Some(boot_id) = current_boot_id() {
        write_marker_file("boot-id.txt", &format!("{boot_id}\n"));
    }
    append_marker_event(&format!("{stage}: {message}"));
}

fn restore_stock_init() {
    record_wrapper_marker(WrapperMode::Standard, "restoring-stock-init", "restoring stock /init");

    if let Err(error) = fs::rename(INIT_PATH, "/init.wrapper") {
        record_wrapper_marker(
            WrapperMode::Standard,
            "rename-init-failed",
            &format!("rename(/init -> /init.wrapper) failed: {error}"),
        );
        log_line(&format!("rename(/init -> /init.wrapper) failed: {error}"));
        process::exit(124);
    }

    if let Err(error) = fs::rename(STOCK_INIT_PATH, INIT_PATH) {
        record_wrapper_marker(
            WrapperMode::Standard,
            "rename-init-stock-failed",
            &format!("rename(/init.stock -> /init) failed: {error}"),
        );
        log_line(&format!("rename(/init.stock -> /init) failed: {error}"));
        if let Err(rollback_error) = fs::rename("/init.wrapper", INIT_PATH) {
            record_wrapper_marker(
                WrapperMode::Standard,
                "rollback-rename-failed",
                &format!("rollback rename(/init.wrapper -> /init) failed: {rollback_error}"),
            );
            log_line(&format!(
                "rollback rename(/init.wrapper -> /init) failed: {rollback_error}"
            ));
        }
        process::exit(124);
    }

    record_wrapper_marker(
        WrapperMode::Standard,
        "stock-init-restored",
        "restored stock /init",
    );
}

fn build_exec_argv(args_os: &[OsString], arg0: &str) -> Result<Vec<CString>, ()> {
    let mut argv = Vec::with_capacity(args_os.len().max(1));
    argv.push(CString::new(arg0).expect("argv0 cstring"));

    for arg in args_os.iter().skip(1) {
        match CString::new(arg.as_os_str().as_bytes()) {
            Ok(value) => argv.push(value),
            Err(_) => return Err(()),
        }
    }

    Ok(argv)
}

fn handoff_to_stock(mode: WrapperMode) -> ! {
    if mode.restores_init_path() {
        record_wrapper_marker(mode, "handoff-starting", "restoring stock /init");
        log_line("restoring stock /init");
        restore_stock_init();
        record_wrapper_marker(mode, "exec-stock-init", "handing off to restored /init");
        log_line("handing off to restored /init");
    } else {
        log_line("handing off directly to /init.stock");
    }

    let args_os: Vec<_> = env::args_os().collect();
    let argv = match build_exec_argv(&args_os, INIT_PATH) {
        Ok(argv) => argv,
        Err(()) => {
            record_wrapper_marker(mode, "argv-nul-byte", "argv contained NUL byte");
            log_line("argv contained NUL byte");
            process::exit(125);
        }
    };

    let mut argv_ptrs: Vec<*const libc::c_char> = argv.iter().map(|arg| arg.as_ptr()).collect();
    argv_ptrs.push(std::ptr::null());

    let exec_path = mode.exec_path();
    let init_stock = CString::new(exec_path).expect("init cstring");
    unsafe {
        libc::execv(init_stock.as_ptr(), argv_ptrs.as_ptr());
    }

    let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(-1);
    record_wrapper_marker(
        mode,
        "execv-failed",
        &format!("execv({exec_path}) failed: {errno}"),
    );
    log_line(&format!("execv({exec_path}) failed: {errno}"));
    process::exit(127);
}

fn main() {
    let mode = WrapperMode::current();
    record_wrapper_marker(mode, "bootstrapping", "wrapper bootstrapping");
    if mode.writes_persistent_markers() {
        log_stdio("wrapper bootstrapping");
    }
    log_line(&format!("wrapper starting ({})", wrapper_mode_sentinel()));

    if !access_x_ok(STOCK_INIT_PATH) {
        record_wrapper_marker(mode, "init-stock-missing", "init.stock missing or not executable");
        log_line("init.stock missing or not executable");
        process::exit(126);
    }

    handoff_to_stock(mode);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn standard_mode_keeps_marker_and_restore_flow() {
        let mode = WrapperMode::from_build_mode(Some("standard"));

        assert!(mode.writes_persistent_markers());
        assert!(mode.restores_init_path());
        assert_eq!(mode.exec_path(), INIT_PATH);
    }

    #[test]
    fn minimal_mode_execs_init_stock_directly() {
        let mode = WrapperMode::from_build_mode(Some("minimal"));

        assert!(!mode.writes_persistent_markers());
        assert!(!mode.restores_init_path());
        assert_eq!(mode.exec_path(), STOCK_INIT_PATH);
    }

    #[test]
    fn sentinel_matches_selected_build_mode() {
        assert_eq!(wrapper_mode_sentinel(), "shadow-init-wrapper-mode:standard");
    }

    #[test]
    fn chainload_argv_keeps_init_as_argv0() {
        let args = vec![OsString::from("/init"), OsString::from("--second-stage")];
        let argv = build_exec_argv(&args, INIT_PATH).expect("argv");

        assert_eq!(argv[0].as_bytes(), INIT_PATH.as_bytes());
        assert_eq!(argv[1].as_bytes(), b"--second-stage");
    }
}
