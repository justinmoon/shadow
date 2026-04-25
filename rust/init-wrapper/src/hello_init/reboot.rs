use super::*;

pub(super) fn raw_reboot(cmd: libc::c_int, arg: Option<&str>) -> io::Result<()> {
    let arg_c = arg.map(|value| CString::new(value).unwrap());
    let arg_ptr = arg_c
        .as_ref()
        .map(|value| value.as_ptr())
        .unwrap_or(std::ptr::null());
    let rc = unsafe {
        libc::syscall(
            libc::SYS_reboot,
            libc::LINUX_REBOOT_MAGIC1,
            libc::LINUX_REBOOT_MAGIC2,
            cmd,
            arg_ptr,
        )
    };
    if rc == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

pub(super) fn reboot_from_config(config: &Config) -> ! {
    unsafe {
        libc::sync();
    }
    let target = config.reboot_target.as_str();
    let _ = match target {
        "halt" => raw_reboot(libc::LINUX_REBOOT_CMD_HALT, None),
        "poweroff" => raw_reboot(libc::LINUX_REBOOT_CMD_POWER_OFF, None),
        "restart" | "reboot" => raw_reboot(libc::LINUX_REBOOT_CMD_RESTART, None),
        other => raw_reboot(libc::LINUX_REBOOT_CMD_RESTART2, Some(other))
            .or_else(|_| raw_reboot(libc::LINUX_REBOOT_CMD_RESTART, None)),
    };
    loop {
        sleep_seconds(60);
    }
}
