use std::{env, fmt, path::PathBuf};

use shadow_compositor_common::launch::{
    first_env_value, parse_env_assignments, runtime_dir_from_env_or, InvalidEnvSpec,
};
use shadow_ui_core::app::{self, AppId};

use crate::{DEFAULT_TOPLEVEL_HEIGHT, DEFAULT_TOPLEVEL_WIDTH};

const DEFAULT_FRAME_ARTIFACT_PATH: &str = "/shadow-frame.ppm";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum StartupAction {
    Client,
    App { app_id: AppId },
    Shell { start_app_id: Option<AppId> },
}

impl StartupAction {
    pub(crate) fn shell_enabled(self) -> bool {
        matches!(self, Self::Shell { .. })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum TransportRequest {
    Auto,
    Socket,
    Direct,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct GuestStartupConfig {
    pub(crate) startup_action: StartupAction,
    pub(crate) client: GuestClientConfig,
    pub(crate) transport: TransportRequest,
    pub(crate) exit_on_client_disconnect: bool,
    pub(crate) exit_on_first_window: bool,
    pub(crate) exit_on_first_frame: bool,
    pub(crate) exit_on_first_dma_buffer: bool,
    pub(crate) selftest_drm: bool,
    pub(crate) boot_splash_drm: bool,
    pub(crate) drm_enabled: bool,
    pub(crate) log_touch_geometry: bool,
    pub(crate) touch_signal_path: Option<PathBuf>,
    pub(crate) frame_artifact_path: PathBuf,
    pub(crate) toplevel_width: i32,
    pub(crate) toplevel_height: i32,
    pub(crate) keyboard_seat_enabled: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct GuestClientConfig {
    pub(crate) app_client_path: String,
    pub(crate) runtime_dir: PathBuf,
    pub(crate) runtime_host_binary_path: Option<std::ffi::OsString>,
    pub(crate) env_assignments: Vec<(String, String)>,
    pub(crate) exit_on_configure: bool,
    pub(crate) linger_ms: Option<u64>,
}

impl GuestStartupConfig {
    pub(crate) fn from_env() -> Result<Self, ConfigError> {
        let start_app_id = parse_start_app_id_env()?;
        let shell_start_app_id = parse_shell_start_app_id_env()?;
        let startup_action = match start_app_id {
            Some(app_id) if app_id == app::SHELL_APP_ID => StartupAction::Shell {
                start_app_id: shell_start_app_id,
            },
            Some(app_id) => StartupAction::App { app_id },
            None => StartupAction::Client,
        };

        Ok(Self {
            startup_action,
            client: GuestClientConfig {
                app_client_path: first_env_value(&["SHADOW_APP_CLIENT", "SHADOW_GUEST_CLIENT"])
                    .unwrap_or_else(crate::default_guest_client_path),
                runtime_dir: runtime_dir_from_env_or(|| "/data/local/tmp/shadow-runtime".into()),
                runtime_host_binary_path: env::var_os("SHADOW_RUNTIME_HOST_BINARY_PATH"),
                env_assignments: env::var("SHADOW_GUEST_CLIENT_ENV")
                    .ok()
                    .map(|value| parse_env_assignments(&value))
                    .transpose()
                    .map_err(ConfigError::InvalidGuestClientEnv)?
                    .unwrap_or_default(),
                exit_on_configure: env_flag("SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE"),
                linger_ms: parse_u64_env("SHADOW_GUEST_CLIENT_LINGER_MS")?,
            },
            transport: parse_transport_request()?,
            exit_on_client_disconnect: env_flag(
                "SHADOW_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT",
            ) && !startup_action.shell_enabled(),
            exit_on_first_window: env_flag("SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_WINDOW"),
            exit_on_first_frame: env_flag("SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME"),
            exit_on_first_dma_buffer: env_flag("SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_DMA_BUFFER"),
            selftest_drm: env_flag("SHADOW_GUEST_COMPOSITOR_SELFTEST_DRM"),
            boot_splash_drm: env_flag("SHADOW_GUEST_COMPOSITOR_BOOT_SPLASH_DRM"),
            drm_enabled: env_flag("SHADOW_GUEST_COMPOSITOR_ENABLE_DRM"),
            log_touch_geometry: env_flag("SHADOW_GUEST_LOG_TOUCH_GEOMETRY"),
            touch_signal_path: env::var_os("SHADOW_GUEST_TOUCH_SIGNAL_PATH")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from),
            frame_artifact_path: env::var_os("SHADOW_GUEST_FRAME_PATH")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(DEFAULT_FRAME_ARTIFACT_PATH)),
            toplevel_width: parse_positive_i32_env(
                "SHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH",
                DEFAULT_TOPLEVEL_WIDTH,
            )?,
            toplevel_height: parse_positive_i32_env(
                "SHADOW_GUEST_COMPOSITOR_TOPLEVEL_HEIGHT",
                DEFAULT_TOPLEVEL_HEIGHT,
            )?,
            keyboard_seat_enabled: false,
        })
    }
}

fn env_flag(key: &str) -> bool {
    env::var_os(key).is_some()
}

fn parse_transport_request() -> Result<TransportRequest, ConfigError> {
    let requested =
        env::var("SHADOW_GUEST_COMPOSITOR_TRANSPORT").unwrap_or_else(|_| "auto".to_string());
    match requested.as_str() {
        "auto" => Ok(TransportRequest::Auto),
        "socket" => Ok(TransportRequest::Socket),
        "direct" => Ok(TransportRequest::Direct),
        _ => Err(ConfigError::InvalidTransport { requested }),
    }
}

fn parse_start_app_id_env() -> Result<Option<AppId>, ConfigError> {
    let key = "SHADOW_GUEST_START_APP_ID";
    let Some(value) = env::var(key).ok().map(|value| value.trim().to_string()) else {
        return Ok(None);
    };
    if value.is_empty() {
        return Ok(None);
    }
    if value == app::SHELL_APP_ID.as_str() {
        return Ok(Some(app::SHELL_APP_ID));
    }
    app::find_app_by_str(&value)
        .map(|app| Some(app.id))
        .ok_or_else(|| ConfigError::InvalidAppId { key, value })
}

fn parse_shell_start_app_id_env() -> Result<Option<AppId>, ConfigError> {
    let key = "SHADOW_GUEST_SHELL_START_APP_ID";
    let Some(value) = env::var(key).ok().map(|value| value.trim().to_string()) else {
        return Ok(None);
    };
    if value.is_empty() || value == app::SHELL_APP_ID.as_str() {
        return Ok(None);
    }
    app::find_app_by_str(&value)
        .map(|app| Some(app.id))
        .ok_or_else(|| ConfigError::InvalidAppId { key, value })
}

fn parse_positive_i32_env(key: &'static str, default: i32) -> Result<i32, ConfigError> {
    let Some(value) = env::var(key).ok().map(|value| value.trim().to_string()) else {
        return Ok(default);
    };
    if value.is_empty() {
        return Ok(default);
    }
    let parsed = value
        .parse::<i32>()
        .map_err(|_| ConfigError::InvalidPositiveI32 {
            key,
            value: value.clone(),
        })?;
    if parsed <= 0 {
        return Err(ConfigError::InvalidPositiveI32 { key, value });
    }
    Ok(parsed)
}

fn parse_u64_env(key: &'static str) -> Result<Option<u64>, ConfigError> {
    let Some(value) = env::var(key).ok().map(|value| value.trim().to_string()) else {
        return Ok(None);
    };
    if value.is_empty() {
        return Ok(None);
    }
    value
        .parse::<u64>()
        .map(Some)
        .map_err(|_| ConfigError::InvalidU64 { key, value })
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum ConfigError {
    InvalidAppId { key: &'static str, value: String },
    InvalidGuestClientEnv(InvalidEnvSpec),
    InvalidPositiveI32 { key: &'static str, value: String },
    InvalidTransport { requested: String },
    InvalidU64 { key: &'static str, value: String },
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidAppId { key, value } => {
                write!(f, "invalid {key}={value:?}: unknown app id")
            }
            Self::InvalidGuestClientEnv(error) => {
                write!(f, "invalid SHADOW_GUEST_CLIENT_ENV: {error}")
            }
            Self::InvalidPositiveI32 { key, value } => {
                write!(f, "invalid {key}={value:?}: expected a positive integer")
            }
            Self::InvalidTransport { requested } => {
                write!(
                    f,
                    "invalid SHADOW_GUEST_COMPOSITOR_TRANSPORT={requested:?}: expected auto, socket, or direct"
                )
            }
            Self::InvalidU64 { key, value } => {
                write!(f, "invalid {key}={value:?}: expected an unsigned integer")
            }
        }
    }
}

impl std::error::Error for ConfigError {}

#[cfg(test)]
mod tests {
    use std::sync::{Mutex, OnceLock};

    use shadow_ui_core::app::{CAMERA_APP_ID, TIMELINE_APP_ID};

    use super::{GuestStartupConfig, StartupAction, TransportRequest};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn with_env(updates: Vec<(&str, Option<&str>)>, check: impl FnOnce()) {
        let _guard = env_lock().lock().unwrap_or_else(|error| error.into_inner());
        let mut updates_with_defaults = vec![
            ("SHADOW_GUEST_START_APP_ID", None),
            ("SHADOW_GUEST_SHELL_START_APP_ID", None),
            ("SHADOW_GUEST_COMPOSITOR_TRANSPORT", None),
            ("SHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH", None),
            ("SHADOW_GUEST_COMPOSITOR_TOPLEVEL_HEIGHT", None),
            ("SHADOW_GUEST_CLIENT_ENV", None),
            ("SHADOW_GUEST_CLIENT_LINGER_MS", None),
        ];
        updates_with_defaults.extend(updates);

        let previous = updates_with_defaults
            .iter()
            .map(|(key, _)| (*key, std::env::var_os(key)))
            .collect::<Vec<_>>();

        for (key, value) in &updates_with_defaults {
            match value {
                Some(value) => unsafe { std::env::set_var(key, value) },
                None => unsafe { std::env::remove_var(key) },
            }
        }

        check();

        for (key, value) in previous {
            match value {
                Some(value) => unsafe { std::env::set_var(key, value) },
                None => unsafe { std::env::remove_var(key) },
            }
        }
    }

    #[test]
    fn config_uses_shell_mode_when_start_app_is_shell() {
        with_env(
            vec![
                ("SHADOW_GUEST_START_APP_ID", Some("shell")),
                ("SHADOW_GUEST_SHELL_START_APP_ID", Some("timeline")),
            ],
            || {
                let config = GuestStartupConfig::from_env().expect("shell config");
                assert_eq!(
                    config.startup_action,
                    StartupAction::Shell {
                        start_app_id: Some(TIMELINE_APP_ID),
                    }
                );
            },
        );
    }

    #[test]
    fn config_uses_direct_app_launch_for_non_shell_start_app() {
        with_env(vec![("SHADOW_GUEST_START_APP_ID", Some("camera"))], || {
            let config = GuestStartupConfig::from_env().expect("app config");
            assert_eq!(
                config.startup_action,
                StartupAction::App {
                    app_id: CAMERA_APP_ID,
                }
            );
        });
    }

    #[test]
    fn config_rejects_invalid_transport() {
        with_env(
            vec![("SHADOW_GUEST_COMPOSITOR_TRANSPORT", Some("bogus"))],
            || {
                let error = GuestStartupConfig::from_env().expect_err("invalid transport");
                assert_eq!(
                    error.to_string(),
                    "invalid SHADOW_GUEST_COMPOSITOR_TRANSPORT=\"bogus\": expected auto, socket, or direct"
                );
            },
        );
    }

    #[test]
    fn config_rejects_invalid_toplevel_dimensions() {
        with_env(
            vec![("SHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH", Some("0"))],
            || {
                let error = GuestStartupConfig::from_env().expect_err("invalid width");
                assert_eq!(
                    error.to_string(),
                    "invalid SHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH=\"0\": expected a positive integer"
                );
            },
        );
    }

    #[test]
    fn config_defaults_transport_to_auto() {
        with_env(vec![], || {
            let config = GuestStartupConfig::from_env().expect("default config");
            assert_eq!(config.transport, TransportRequest::Auto);
        });
    }

    #[test]
    fn config_rejects_invalid_guest_client_env() {
        with_env(vec![("SHADOW_GUEST_CLIENT_ENV", Some("A=1 nope"))], || {
            let error = GuestStartupConfig::from_env().expect_err("invalid guest client env");
            assert_eq!(
                error.to_string(),
                "invalid SHADOW_GUEST_CLIENT_ENV: invalid env assignment \"nope\": missing '='"
            );
        });
    }

    #[test]
    fn config_rejects_invalid_client_linger_ms() {
        with_env(vec![("SHADOW_GUEST_CLIENT_LINGER_MS", Some("abc"))], || {
            let error = GuestStartupConfig::from_env().expect_err("invalid linger");
            assert_eq!(
                error.to_string(),
                "invalid SHADOW_GUEST_CLIENT_LINGER_MS=\"abc\": expected an unsigned integer"
            );
        });
    }
}
