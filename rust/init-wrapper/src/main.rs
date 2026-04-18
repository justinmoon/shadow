use std::env;
use std::ffi::CString;
use std::fs::{self, OpenOptions, Permissions};
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process;

const WRAPPER_MARKER_ROOT: &str = "/.shadow-init-wrapper";

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

fn record_wrapper_marker(stage: &str, message: &str) {
    write_marker_file("status.txt", &format!("{stage}\n"));
    write_marker_file("pid.txt", &format!("{}\n", process::id()));
    if let Some(boot_id) = current_boot_id() {
        write_marker_file("boot-id.txt", &format!("{boot_id}\n"));
    }
    append_marker_event(&format!("{stage}: {message}"));
}

fn restore_stock_init() {
    record_wrapper_marker("restoring-stock-init", "restoring stock /init");

    if let Err(error) = fs::rename("/init", "/init.wrapper") {
        record_wrapper_marker(
            "rename-init-failed",
            &format!("rename(/init -> /init.wrapper) failed: {error}"),
        );
        log_line(&format!("rename(/init -> /init.wrapper) failed: {error}"));
        process::exit(124);
    }

    if let Err(error) = fs::rename("/init.stock", "/init") {
        record_wrapper_marker(
            "rename-init-stock-failed",
            &format!("rename(/init.stock -> /init) failed: {error}"),
        );
        log_line(&format!("rename(/init.stock -> /init) failed: {error}"));
        if let Err(rollback_error) = fs::rename("/init.wrapper", "/init") {
            record_wrapper_marker(
                "rollback-rename-failed",
                &format!("rollback rename(/init.wrapper -> /init) failed: {rollback_error}"),
            );
            log_line(&format!(
                "rollback rename(/init.wrapper -> /init) failed: {rollback_error}"
            ));
        }
        process::exit(124);
    }

    record_wrapper_marker("stock-init-restored", "restored stock /init");
}

fn handoff_to_stock() -> ! {
    record_wrapper_marker("handoff-starting", "restoring stock /init");
    log_line("restoring stock /init");
    restore_stock_init();
    record_wrapper_marker("exec-stock-init", "handing off to restored /init");
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
                    record_wrapper_marker("argv-nul-byte", "argv contained NUL byte");
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
    record_wrapper_marker("execv-failed", &format!("execv(/init) failed: {errno}"));
    log_line(&format!("execv(/init) failed: {errno}"));
    process::exit(127);
}

fn main() {
    record_wrapper_marker("bootstrapping", "wrapper bootstrapping");
    log_stdio("wrapper bootstrapping");
    log_line("wrapper starting");

    if !access_x_ok("/init.stock") {
        record_wrapper_marker("init-stock-missing", "init.stock missing or not executable");
        log_line("init.stock missing or not executable");
        process::exit(126);
    }

    handoff_to_stock();
}
