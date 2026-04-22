#[cfg(not(target_os = "linux"))]
fn main() {
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
mod linux {
    use std::ffi::CString;

    const OWNED_INIT_ROLE_SENTINEL: &str = "shadow-owned-init-role:hello-init";
    const OWNED_INIT_IMPL_SENTINEL: &str = "shadow-owned-init-impl:rust-static";
    const OWNED_INIT_CONFIG_SENTINEL: &str = "shadow-owned-init-config:/shadow-init.cfg";
    const PROBE_STAGE_SENTINEL: &str = "shadow-owned-init-probe:minimal-reboot";

    fn arg_present(flag: &str) -> bool {
        let flag_bytes = flag.as_bytes();
        std::env::args_os().any(|arg| arg.as_encoded_bytes() == flag_bytes)
    }

    fn raw_write(fd: libc::c_int, message: &[u8]) {
        unsafe {
            libc::write(fd, message.as_ptr().cast(), message.len());
        }
    }

    fn raw_write_line(fd: libc::c_int, message: &str) {
        raw_write(fd, message.as_bytes());
        raw_write(fd, b"\n");
    }

    fn raw_reboot(cmd: libc::c_int, arg: Option<&str>) -> libc::c_long {
        let arg_c = arg.and_then(|value| CString::new(value).ok());
        let arg_ptr = arg_c
            .as_ref()
            .map(|value| value.as_ptr())
            .unwrap_or(std::ptr::null());
        unsafe {
            libc::syscall(
                libc::SYS_reboot,
                libc::LINUX_REBOOT_MAGIC1,
                libc::LINUX_REBOOT_MAGIC2,
                cmd,
                arg_ptr,
            )
        }
    }

    fn reboot_bootloader_forever() -> ! {
        let _ = raw_reboot(libc::LINUX_REBOOT_CMD_RESTART2, Some("bootloader"));
        let _ = raw_reboot(libc::LINUX_REBOOT_CMD_RESTART, None);
        loop {
            unsafe {
                libc::sleep(60);
            }
        }
    }

    pub(crate) fn main_linux() -> ! {
        let selftest = arg_present("--selftest");
        if !selftest && unsafe { libc::getpid() } != 1 {
            unsafe { libc::_exit(1) }
        }

        raw_write(
            2,
            b"[shadow-hello-init-probe] entering minimal reboot probe\n",
        );
        raw_write_line(2, OWNED_INIT_ROLE_SENTINEL);
        raw_write_line(2, OWNED_INIT_IMPL_SENTINEL);
        raw_write_line(2, OWNED_INIT_CONFIG_SENTINEL);
        raw_write_line(2, PROBE_STAGE_SENTINEL);

        if selftest {
            unsafe { libc::_exit(0) }
        }

        reboot_bootloader_forever()
    }
}

#[cfg(target_os = "linux")]
fn main() {
    linux::main_linux();
}
