#![cfg_attr(target_os = "linux", no_main)]

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("hello-init only supports linux targets");
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
#[unsafe(no_mangle)]
pub extern "C" fn main(argc: libc::c_int, argv: *const *const libc::c_char) -> libc::c_int {
    init_wrapper::hello_init::main_linux_raw(argc, argv);
}
