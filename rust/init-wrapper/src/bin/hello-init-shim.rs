#![cfg_attr(target_os = "linux", no_std)]
#![cfg_attr(target_os = "linux", no_main)]

#[cfg(not(target_os = "linux"))]
fn main() {
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
mod linux {
    use core::ffi::{c_char, c_int, c_long};
    use core::panic::PanicInfo;
    use core::ptr;

    #[link(name = "c")]
    unsafe extern "C" {}

    const OWNED_INIT_ROLE_SENTINEL: &str = "shadow-owned-init-role:hello-init";
    const OWNED_INIT_IMPL_SENTINEL: &str = "shadow-owned-init-impl:rust-static";
    const OWNED_INIT_CONFIG_SENTINEL: &str = "shadow-owned-init-config:/shadow-init.cfg";
    const PROBE_STAGE_SENTINEL: &str = "shadow-owned-init-probe:nostd-shim-child";

    static CHILD_PATH: &[u8] = b"/hello-init-child\0";
    static CHILD_ARG0: &[u8] = b"/hello-init-child\0";
    static CHILD_ARG1: &[u8] = b"--owned-child\0";
    static CHILD_ARG2: &[u8] = b"--config\0";
    static CHILD_ARG3: &[u8] = b"/shadow-init.cfg\0";
    static BOOTLOADER: &[u8] = b"bootloader\0";

    #[panic_handler]
    fn panic(_info: &PanicInfo<'_>) -> ! {
        reboot_bootloader_forever()
    }

    fn raw_write(fd: c_int, message: &[u8]) {
        unsafe {
            libc::write(fd, message.as_ptr().cast(), message.len());
        }
    }

    fn raw_write_line(fd: c_int, message: &str) {
        raw_write(fd, message.as_bytes());
        raw_write(fd, b"\n");
    }

    fn raw_reboot(cmd: c_int, arg: *const c_char) -> c_long {
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
        let _ = raw_reboot(libc::LINUX_REBOOT_CMD_RESTART2, BOOTLOADER.as_ptr().cast());
        let _ = raw_reboot(libc::LINUX_REBOOT_CMD_RESTART, ptr::null());
        loop {
            unsafe {
                libc::sleep(60);
            }
        }
    }

    fn wait_for_child(child_pid: c_int) {
        loop {
            let mut status: c_int = 0;
            let rc = unsafe { libc::waitpid(child_pid, &mut status, 0) };
            if rc == child_pid {
                break;
            }
            if rc < 0 {
                let errno = unsafe { *libc::__errno_location() };
                if errno == libc::EINTR {
                    continue;
                }
                break;
            }
        }
    }

    fn exec_child() -> ! {
        let child_path = CHILD_PATH.as_ptr().cast::<c_char>();
        let mut argv: [*const c_char; 5] = [
            CHILD_ARG0.as_ptr().cast(),
            CHILD_ARG1.as_ptr().cast(),
            CHILD_ARG2.as_ptr().cast(),
            CHILD_ARG3.as_ptr().cast(),
            ptr::null(),
        ];
        unsafe {
            libc::execv(child_path, argv.as_mut_ptr());
            libc::_exit(127);
        }
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn main(_argc: c_int, _argv: *const *const c_char) -> c_int {
        if unsafe { libc::getpid() } != 1 {
            return 1;
        }

        raw_write(2, b"[shadow-hello-init-shim] spawning child hello-init\n");
        raw_write_line(2, OWNED_INIT_ROLE_SENTINEL);
        raw_write_line(2, OWNED_INIT_IMPL_SENTINEL);
        raw_write_line(2, OWNED_INIT_CONFIG_SENTINEL);
        raw_write_line(2, PROBE_STAGE_SENTINEL);

        let child_pid = unsafe { libc::fork() };
        if child_pid < 0 {
            reboot_bootloader_forever();
        }
        if child_pid == 0 {
            exec_child();
        }

        wait_for_child(child_pid);
        reboot_bootloader_forever()
    }
}
