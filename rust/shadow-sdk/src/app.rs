use std::{
    env, io,
    path::PathBuf,
    sync::{Mutex, OnceLock},
    thread::JoinHandle,
};

pub use shadow_runtime_protocol::AppLifecycleState as LifecycleState;

use shadow_runtime_protocol::AppPlatformRequest;

#[cfg(unix)]
use std::{
    io::{Read, Write},
    os::unix::net::UnixListener,
};

pub const APP_TITLE_ENV: &str = "SHADOW_APP_TITLE";
pub const APP_LIFECYCLE_STATE_ENV: &str = "SHADOW_APP_LIFECYCLE_STATE";
pub const APP_PLATFORM_CONTROL_SOCKET_ENV: &str = "SHADOW_APP_PLATFORM_CONTROL_SOCKET";
pub const SAFE_AREA_BOTTOM_ENV: &str = "SHADOW_APP_SAFE_AREA_BOTTOM";
pub const SAFE_AREA_LEFT_ENV: &str = "SHADOW_APP_SAFE_AREA_LEFT";
pub const SAFE_AREA_RIGHT_ENV: &str = "SHADOW_APP_SAFE_AREA_RIGHT";
pub const SAFE_AREA_TOP_ENV: &str = "SHADOW_APP_SAFE_AREA_TOP";
pub const SURFACE_HEIGHT_ENV: &str = "SHADOW_APP_SURFACE_HEIGHT";
pub const SURFACE_WIDTH_ENV: &str = "SHADOW_APP_SURFACE_WIDTH";
pub const UNDECORATED_ENV: &str = "SHADOW_APP_UNDECORATED";
pub const WAYLAND_APP_ID_ENV: &str = "SHADOW_APP_WAYLAND_APP_ID";
pub const WAYLAND_INSTANCE_NAME_ENV: &str = "SHADOW_APP_WAYLAND_INSTANCE_NAME";

const LEGACY_APP_TITLE_ENV: &str = "SHADOW_BLITZ_APP_TITLE";
const LEGACY_APP_PLATFORM_CONTROL_SOCKET_ENV: &str = "SHADOW_BLITZ_PLATFORM_CONTROL_SOCKET";
const LEGACY_SAFE_AREA_BOTTOM_ENV: &str = "SHADOW_BLITZ_SAFE_AREA_BOTTOM";
const LEGACY_SAFE_AREA_LEFT_ENV: &str = "SHADOW_BLITZ_SAFE_AREA_LEFT";
const LEGACY_SAFE_AREA_RIGHT_ENV: &str = "SHADOW_BLITZ_SAFE_AREA_RIGHT";
const LEGACY_SAFE_AREA_TOP_ENV: &str = "SHADOW_BLITZ_SAFE_AREA_TOP";
const LEGACY_SURFACE_HEIGHT_ENV: &str = "SHADOW_BLITZ_SURFACE_HEIGHT";
const LEGACY_SURFACE_WIDTH_ENV: &str = "SHADOW_BLITZ_SURFACE_WIDTH";
const LEGACY_UNDECORATED_ENV: &str = "SHADOW_BLITZ_UNDECORATED";
const LEGACY_WAYLAND_APP_ID_ENV: &str = "SHADOW_BLITZ_WAYLAND_APP_ID";
const LEGACY_WAYLAND_INSTANCE_NAME_ENV: &str = "SHADOW_BLITZ_WAYLAND_INSTANCE_NAME";

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AppSafeAreaInsets {
    pub left: u32,
    pub top: u32,
    pub right: u32,
    pub bottom: u32,
}

impl AppSafeAreaInsets {
    fn from_env() -> Self {
        Self {
            left: env_u32_allow_zero_any(&[SAFE_AREA_LEFT_ENV, LEGACY_SAFE_AREA_LEFT_ENV])
                .unwrap_or(0),
            top: env_u32_allow_zero_any(&[SAFE_AREA_TOP_ENV, LEGACY_SAFE_AREA_TOP_ENV])
                .unwrap_or(0),
            right: env_u32_allow_zero_any(&[SAFE_AREA_RIGHT_ENV, LEGACY_SAFE_AREA_RIGHT_ENV])
                .unwrap_or(0),
            bottom: env_u32_allow_zero_any(&[SAFE_AREA_BOTTOM_ENV, LEGACY_SAFE_AREA_BOTTOM_ENV])
                .unwrap_or(0),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AppWindowMetrics {
    pub surface_width: u32,
    pub surface_height: u32,
    pub safe_area_insets: AppSafeAreaInsets,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AppWindowDefaults<'a> {
    pub title: &'a str,
    pub surface_width: u32,
    pub surface_height: u32,
    pub undecorated: bool,
    pub wayland_app_id: Option<&'a str>,
    pub wayland_instance_name: Option<&'a str>,
}

impl<'a> AppWindowDefaults<'a> {
    pub const fn new(title: &'a str, surface_width: u32, surface_height: u32) -> Self {
        Self {
            title,
            surface_width,
            surface_height,
            undecorated: false,
            wayland_app_id: None,
            wayland_instance_name: None,
        }
    }

    pub const fn with_undecorated(mut self, value: bool) -> Self {
        self.undecorated = value;
        self
    }

    pub const fn with_wayland_app_id(mut self, value: &'a str) -> Self {
        self.wayland_app_id = Some(value);
        self
    }

    pub const fn with_wayland_instance_name(mut self, value: &'a str) -> Self {
        self.wayland_instance_name = Some(value);
        self
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppWindowEnvironment {
    pub title: String,
    pub surface_width: u32,
    pub surface_height: u32,
    pub safe_area_insets: AppSafeAreaInsets,
    pub undecorated: bool,
    pub wayland_app_id: Option<String>,
    pub wayland_instance_name: Option<String>,
}

impl AppWindowEnvironment {
    pub fn from_env(defaults: AppWindowDefaults<'_>) -> Self {
        let wayland_app_id = env_override_any(&[WAYLAND_APP_ID_ENV, LEGACY_WAYLAND_APP_ID_ENV])
            .or_else(|| defaults.wayland_app_id.map(str::to_owned));
        let wayland_instance_name =
            env_override_any(&[WAYLAND_INSTANCE_NAME_ENV, LEGACY_WAYLAND_INSTANCE_NAME_ENV])
                .or_else(|| defaults.wayland_instance_name.map(str::to_owned))
                .or_else(|| {
                    wayland_app_id
                        .as_deref()
                        .map(derive_wayland_instance_name)
                        .filter(|value| !value.is_empty())
                });

        Self {
            title: env_override_any(&[APP_TITLE_ENV, LEGACY_APP_TITLE_ENV])
                .unwrap_or_else(|| defaults.title.to_owned()),
            surface_width: env_u32_any(&[SURFACE_WIDTH_ENV, LEGACY_SURFACE_WIDTH_ENV])
                .unwrap_or(defaults.surface_width),
            surface_height: env_u32_any(&[SURFACE_HEIGHT_ENV, LEGACY_SURFACE_HEIGHT_ENV])
                .unwrap_or(defaults.surface_height),
            safe_area_insets: AppSafeAreaInsets::from_env(),
            undecorated: defaults.undecorated
                || env_flag_any(&[UNDECORATED_ENV, LEGACY_UNDECORATED_ENV]),
            wayland_app_id,
            wayland_instance_name,
        }
    }

    pub fn metrics(&self) -> AppWindowMetrics {
        AppWindowMetrics {
            surface_width: self.surface_width,
            surface_height: self.surface_height,
            safe_area_insets: self.safe_area_insets,
        }
    }
}

pub fn app_window_metrics_from_env() -> Option<AppWindowMetrics> {
    Some(AppWindowMetrics {
        surface_width: env_u32_any(&[SURFACE_WIDTH_ENV, LEGACY_SURFACE_WIDTH_ENV])?,
        surface_height: env_u32_any(&[SURFACE_HEIGHT_ENV, LEGACY_SURFACE_HEIGHT_ENV])?,
        safe_area_insets: AppSafeAreaInsets::from_env(),
    })
}

pub fn current_lifecycle_state() -> LifecycleState {
    let mut state = lifecycle_state_cell()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    if let Some(state) = *state {
        return state;
    }

    let current = lifecycle_state_from_env();
    *state = Some(current);
    current
}

pub fn platform_control_socket_path() -> Option<PathBuf> {
    env_override_any(&[
        APP_PLATFORM_CONTROL_SOCKET_ENV,
        LEGACY_APP_PLATFORM_CONTROL_SOCKET_ENV,
    ])
    .map(PathBuf::from)
}

#[cfg(unix)]
pub fn spawn_lifecycle_listener<F>(mut handler: F) -> io::Result<JoinHandle<()>>
where
    F: FnMut(LifecycleState) + Send + 'static,
{
    let Some(socket_path) = platform_control_socket_path() else {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            format!(
                "missing {} or {}",
                APP_PLATFORM_CONTROL_SOCKET_ENV, LEGACY_APP_PLATFORM_CONTROL_SOCKET_ENV
            ),
        ));
    };

    if socket_path.exists() {
        let _ = std::fs::remove_file(&socket_path);
    }

    let listener = UnixListener::bind(&socket_path)?;
    Ok(std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut stream = match stream {
                Ok(stream) => stream,
                Err(_) => continue,
            };

            let mut request = String::new();
            if stream.read_to_string(&mut request).is_err() {
                let _ = stream.write_all(b"error=read-failed\n");
                continue;
            }

            let response = match AppPlatformRequest::parse_line(&request) {
                Some(AppPlatformRequest::Lifecycle { state }) => {
                    update_current_lifecycle_state(state);
                    handler(state);
                    format!("ok\nhandled=1\nstate={}\n", state.as_str())
                }
                Some(AppPlatformRequest::Media { action }) => format!(
                    "ok\nhandled=0\nreason=unsupported-request\nrequest={}\n",
                    action.as_str()
                ),
                Some(AppPlatformRequest::Automation { action, .. }) => format!(
                    "ok\nhandled=0\nreason=unsupported-request\nrequest=automation:{action}\n"
                ),
                None => String::from("ok\nhandled=0\nreason=invalid-action\n"),
            };
            let _ = stream.write_all(response.as_bytes());
        }

        let _ = std::fs::remove_file(socket_path);
    }))
}

#[cfg(not(unix))]
pub fn spawn_lifecycle_listener<F>(_handler: F) -> io::Result<JoinHandle<()>>
where
    F: FnMut(LifecycleState) + Send + 'static,
{
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "lifecycle listener requires unix domain sockets",
    ))
}

fn derive_wayland_instance_name(app_id: &str) -> String {
    app_id
        .rsplit_once('.')
        .map(|(_, suffix)| suffix.to_owned())
        .unwrap_or_else(|| app_id.to_owned())
}

fn lifecycle_state_from_env() -> LifecycleState {
    env_override(APP_LIFECYCLE_STATE_ENV)
        .as_deref()
        .and_then(LifecycleState::parse)
        .unwrap_or(LifecycleState::Foreground)
}

fn lifecycle_state_cell() -> &'static Mutex<Option<LifecycleState>> {
    static STATE: OnceLock<Mutex<Option<LifecycleState>>> = OnceLock::new();
    STATE.get_or_init(|| Mutex::new(None))
}

fn update_current_lifecycle_state(state: LifecycleState) {
    let mut current = lifecycle_state_cell()
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    *current = Some(state);
}

fn env_override(key: &str) -> Option<String> {
    env::var(key)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn env_override_any(keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| env_override(key))
}

fn env_u32(key: &str) -> Option<u32> {
    env::var(key)
        .ok()
        .and_then(|value| value.trim().parse::<u32>().ok())
        .filter(|value| *value > 0)
}

fn env_u32_any(keys: &[&str]) -> Option<u32> {
    keys.iter().find_map(|key| env_u32(key))
}

fn env_u32_allow_zero(key: &str) -> Option<u32> {
    env::var(key)
        .ok()
        .and_then(|value| value.trim().parse::<u32>().ok())
}

fn env_u32_allow_zero_any(keys: &[&str]) -> Option<u32> {
    keys.iter().find_map(|key| env_u32_allow_zero(key))
}

fn env_flag(key: &str) -> bool {
    env::var_os(key).is_some()
}

fn env_flag_any(keys: &[&str]) -> bool {
    keys.iter().any(|key| env_flag(key))
}

#[cfg(test)]
mod tests {
    use std::sync::{Mutex, OnceLock};

    use super::{
        app_window_metrics_from_env, current_lifecycle_state, platform_control_socket_path,
        spawn_lifecycle_listener, AppSafeAreaInsets, AppWindowDefaults, AppWindowEnvironment,
        LifecycleState, APP_LIFECYCLE_STATE_ENV, APP_PLATFORM_CONTROL_SOCKET_ENV, APP_TITLE_ENV,
        LEGACY_APP_PLATFORM_CONTROL_SOCKET_ENV, LEGACY_APP_TITLE_ENV, LEGACY_SAFE_AREA_BOTTOM_ENV,
        LEGACY_SAFE_AREA_LEFT_ENV, LEGACY_SAFE_AREA_RIGHT_ENV, LEGACY_SAFE_AREA_TOP_ENV,
        LEGACY_SURFACE_HEIGHT_ENV, LEGACY_SURFACE_WIDTH_ENV, LEGACY_UNDECORATED_ENV,
        LEGACY_WAYLAND_APP_ID_ENV, LEGACY_WAYLAND_INSTANCE_NAME_ENV, SAFE_AREA_BOTTOM_ENV,
        SAFE_AREA_LEFT_ENV, SAFE_AREA_RIGHT_ENV, SAFE_AREA_TOP_ENV, SURFACE_HEIGHT_ENV,
        SURFACE_WIDTH_ENV, UNDECORATED_ENV, WAYLAND_APP_ID_ENV, WAYLAND_INSTANCE_NAME_ENV,
    };
    use shadow_runtime_protocol::AppPlatformRequest;

    #[cfg(unix)]
    use std::{
        io::{Read, Write},
        os::unix::net::UnixStream,
        time::Duration,
    };

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn clear_window_env() {
        for key in [
            APP_TITLE_ENV,
            SAFE_AREA_LEFT_ENV,
            SAFE_AREA_TOP_ENV,
            SAFE_AREA_RIGHT_ENV,
            SAFE_AREA_BOTTOM_ENV,
            SURFACE_WIDTH_ENV,
            SURFACE_HEIGHT_ENV,
            UNDECORATED_ENV,
            WAYLAND_APP_ID_ENV,
            WAYLAND_INSTANCE_NAME_ENV,
            APP_LIFECYCLE_STATE_ENV,
            APP_PLATFORM_CONTROL_SOCKET_ENV,
            LEGACY_APP_TITLE_ENV,
            LEGACY_APP_PLATFORM_CONTROL_SOCKET_ENV,
            LEGACY_SAFE_AREA_LEFT_ENV,
            LEGACY_SAFE_AREA_TOP_ENV,
            LEGACY_SAFE_AREA_RIGHT_ENV,
            LEGACY_SAFE_AREA_BOTTOM_ENV,
            LEGACY_SURFACE_WIDTH_ENV,
            LEGACY_SURFACE_HEIGHT_ENV,
            LEGACY_UNDECORATED_ENV,
            LEGACY_WAYLAND_APP_ID_ENV,
            LEGACY_WAYLAND_INSTANCE_NAME_ENV,
        ] {
            std::env::remove_var(key);
        }
        *super::lifecycle_state_cell()
            .lock()
            .expect("lifecycle state lock") = None;
    }

    fn defaults() -> AppWindowDefaults<'static> {
        AppWindowDefaults::new("Shadow Notes", 540, 1042)
            .with_wayland_app_id("dev.shadow.notes")
            .with_wayland_instance_name("notes-window")
    }

    #[test]
    fn window_env_uses_defaults_when_env_is_unset() {
        let _guard = env_lock().lock().expect("env lock");
        clear_window_env();

        let parsed = AppWindowEnvironment::from_env(defaults());
        assert_eq!(parsed.title, "Shadow Notes");
        assert_eq!(parsed.surface_width, 540);
        assert_eq!(parsed.surface_height, 1042);
        assert_eq!(parsed.safe_area_insets, AppSafeAreaInsets::default());
        assert!(!parsed.undecorated);
        assert_eq!(parsed.wayland_app_id.as_deref(), Some("dev.shadow.notes"));
        assert_eq!(
            parsed.wayland_instance_name.as_deref(),
            Some("notes-window")
        );
    }

    #[test]
    fn window_env_honors_undecorated_default() {
        let _guard = env_lock().lock().expect("env lock");
        clear_window_env();

        let parsed = AppWindowEnvironment::from_env(defaults().with_undecorated(true));
        assert!(parsed.undecorated);
    }

    #[test]
    fn window_env_honors_shadow_env_overrides() {
        let _guard = env_lock().lock().expect("env lock");
        clear_window_env();
        std::env::set_var(APP_TITLE_ENV, " Custom Title ");
        std::env::set_var(SURFACE_WIDTH_ENV, "720");
        std::env::set_var(SURFACE_HEIGHT_ENV, "1280");
        std::env::set_var(SAFE_AREA_LEFT_ENV, "12");
        std::env::set_var(SAFE_AREA_TOP_ENV, "24");
        std::env::set_var(SAFE_AREA_RIGHT_ENV, "18");
        std::env::set_var(SAFE_AREA_BOTTOM_ENV, "30");
        std::env::set_var(UNDECORATED_ENV, "");
        std::env::set_var(WAYLAND_APP_ID_ENV, "dev.shadow.custom");
        std::env::set_var(WAYLAND_INSTANCE_NAME_ENV, "custom-instance");

        let parsed = AppWindowEnvironment::from_env(defaults());
        assert_eq!(parsed.title, "Custom Title");
        assert_eq!(parsed.surface_width, 720);
        assert_eq!(parsed.surface_height, 1280);
        assert_eq!(
            parsed.safe_area_insets,
            AppSafeAreaInsets {
                left: 12,
                top: 24,
                right: 18,
                bottom: 30,
            }
        );
        assert!(parsed.undecorated);
        assert_eq!(parsed.wayland_app_id.as_deref(), Some("dev.shadow.custom"));
        assert_eq!(
            parsed.wayland_instance_name.as_deref(),
            Some("custom-instance")
        );
    }

    #[test]
    fn window_env_derives_wayland_instance_name_from_app_id() {
        let _guard = env_lock().lock().expect("env lock");
        clear_window_env();
        std::env::set_var(WAYLAND_APP_ID_ENV, "dev.shadow.timeline");

        let parsed = AppWindowEnvironment::from_env(AppWindowDefaults::new("Timeline", 540, 1042));
        assert_eq!(
            parsed.wayland_app_id.as_deref(),
            Some("dev.shadow.timeline")
        );
        assert_eq!(parsed.wayland_instance_name.as_deref(), Some("timeline"));
    }

    #[test]
    fn window_env_falls_back_to_legacy_blitz_env() {
        let _guard = env_lock().lock().expect("env lock");
        clear_window_env();
        std::env::set_var(LEGACY_APP_TITLE_ENV, " Legacy Title ");
        std::env::set_var(LEGACY_SAFE_AREA_LEFT_ENV, "4");
        std::env::set_var(LEGACY_SAFE_AREA_TOP_ENV, "6");
        std::env::set_var(LEGACY_SAFE_AREA_RIGHT_ENV, "8");
        std::env::set_var(LEGACY_SAFE_AREA_BOTTOM_ENV, "10");
        std::env::set_var(LEGACY_SURFACE_WIDTH_ENV, "900");
        std::env::set_var(LEGACY_SURFACE_HEIGHT_ENV, "1600");
        std::env::set_var(LEGACY_UNDECORATED_ENV, "");
        std::env::set_var(LEGACY_WAYLAND_APP_ID_ENV, "dev.shadow.legacy");
        std::env::set_var(LEGACY_WAYLAND_INSTANCE_NAME_ENV, "legacy-instance");

        let parsed = AppWindowEnvironment::from_env(defaults());
        assert_eq!(parsed.title, "Legacy Title");
        assert_eq!(parsed.surface_width, 900);
        assert_eq!(parsed.surface_height, 1600);
        assert_eq!(
            parsed.safe_area_insets,
            AppSafeAreaInsets {
                left: 4,
                top: 6,
                right: 8,
                bottom: 10,
            }
        );
        assert!(parsed.undecorated);
        assert_eq!(parsed.wayland_app_id.as_deref(), Some("dev.shadow.legacy"));
        assert_eq!(
            parsed.wayland_instance_name.as_deref(),
            Some("legacy-instance")
        );
    }

    #[test]
    fn app_window_metrics_reads_launcher_seeded_surface_and_safe_area() {
        let _guard = env_lock().lock().expect("env lock");
        clear_window_env();
        std::env::set_var(SURFACE_WIDTH_ENV, "540");
        std::env::set_var(SURFACE_HEIGHT_ENV, "1042");
        std::env::set_var(SAFE_AREA_TOP_ENV, "16");

        assert_eq!(
            app_window_metrics_from_env(),
            Some(super::AppWindowMetrics {
                surface_width: 540,
                surface_height: 1042,
                safe_area_insets: AppSafeAreaInsets {
                    left: 0,
                    top: 16,
                    right: 0,
                    bottom: 0,
                },
            })
        );
    }

    #[test]
    fn lifecycle_state_defaults_to_foreground() {
        let _guard = env_lock().lock().expect("env lock");
        clear_window_env();

        assert_eq!(current_lifecycle_state(), LifecycleState::Foreground);
    }

    #[test]
    fn lifecycle_state_honors_env_override() {
        let _guard = env_lock().lock().expect("env lock");
        clear_window_env();
        std::env::set_var(APP_LIFECYCLE_STATE_ENV, "background");

        assert_eq!(current_lifecycle_state(), LifecycleState::Background);
    }

    #[test]
    fn platform_control_socket_path_honors_shadow_env() {
        let _guard = env_lock().lock().expect("env lock");
        clear_window_env();
        std::env::set_var(APP_PLATFORM_CONTROL_SOCKET_ENV, "/tmp/shadow-platform.sock");

        assert_eq!(
            platform_control_socket_path()
                .expect("platform control path")
                .to_string_lossy(),
            "/tmp/shadow-platform.sock"
        );
    }

    #[test]
    fn platform_control_socket_path_falls_back_to_legacy_env() {
        let _guard = env_lock().lock().expect("env lock");
        clear_window_env();
        std::env::set_var(
            LEGACY_APP_PLATFORM_CONTROL_SOCKET_ENV,
            "/tmp/shadow-legacy-platform.sock",
        );

        assert_eq!(
            platform_control_socket_path()
                .expect("platform control path")
                .to_string_lossy(),
            "/tmp/shadow-legacy-platform.sock"
        );
    }

    #[cfg(unix)]
    #[test]
    fn lifecycle_listener_receives_background_event() {
        let _guard = env_lock().lock().expect("env lock");
        clear_window_env();
        let socket_path = std::env::temp_dir().join(format!(
            "shadow-sdk-lifecycle-{}-{}.sock",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("unix epoch")
                .as_nanos()
        ));
        std::env::set_var(APP_PLATFORM_CONTROL_SOCKET_ENV, &socket_path);

        let observed = std::sync::Arc::new(Mutex::new(Vec::new()));
        let observed_for_thread = observed.clone();
        let _listener = spawn_lifecycle_listener(move |state| {
            observed_for_thread
                .lock()
                .expect("observed lock")
                .push(state);
        })
        .expect("spawn lifecycle listener");

        for _ in 0..50 {
            if socket_path.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }

        let mut stream = UnixStream::connect(&socket_path).expect("connect lifecycle socket");
        stream
            .write_all(
                AppPlatformRequest::Lifecycle {
                    state: LifecycleState::Background,
                }
                .encode_line()
                .as_bytes(),
            )
            .expect("write lifecycle request");
        stream
            .shutdown(std::net::Shutdown::Write)
            .expect("shutdown write");

        let mut response = String::new();
        stream
            .read_to_string(&mut response)
            .expect("read lifecycle response");
        assert_eq!(response, "ok\nhandled=1\nstate=background\n");

        for _ in 0..50 {
            if observed.lock().expect("observed lock").len() == 1 {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(
            observed.lock().expect("observed lock").as_slice(),
            &[LifecycleState::Background]
        );
        assert_eq!(current_lifecycle_state(), LifecycleState::Background);

        let _ = std::fs::remove_file(socket_path);
    }
}
