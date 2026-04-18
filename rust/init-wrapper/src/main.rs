use std::env;
use std::ffi::CString;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::process;

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

fn main() {
    log_stdio("wrapper bootstrapping");
    log_line("wrapper starting");

    if !access_x_ok("/init.stock") {
        log_line("init.stock missing or not executable");
        process::exit(126);
    }

    handoff_to_stock();
}
