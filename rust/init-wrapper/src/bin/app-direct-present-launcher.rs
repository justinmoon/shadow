use std::{
    env,
    ffi::OsString,
    fs, io,
    os::unix::process::CommandExt,
    path::Path,
    process::{self, Command},
};

const ROLE_SENTINEL: &str = "shadow-app-direct-present-launcher-role:static-loader-exec";
const BUNDLE_ROOT: &str = "/orange-gpu/app-direct-present";
const LOADER_PATH: &str = "/orange-gpu/app-direct-present/lib/ld-linux-aarch64.so.1";
const LIBRARY_PATH: &str = "/orange-gpu/app-direct-present/lib";
const APP_BINARY_PATH: &str = "/orange-gpu/app-direct-present/shadow-rust-demo";
const DEFAULT_HOME: &str = "/orange-gpu/app-direct-present/home";
const DEFAULT_CACHE_HOME: &str = "/orange-gpu/app-direct-present/home/.cache";
const DEFAULT_CONFIG_HOME: &str = "/orange-gpu/app-direct-present/home/.config";
const CAMERA_ALLOW_MOCK_ENV: &str = "SHADOW_RUNTIME_CAMERA_ALLOW_MOCK";
const APP_BINARY_PATH_ENV: &str = "SHADOW_APP_DIRECT_PRESENT_BINARY_PATH";
const LOADER_PATH_ENV: &str = "SHADOW_APP_DIRECT_PRESENT_LOADER_PATH";
const LIBRARY_PATH_ENV: &str = "SHADOW_APP_DIRECT_PRESENT_LIBRARY_PATH";

fn main() {
    if let Err(error) = exec_app() {
        eprintln!("[shadow-app-direct-present-launcher] failed: {error}");
        process::exit(127);
    }
}

fn exec_app() -> io::Result<()> {
    let home = env_or_default("HOME", DEFAULT_HOME);
    let cache_home = env_or_default("XDG_CACHE_HOME", DEFAULT_CACHE_HOME);
    let config_home = env_or_default("XDG_CONFIG_HOME", DEFAULT_CONFIG_HOME);
    let loader_path = env_or_default(LOADER_PATH_ENV, LOADER_PATH);
    let library_path = env_or_default(LIBRARY_PATH_ENV, LIBRARY_PATH);
    let app_binary_path = env_or_default(APP_BINARY_PATH_ENV, APP_BINARY_PATH);
    let library_env = prepend_env_path("LD_LIBRARY_PATH", &library_path.to_string_lossy());

    fs::create_dir_all(Path::new(&home))?;
    fs::create_dir_all(Path::new(&cache_home))?;
    fs::create_dir_all(Path::new(&config_home))?;

    eprintln!("[shadow-app-direct-present-launcher] {ROLE_SENTINEL} bundle_root={BUNDLE_ROOT}");
    eprintln!(
        "[shadow-app-direct-present-launcher] exec loader={} app={}",
        loader_path.to_string_lossy(),
        app_binary_path.to_string_lossy(),
    );

    let mut command = Command::new(loader_path);
    command
        .arg("--library-path")
        .arg(&library_path)
        .arg(app_binary_path)
        .args(env::args_os().skip(1))
        .env("HOME", home)
        .env("XDG_CACHE_HOME", cache_home)
        .env("XDG_CONFIG_HOME", config_home)
        .env("LD_LIBRARY_PATH", library_env);

    if env::var_os(CAMERA_ALLOW_MOCK_ENV).is_none() {
        command.env(CAMERA_ALLOW_MOCK_ENV, "1");
    }

    Err(command.exec())
}

fn env_or_default(key: &str, default_value: &str) -> OsString {
    match env::var_os(key) {
        Some(value) if !value.as_os_str().is_empty() => value,
        _ => OsString::from(default_value),
    }
}

fn prepend_env_path(key: &str, prefix: &str) -> OsString {
    match env::var_os(key) {
        Some(value) if !value.as_os_str().is_empty() => {
            let mut combined = OsString::from(prefix);
            combined.push(":");
            combined.push(value);
            combined
        }
        _ => OsString::from(prefix),
    }
}
