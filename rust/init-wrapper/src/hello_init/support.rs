use super::*;

pub(super) fn bool_word(value: bool) -> &'static str {
    if value {
        "true"
    } else {
        "false"
    }
}

pub(super) fn current_boot_id() -> Option<String> {
    fs::read_to_string("/proc/sys/kernel/random/boot_id")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

pub(super) fn raw_write_fd(fd: libc::c_int, payload: &[u8]) {
    unsafe {
        libc::write(fd, payload.as_ptr().cast(), payload.len());
    }
}

pub(super) fn write_to_kmsg(message: &str) {
    if !LOG_KMSG_ENABLED.load(Ordering::Relaxed) {
        return;
    }
    let Ok(kmsg_path) = CString::new("/dev/kmsg") else {
        return;
    };
    let fd = unsafe {
        libc::open(
            kmsg_path.as_ptr(),
            libc::O_WRONLY | libc::O_CLOEXEC | libc::O_NOCTTY,
        )
    };
    if fd < 0 {
        return;
    }
    let payload = format!("<6>[shadow-hello-init] {message}\n");
    raw_write_fd(fd, payload.as_bytes());
    unsafe {
        libc::close(fd);
    }
}

pub(super) fn write_to_pmsg(message: &str) {
    if !LOG_PMSG_ENABLED.load(Ordering::Relaxed) {
        return;
    }
    let Ok(pmsg_path) = CString::new("/dev/pmsg0") else {
        return;
    };
    let fd = unsafe {
        libc::open(
            pmsg_path.as_ptr(),
            libc::O_WRONLY | libc::O_CLOEXEC | libc::O_NOCTTY,
        )
    };
    if fd < 0 {
        return;
    }
    let payload = format!("[shadow-hello-init] {message}\n");
    raw_write_fd(fd, payload.as_bytes());
    unsafe {
        libc::close(fd);
    }
}

pub(super) fn log_line(message: &str) {
    let payload = format!("[shadow-hello-init] {message}\n");
    raw_write_fd(1, payload.as_bytes());
    raw_write_fd(2, payload.as_bytes());
    write_to_kmsg(message);
    write_to_pmsg(message);
}

pub(super) fn set_log_channel_preferences(config: &Config) {
    LOG_KMSG_ENABLED.store(config.log_kmsg, Ordering::Relaxed);
    LOG_PMSG_ENABLED.store(config.log_pmsg, Ordering::Relaxed);
}

pub(super) fn ensure_directory(path: &Path, mode: u32) -> io::Result<()> {
    fs::create_dir_all(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))?;
    Ok(())
}

pub(super) fn ensure_node(path: &Path, mode: u32, dev: libc::dev_t) -> io::Result<()> {
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if metadata.file_type().is_char_device() || metadata.file_type().is_block_device() {
            return Ok(());
        }
        fs::remove_file(path)?;
    }

    let c_path = CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    let result = unsafe { libc::mknod(c_path.as_ptr(), mode as libc::mode_t, dev) };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    fs::set_permissions(path, fs::Permissions::from_mode(mode & 0o7777))?;
    Ok(())
}

pub(super) fn ensure_char_device(path: &Path, perm: u32, major: u64, minor: u64) -> io::Result<()> {
    ensure_node(
        path,
        libc::S_IFCHR | perm,
        libc::makedev(major as u32, minor as u32),
    )
}

pub(super) fn ensure_block_device(
    path: &Path,
    perm: u32,
    major: u64,
    minor: u64,
) -> io::Result<()> {
    ensure_node(
        path,
        libc::S_IFBLK | perm,
        libc::makedev(major as u32, minor as u32),
    )
}

pub(super) fn ensure_symlink_target(path: &Path, target: &Path) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() {
                return Ok(());
            }
            if metadata.is_file() {
                fs::remove_file(path)?;
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    std::os::unix::fs::symlink(target, path)
}

pub(super) fn ensure_stdio_fds() -> io::Result<()> {
    let dev_null = CString::new("/dev/null").unwrap();
    for fd in [0, 1, 2] {
        let status = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if status >= 0 {
            continue;
        }
        let opened = unsafe { libc::open(dev_null.as_ptr(), libc::O_RDWR | libc::O_CLOEXEC) };
        if opened < 0 {
            return Err(io::Error::last_os_error());
        }
        if opened != fd {
            let dup_rc = unsafe { libc::dup2(opened, fd) };
            let saved = io::Error::last_os_error();
            unsafe {
                libc::close(opened);
            }
            if dup_rc < 0 {
                return Err(saved);
            }
        }
    }
    Ok(())
}

pub(super) fn mount_fs(
    source: &str,
    target: &str,
    fstype: &str,
    flags: libc::c_ulong,
    data: Option<&str>,
) -> io::Result<()> {
    let source_c = CString::new(source).unwrap();
    let target_c = CString::new(target).unwrap();
    let fstype_c = CString::new(fstype).unwrap();
    let data_c = data.map(|value| CString::new(value).unwrap());
    let rc = unsafe {
        libc::mount(
            source_c.as_ptr(),
            target_c.as_ptr(),
            fstype_c.as_ptr(),
            flags,
            data_c
                .as_ref()
                .map(|value| value.as_ptr() as *const libc::c_void)
                .unwrap_or(std::ptr::null()),
        )
    };
    if rc == 0 {
        return Ok(());
    }
    let err = io::Error::last_os_error();
    if err.raw_os_error() == Some(libc::EBUSY) {
        return Ok(());
    }
    Err(err)
}

pub(super) fn sleep_seconds(seconds: u32) {
    thread::sleep(Duration::from_secs(seconds as u64));
}

pub(super) fn hold_for_observation(seconds: u32) {
    if seconds == 0 {
        return;
    }
    sleep_seconds(seconds);
}

pub(super) fn run_token_or_unset(config: &Config) -> &str {
    if config.run_token.is_empty() {
        "unset"
    } else {
        &config.run_token
    }
}

pub(super) fn append_wrapper_log(message: &str) {
    log_line(message);
}

pub(super) fn parse_bool(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

pub(super) fn parse_u32(value: &str) -> Option<u32> {
    let parsed = value.trim().parse::<u32>().ok()?;
    if parsed > MAX_HOLD_SECONDS {
        return None;
    }
    Some(parsed)
}

pub(super) fn parse_allowed(value: &str, allowed: &[&str]) -> Option<String> {
    let trimmed = value.trim();
    if allowed.iter().any(|candidate| *candidate == trimmed) {
        Some(trimmed.to_string())
    } else {
        None
    }
}

pub(super) fn parse_run_token(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        Some(trimmed.to_string())
    } else {
        None
    }
}

pub(super) fn parse_args_raw(argc: libc::c_int, argv: *const *const libc::c_char) -> Args {
    let mut args = Args::default();
    if argc <= 1 || argv.is_null() {
        return args;
    }

    let argc = usize::try_from(argc).unwrap_or(0);
    if argc <= 1 {
        return args;
    }

    let raw_args = unsafe { std::slice::from_raw_parts(argv, argc) };
    if let Some(raw_argv0) = raw_args.first().copied() {
        if !raw_argv0.is_null() {
            let argv0_bytes = unsafe { CStr::from_ptr(raw_argv0) }.to_bytes().to_vec();
            let argv0 = std::ffi::OsString::from_vec(argv0_bytes);
            args.argv0 = Some(argv0.to_string_lossy().into_owned());
        }
    }
    let mut index = 1usize;
    while index < raw_args.len() {
        let Some(raw_arg) = raw_args.get(index).copied() else {
            break;
        };
        if raw_arg.is_null() {
            index += 1;
            continue;
        }

        let arg_bytes = unsafe { CStr::from_ptr(raw_arg) }.to_bytes();
        if arg_bytes == b"--selftest" {
            args.selftest = true;
            index += 1;
            continue;
        }
        if arg_bytes == b"--owned-child" {
            args.owned_child = true;
            index += 1;
            continue;
        }
        if arg_bytes == b"--orange-gpu-child-mode" {
            if let Some(raw_value) = raw_args.get(index + 1).copied() {
                if !raw_value.is_null() {
                    let mode_bytes = unsafe { CStr::from_ptr(raw_value) }.to_bytes().to_vec();
                    let mode = std::ffi::OsString::from_vec(mode_bytes)
                        .to_string_lossy()
                        .into_owned();
                    if matches!(
                        mode.as_str(),
                        "timeout-control-smoke"
                            | "camera-hal-link-probe"
                            | "wifi-linux-surface-probe"
                            | "c-kgsl-open-readonly-smoke"
                            | "c-kgsl-open-readonly-firmware-helper-smoke"
                    ) {
                        args.orange_gpu_child_mode = Some(mode);
                    }
                }
                index += 2;
                continue;
            }
        }
        if arg_bytes == b"--config" {
            if let Some(raw_value) = raw_args.get(index + 1).copied() {
                if !raw_value.is_null() {
                    let config_bytes = unsafe { CStr::from_ptr(raw_value) }.to_bytes().to_vec();
                    let config_path = std::ffi::OsString::from_vec(config_bytes);
                    args.config_path = Some(config_path.to_string_lossy().into_owned());
                }
                index += 2;
                continue;
            }
        }
        index += 1;
    }
    args
}
