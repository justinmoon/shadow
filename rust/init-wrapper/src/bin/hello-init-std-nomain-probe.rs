#![cfg_attr(target_os = "linux", no_main)]

#[cfg(not(target_os = "linux"))]
fn main() {
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
mod linux {
    use std::ptr;

    const OWNED_INIT_ROLE_SENTINEL: &str = "shadow-owned-init-role:hello-init";
    const OWNED_INIT_IMPL_SENTINEL: &str = "shadow-owned-init-impl:rust-static";
    const OWNED_INIT_CONFIG_SENTINEL: &str = "shadow-owned-init-config:/shadow-init.cfg";
    const PROBE_STAGE_SENTINEL: &str = "shadow-owned-init-probe:std-nomain-reboot";

    fn raw_write(fd: libc::c_int, message: &[u8]) {
        unsafe {
            libc::write(fd, message.as_ptr().cast(), message.len());
        }
    }

    fn raw_write_line(fd: libc::c_int, message: &str) {
        raw_write(fd, message.as_bytes());
        raw_write(fd, b"\n");
    }

    fn raw_reboot(cmd: libc::c_int, arg: *const libc::c_char) -> libc::c_long {
        unsafe {
            libc::syscall(
                libc::SYS_reboot,
                libc::LINUX_REBOOT_MAGIC1,
                libc::LINUX_REBOOT_MAGIC2,
                cmd,
                arg,
            )
        }
    }

    fn reboot_bootloader_forever() -> ! {
        static BOOTLOADER: &[u8] = b"bootloader\0";
        let _ = raw_reboot(
            libc::LINUX_REBOOT_CMD_RESTART2,
            BOOTLOADER.as_ptr().cast(),
        );
        let _ = raw_reboot(libc::LINUX_REBOOT_CMD_RESTART, ptr::null());
        loop {
            unsafe {
                libc::sleep(60);
            }
        }
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn main(_argc: libc::c_int, _argv: *const *const libc::c_char) -> libc::c_int {
        if unsafe { libc::getpid() } != 1 {
            unsafe { libc::_exit(1) }
        }

        raw_write(2, b"[shadow-hello-init-std-nomain-probe] entering std no_main reboot probe\n");
        raw_write_line(2, OWNED_INIT_ROLE_SENTINEL);
        raw_write_line(2, OWNED_INIT_IMPL_SENTINEL);
        raw_write_line(2, OWNED_INIT_CONFIG_SENTINEL);
        raw_write_line(2, PROBE_STAGE_SENTINEL);

        reboot_bootloader_forever()
    }
}
