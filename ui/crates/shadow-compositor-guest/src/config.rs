use std::{
    env,
    ffi::OsString,
    fmt, fs, io,
    path::{Path, PathBuf},
};

use serde::Deserialize;
use shadow_compositor_common::launch::{
    first_env_value, parse_env_assignments, runtime_dir_from_env_or, InvalidEnvSpec,
};
use shadow_ui_core::app::{self, AppId};

use crate::{DEFAULT_TOPLEVEL_HEIGHT, DEFAULT_TOPLEVEL_WIDTH};

const DEFAULT_FRAME_ARTIFACT_PATH: &str = "/shadow-frame.ppm";
const DEFAULT_RUNTIME_DIR: &str = "/data/local/tmp/shadow-runtime";
const DEFAULT_BACKGROUND_APP_RESIDENT_LIMIT: usize = 3;

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

    pub(crate) fn needs_control_socket(self) -> bool {
        !matches!(self, Self::Shell { start_app_id: None })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum TransportRequest {
    Auto,
    Socket,
    Direct,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum DmabufFormatProfile {
    Default,
    LinearOnly,
    ImplicitOnly,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct GuestStartupConfig {
    pub(crate) startup_action: StartupAction,
    pub(crate) client: GuestClientConfig,
    pub(crate) transport: TransportRequest,
    pub(crate) exit_on_client_disconnect: bool,
    pub(crate) exit_on_first_frame: bool,
    pub(crate) exit_on_first_dma_buffer: bool,
    pub(crate) boot_splash_drm: bool,
    pub(crate) drm_enabled: bool,
    pub(crate) gpu_shell: bool,
    pub(crate) strict_gpu_resident: bool,
    pub(crate) dmabuf_global_enabled: bool,
    pub(crate) dmabuf_feedback_enabled: bool,
    pub(crate) dmabuf_format_profile: DmabufFormatProfile,
    pub(crate) touch_signal_path: Option<PathBuf>,
    pub(crate) touch_latency_trace: bool,
    pub(crate) synthetic_tap: Option<GuestSyntheticTapConfig>,
    pub(crate) exit_after_touch_present: bool,
    pub(crate) frame_snapshot_cache_enabled: bool,
    pub(crate) frame_checksum_enabled: bool,
    pub(crate) frame_artifact_path: PathBuf,
    pub(crate) frame_artifacts_enabled: bool,
    pub(crate) frame_artifact_every_frame: bool,
    pub(crate) toplevel_width: i32,
    pub(crate) toplevel_height: i32,
    pub(crate) keyboard_seat_enabled: bool,
    pub(crate) software_keyboard_enabled: bool,
    pub(crate) background_app_resident_limit: usize,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct GuestSyntheticTapConfig {
    pub(crate) normalized_x_millis: u16,
    pub(crate) normalized_y_millis: u16,
    pub(crate) after_first_frame_delay_ms: u64,
    pub(crate) hold_ms: u64,
    pub(crate) after_app_id: Option<AppId>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct GuestClientConfig {
    pub(crate) app_client_path: String,
    pub(crate) runtime_dir: PathBuf,
    pub(crate) system_binary_path: Option<OsString>,
    pub(crate) env_assignments: Vec<(String, String)>,
    pub(crate) exit_on_configure: bool,
    pub(crate) linger_ms: Option<u64>,
}

impl GuestStartupConfig {
    pub(crate) fn from_env() -> Result<Self, ConfigError> {
        let session_config_path = session_config_path_from_env();
        let mut config = match &session_config_path {
            Some(path) => Self::from_session_config_file(path)?,
            None => Self::defaults(),
        };
        config.apply_env_overlay(session_config_path.is_some())?;
        Ok(config)
    }

    fn defaults() -> Self {
        let keyboard_seat_enabled = false;
        Self {
            startup_action: StartupAction::Client,
            client: GuestClientConfig::defaults(),
            transport: TransportRequest::Auto,
            exit_on_client_disconnect: false,
            exit_on_first_frame: false,
            exit_on_first_dma_buffer: false,
            boot_splash_drm: false,
            drm_enabled: false,
            gpu_shell: false,
            strict_gpu_resident: false,
            dmabuf_global_enabled: true,
            dmabuf_feedback_enabled: false,
            dmabuf_format_profile: DmabufFormatProfile::Default,
            touch_signal_path: None,
            touch_latency_trace: false,
            synthetic_tap: None,
            exit_after_touch_present: false,
            frame_snapshot_cache_enabled: false,
            frame_checksum_enabled: false,
            frame_artifact_path: default_frame_artifact_path(),
            frame_artifacts_enabled: false,
            frame_artifact_every_frame: false,
            toplevel_width: DEFAULT_TOPLEVEL_WIDTH,
            toplevel_height: DEFAULT_TOPLEVEL_HEIGHT,
            keyboard_seat_enabled,
            software_keyboard_enabled: default_software_keyboard_enabled(keyboard_seat_enabled),
            background_app_resident_limit: DEFAULT_BACKGROUND_APP_RESIDENT_LIMIT,
        }
    }

    fn from_session_config_file(path: &Path) -> Result<Self, ConfigError> {
        let contents =
            fs::read_to_string(path).map_err(|source| ConfigError::ReadSessionConfig {
                path: path.to_path_buf(),
                source,
            })?;
        let config =
            serde_json::from_str::<GuestStartupConfigFile>(&contents).map_err(|source| {
                ConfigError::ParseSessionConfig {
                    path: path.to_path_buf(),
                    source,
                }
            })?;
        config.into_startup_config()
    }

    fn apply_env_overlay(&mut self, file_backed: bool) -> Result<(), ConfigError> {
        if let Ok(_) = env::var("SHADOW_GUEST_START_APP_ID") {
            self.startup_action = startup_action_from_env()?;
        } else if let Ok(_) = env::var("SHADOW_GUEST_SHELL_START_APP_ID") {
            if matches!(self.startup_action, StartupAction::Shell { .. }) {
                self.startup_action = StartupAction::Shell {
                    start_app_id: parse_shell_start_app_id_env()?,
                };
            }
        }

        let client_override_keys: &[&str] = if file_backed {
            &["SHADOW_APP_CLIENT"]
        } else {
            &["SHADOW_APP_CLIENT", "SHADOW_GUEST_CLIENT"]
        };
        if let Some(app_client_path) = first_env_value(client_override_keys) {
            self.client.app_client_path = app_client_path;
        }
        if !file_backed && env::var_os("XDG_RUNTIME_DIR").is_some() {
            self.client.runtime_dir = runtime_dir_from_env_or(default_runtime_dir);
        }
        if env::var_os("SHADOW_SYSTEM_BINARY_PATH").is_some() {
            self.client.system_binary_path = env::var_os("SHADOW_SYSTEM_BINARY_PATH");
        }
        if let Ok(value) = env::var("SHADOW_GUEST_CLIENT_ENV") {
            let overlay =
                parse_env_assignments(&value).map_err(ConfigError::InvalidGuestClientEnv)?;
            merge_env_assignments(&mut self.client.env_assignments, overlay);
        }
        if env_flag("SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE") {
            self.client.exit_on_configure = true;
        }
        if let Ok(_) = env::var("SHADOW_GUEST_CLIENT_LINGER_MS") {
            self.client.linger_ms = parse_u64_env("SHADOW_GUEST_CLIENT_LINGER_MS")?;
        }
        if let Ok(_) = env::var("SHADOW_GUEST_COMPOSITOR_TRANSPORT") {
            self.transport = parse_transport_request()?;
        }
        if env_flag("SHADOW_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT") {
            self.exit_on_client_disconnect = !self.startup_action.shell_enabled();
        }
        if env_flag("SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME") {
            self.exit_on_first_frame = true;
        }
        if env_flag("SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_DMA_BUFFER") {
            self.exit_on_first_dma_buffer = true;
        }
        if env_flag("SHADOW_GUEST_COMPOSITOR_BOOT_SPLASH_DRM") {
            self.boot_splash_drm = true;
        }
        if env_flag("SHADOW_GUEST_COMPOSITOR_ENABLE_DRM") {
            self.drm_enabled = true;
        }
        if env_flag("SHADOW_GUEST_COMPOSITOR_GPU_SHELL") {
            self.gpu_shell = true;
        }
        if env_flag("SHADOW_GUEST_COMPOSITOR_STRICT_GPU_RESIDENT") {
            self.strict_gpu_resident = true;
        }
        if env_flag("SHADOW_GUEST_COMPOSITOR_DISABLE_DMABUF_GLOBAL") {
            self.dmabuf_global_enabled = false;
        }
        if env_flag("SHADOW_GUEST_COMPOSITOR_DMABUF_FEEDBACK") {
            self.dmabuf_feedback_enabled = true;
        }
        if let Ok(_) = env::var("SHADOW_GUEST_COMPOSITOR_DMABUF_FORMAT_PROFILE") {
            self.dmabuf_format_profile = parse_dmabuf_format_profile()?;
        }
        if env::var_os("SHADOW_GUEST_TOUCH_SIGNAL_PATH").is_some() {
            self.touch_signal_path = env::var_os("SHADOW_GUEST_TOUCH_SIGNAL_PATH")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from);
        }
        if env_flag("SHADOW_GUEST_TOUCH_LATENCY_TRACE") {
            self.touch_latency_trace = true;
        }
        if env_flag("SHADOW_GUEST_FRAME_SNAPSHOT_CACHE") {
            self.frame_snapshot_cache_enabled = true;
        }
        if env_flag("SHADOW_GUEST_FRAME_CHECKSUM") {
            self.frame_checksum_enabled = true;
        }
        if env::var_os("SHADOW_GUEST_FRAME_PATH").is_some() {
            self.frame_artifact_path = env::var_os("SHADOW_GUEST_FRAME_PATH")
                .filter(|value| !value.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(default_frame_artifact_path);
        }
        if env_flag("SHADOW_GUEST_FRAME_ARTIFACTS") {
            self.frame_artifacts_enabled = true;
        }
        if env_flag("SHADOW_GUEST_FRAME_WRITE_EVERY_FRAME") {
            self.frame_artifact_every_frame = true;
        }
        if let Ok(_) = env::var("SHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH") {
            self.toplevel_width = parse_positive_i32_env(
                "SHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH",
                DEFAULT_TOPLEVEL_WIDTH,
            )?;
        }
        if let Ok(_) = env::var("SHADOW_GUEST_COMPOSITOR_TOPLEVEL_HEIGHT") {
            self.toplevel_height = parse_positive_i32_env(
                "SHADOW_GUEST_COMPOSITOR_TOPLEVEL_HEIGHT",
                DEFAULT_TOPLEVEL_HEIGHT,
            )?;
        }
        if let Ok(_) = env::var("SHADOW_BLITZ_SOFTWARE_KEYBOARD") {
            self.software_keyboard_enabled =
                parse_software_keyboard_enabled(self.keyboard_seat_enabled);
        }
        if let Ok(_) = env::var("SHADOW_GUEST_COMPOSITOR_BACKGROUND_APP_LIMIT") {
            self.background_app_resident_limit = parse_usize_env(
                "SHADOW_GUEST_COMPOSITOR_BACKGROUND_APP_LIMIT",
                DEFAULT_BACKGROUND_APP_RESIDENT_LIMIT,
            )?;
        }

        Ok(())
    }
}

impl GuestClientConfig {
    fn defaults() -> Self {
        Self {
            app_client_path: crate::default_guest_client_path(),
            runtime_dir: default_runtime_dir(),
            system_binary_path: None,
            env_assignments: Vec::new(),
            exit_on_configure: false,
            linger_ms: None,
        }
    }
}

fn env_flag(key: &str) -> bool {
    env::var_os(key).is_some()
}

fn session_config_path_from_env() -> Option<PathBuf> {
    env::var_os("SHADOW_GUEST_SESSION_CONFIG")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn default_runtime_dir() -> PathBuf {
    PathBuf::from(DEFAULT_RUNTIME_DIR)
}

fn default_frame_artifact_path() -> PathBuf {
    PathBuf::from(DEFAULT_FRAME_ARTIFACT_PATH)
}

fn default_software_keyboard_enabled(keyboard_seat_enabled: bool) -> bool {
    !keyboard_seat_enabled
}

fn startup_action_from_env() -> Result<StartupAction, ConfigError> {
    let start_app_id = parse_start_app_id_env()?;
    let shell_start_app_id = parse_shell_start_app_id_env()?;
    Ok(match start_app_id {
        Some(app_id) if app_id == app::SHELL_APP_ID => StartupAction::Shell {
            start_app_id: shell_start_app_id,
        },
        Some(app_id) => StartupAction::App { app_id },
        None => StartupAction::Client,
    })
}

fn parse_transport_request() -> Result<TransportRequest, ConfigError> {
    let requested =
        env::var("SHADOW_GUEST_COMPOSITOR_TRANSPORT").unwrap_or_else(|_| "auto".to_string());
    parse_transport_request_value(&requested)
        .map_err(|requested| ConfigError::InvalidTransport { requested })
}

fn parse_dmabuf_format_profile() -> Result<DmabufFormatProfile, ConfigError> {
    let requested = env::var("SHADOW_GUEST_COMPOSITOR_DMABUF_FORMAT_PROFILE")
        .unwrap_or_else(|_| "default".to_string());
    parse_dmabuf_format_profile_value(&requested)
        .map_err(|requested| ConfigError::InvalidDmabufFormatProfile { requested })
}

fn parse_transport_request_value(requested: &str) -> Result<TransportRequest, String> {
    match requested.trim() {
        "auto" => Ok(TransportRequest::Auto),
        "socket" => Ok(TransportRequest::Socket),
        "direct" => Ok(TransportRequest::Direct),
        _ => Err(requested.to_string()),
    }
}

fn parse_dmabuf_format_profile_value(requested: &str) -> Result<DmabufFormatProfile, String> {
    match requested.trim() {
        "default" => Ok(DmabufFormatProfile::Default),
        "linear-only" | "linear_only" => Ok(DmabufFormatProfile::LinearOnly),
        "implicit-only" | "implicit_only" => Ok(DmabufFormatProfile::ImplicitOnly),
        _ => Err(requested.to_string()),
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

fn parse_software_keyboard_enabled(keyboard_seat_enabled: bool) -> bool {
    match env::var("SHADOW_BLITZ_SOFTWARE_KEYBOARD")
        .ok()
        .as_deref()
        .map(str::trim)
    {
        Some("1") | Some("true") | Some("on") => true,
        Some("0") | Some("false") | Some("off") => false,
        _ => default_software_keyboard_enabled(keyboard_seat_enabled),
    }
}

fn parse_usize_env(key: &'static str, default: usize) -> Result<usize, ConfigError> {
    let Some(value) = parse_u64_env(key)? else {
        return Ok(default);
    };
    usize::try_from(value).map_err(|_| ConfigError::InvalidU64 {
        key,
        value: value.to_string(),
    })
}

fn merge_env_assignments(base: &mut Vec<(String, String)>, overlay: Vec<(String, String)>) {
    for (key, value) in overlay {
        if let Some((_, existing_value)) = base
            .iter_mut()
            .find(|(existing_key, _)| existing_key == &key)
        {
            *existing_value = value;
        } else {
            base.push((key, value));
        }
    }
}

#[derive(Debug)]
pub(crate) enum ConfigError {
    InvalidAppId {
        key: &'static str,
        value: String,
    },
    InvalidDmabufFormatProfile {
        requested: String,
    },
    InvalidGuestClientEnv(InvalidEnvSpec),
    InvalidPositiveI32 {
        key: &'static str,
        value: String,
    },
    InvalidSessionConfigField {
        field: &'static str,
        message: String,
    },
    InvalidTransport {
        requested: String,
    },
    InvalidU64 {
        key: &'static str,
        value: String,
    },
    ParseSessionConfig {
        path: PathBuf,
        source: serde_json::Error,
    },
    ReadSessionConfig {
        path: PathBuf,
        source: io::Error,
    },
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidAppId { key, value } => {
                write!(f, "invalid {key}={value:?}: unknown app id")
            }
            Self::InvalidDmabufFormatProfile { requested } => {
                write!(
                    f,
                    "invalid SHADOW_GUEST_COMPOSITOR_DMABUF_FORMAT_PROFILE={requested:?}: expected default, linear-only, or implicit-only"
                )
            }
            Self::InvalidGuestClientEnv(error) => {
                write!(f, "invalid SHADOW_GUEST_CLIENT_ENV: {error}")
            }
            Self::InvalidPositiveI32 { key, value } => {
                write!(f, "invalid {key}={value:?}: expected a positive integer")
            }
            Self::InvalidSessionConfigField { field, message } => {
                write!(f, "invalid SHADOW_GUEST_SESSION_CONFIG {field}: {message}")
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
            Self::ParseSessionConfig { path, source } => {
                write!(
                    f,
                    "invalid SHADOW_GUEST_SESSION_CONFIG=\"{}\": {source}",
                    path.display()
                )
            }
            Self::ReadSessionConfig { path, source } => {
                write!(
                    f,
                    "failed to read SHADOW_GUEST_SESSION_CONFIG=\"{}\": {source}",
                    path.display()
                )
            }
        }
    }
}

impl std::error::Error for ConfigError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::InvalidGuestClientEnv(error) => Some(error),
            Self::ParseSessionConfig { source, .. } => Some(source),
            Self::ReadSessionConfig { source, .. } => Some(source),
            _ => None,
        }
    }
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct GuestStartupConfigFile {
    schema_version: Option<u64>,
    #[serde(default)]
    startup: GuestStartupActionFile,
    #[serde(default)]
    client: GuestClientConfigFile,
    #[serde(default)]
    compositor: GuestCompositorConfigFile,
    #[serde(default)]
    touch: GuestTouchConfigFile,
    #[serde(default)]
    window: GuestWindowConfigFile,
    #[serde(default)]
    runtime: GuestRuntimeConfigFile,
    #[serde(default)]
    artifacts: GuestArtifactsConfigFile,
}

impl GuestStartupConfigFile {
    fn into_startup_config(self) -> Result<GuestStartupConfig, ConfigError> {
        match self.schema_version {
            Some(1) => {}
            Some(schema_version) => {
                return Err(invalid_session_config_field(
                    "schemaVersion",
                    format!("{schema_version:?}: expected 1"),
                ));
            }
            None => {
                return Err(invalid_session_config_field(
                    "schemaVersion",
                    "missing required schemaVersion",
                ));
            }
        }
        let mut config = GuestStartupConfig::defaults();
        config.startup_action = self.startup.into_startup_action()?;
        config.client = self.client.into_client_config(self.runtime, self.artifacts);
        self.compositor.apply_to(&mut config)?;
        self.touch.apply_to(&mut config)?;
        self.window.apply_to(&mut config)?;
        Ok(config)
    }
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct GuestStartupActionFile {
    mode: Option<String>,
    #[serde(default, alias = "appId")]
    start_app_id: Option<String>,
    #[serde(default)]
    shell_start_app_id: Option<String>,
}

impl GuestStartupActionFile {
    fn into_startup_action(self) -> Result<StartupAction, ConfigError> {
        match self
            .mode
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            Some("client") => Ok(StartupAction::Client),
            Some("app") => {
                let start_app_id =
                    non_empty_trimmed(self.start_app_id.as_deref()).ok_or_else(|| {
                        invalid_session_config_field(
                            "startup.startAppId",
                            "missing required app id",
                        )
                    })?;
                let app_id = parse_config_app_id("startup.startAppId", start_app_id)?;
                if app_id == app::SHELL_APP_ID {
                    return Err(invalid_session_config_field(
                        "startup.startAppId",
                        format!("{start_app_id:?}: use startup.mode=\"shell\" for shell sessions"),
                    ));
                }
                Ok(StartupAction::App { app_id })
            }
            Some("shell") => {
                let field = if self.shell_start_app_id.is_some() {
                    "startup.shellStartAppId"
                } else {
                    "startup.startAppId"
                };
                Ok(StartupAction::Shell {
                    start_app_id: parse_optional_config_shell_start_app_id(
                        field,
                        self.shell_start_app_id
                            .as_deref()
                            .or(self.start_app_id.as_deref()),
                    )?,
                })
            }
            Some(mode) => Err(invalid_session_config_field(
                "startup.mode",
                format!("{mode:?}: expected client, app, or shell"),
            )),
            None => {
                if self.shell_start_app_id.is_some() {
                    return Ok(StartupAction::Shell {
                        start_app_id: parse_optional_config_shell_start_app_id(
                            "startup.shellStartAppId",
                            self.shell_start_app_id.as_deref(),
                        )?,
                    });
                }
                let Some(start_app_id) = self.start_app_id.as_deref() else {
                    return Ok(StartupAction::Client);
                };
                let app_id = parse_config_app_id("startup.startAppId", start_app_id)?;
                if app_id == app::SHELL_APP_ID {
                    Ok(StartupAction::Shell { start_app_id: None })
                } else {
                    Ok(StartupAction::App { app_id })
                }
            }
        }
    }
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct GuestClientConfigFile {
    app_client_path: Option<String>,
    runtime_dir: Option<String>,
    system_binary_path: Option<String>,
    env_assignments: Option<Vec<GuestEnvAssignmentFile>>,
    exit_on_configure: Option<bool>,
    linger_ms: Option<u64>,
}

impl GuestClientConfigFile {
    fn into_client_config(
        self,
        runtime: GuestRuntimeConfigFile,
        artifacts: GuestArtifactsConfigFile,
    ) -> GuestClientConfig {
        let mut client = GuestClientConfig::defaults();
        if let Some(app_client_path) = non_empty_trimmed(self.app_client_path.as_deref()) {
            client.app_client_path = app_client_path.to_owned();
        }
        if let Some(runtime_dir) = self
            .runtime_dir
            .or(runtime.runtime_dir)
            .filter(|value| !value.trim().is_empty())
        {
            client.runtime_dir = PathBuf::from(runtime_dir);
        }
        if let Some(system_binary_path) = self
            .system_binary_path
            .or(artifacts.system_binary_path)
            .as_deref()
            .and_then(|value| non_empty_trimmed(Some(value)))
        {
            client.system_binary_path = Some(OsString::from(system_binary_path));
        }
        if let Some(env_assignments) = self.env_assignments {
            client.env_assignments = env_assignments
                .into_iter()
                .map(|assignment| (assignment.key, assignment.value))
                .collect();
        }
        if let Some(exit_on_configure) = self.exit_on_configure {
            client.exit_on_configure = exit_on_configure;
        }
        client.linger_ms = self.linger_ms;
        client
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GuestEnvAssignmentFile {
    key: String,
    value: String,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct GuestCompositorConfigFile {
    transport: Option<String>,
    exit_on_client_disconnect: Option<bool>,
    exit_on_first_frame: Option<bool>,
    exit_on_first_dma_buffer: Option<bool>,
    boot_splash_drm: Option<bool>,
    enable_drm: Option<bool>,
    gpu_shell: Option<bool>,
    strict_gpu_resident: Option<bool>,
    dmabuf_global_enabled: Option<bool>,
    dmabuf_feedback_enabled: Option<bool>,
    dmabuf_format_profile: Option<String>,
    software_keyboard_enabled: Option<bool>,
    background_app_resident_limit: Option<u64>,
    #[serde(default)]
    frame_capture: GuestFrameCaptureConfigFile,
}

impl GuestCompositorConfigFile {
    fn apply_to(self, config: &mut GuestStartupConfig) -> Result<(), ConfigError> {
        if let Some(transport) = self.transport.as_deref() {
            config.transport = parse_transport_request_value(transport).map_err(|requested| {
                invalid_session_config_field(
                    "compositor.transport",
                    format!("{requested:?}: expected auto, socket, or direct"),
                )
            })?;
        }
        if let Some(exit_on_client_disconnect) = self.exit_on_client_disconnect {
            config.exit_on_client_disconnect = exit_on_client_disconnect;
        }
        if let Some(exit_on_first_frame) = self.exit_on_first_frame {
            config.exit_on_first_frame = exit_on_first_frame;
        }
        if let Some(exit_on_first_dma_buffer) = self.exit_on_first_dma_buffer {
            config.exit_on_first_dma_buffer = exit_on_first_dma_buffer;
        }
        if let Some(boot_splash_drm) = self.boot_splash_drm {
            config.boot_splash_drm = boot_splash_drm;
        }
        if let Some(drm_enabled) = self.enable_drm {
            config.drm_enabled = drm_enabled;
        }
        if let Some(gpu_shell) = self.gpu_shell {
            config.gpu_shell = gpu_shell;
        }
        if let Some(strict_gpu_resident) = self.strict_gpu_resident {
            config.strict_gpu_resident = strict_gpu_resident;
        }
        if let Some(dmabuf_global_enabled) = self.dmabuf_global_enabled {
            config.dmabuf_global_enabled = dmabuf_global_enabled;
        }
        if let Some(dmabuf_feedback_enabled) = self.dmabuf_feedback_enabled {
            config.dmabuf_feedback_enabled = dmabuf_feedback_enabled;
        }
        if let Some(dmabuf_format_profile) = self.dmabuf_format_profile.as_deref() {
            config.dmabuf_format_profile = parse_dmabuf_format_profile_value(dmabuf_format_profile)
                .map_err(|requested| {
                    invalid_session_config_field(
                        "compositor.dmabufFormatProfile",
                        format!("{requested:?}: expected default, linear-only, or implicit-only"),
                    )
                })?;
        }
        if let Some(software_keyboard_enabled) = self.software_keyboard_enabled {
            config.software_keyboard_enabled = software_keyboard_enabled;
        }
        if let Some(background_app_resident_limit) = self.background_app_resident_limit {
            config.background_app_resident_limit = usize::try_from(background_app_resident_limit)
                .map_err(|_| {
                invalid_session_config_field(
                    "compositor.backgroundAppResidentLimit",
                    format!("{background_app_resident_limit:?}: expected an unsigned integer"),
                )
            })?;
        }
        self.frame_capture.apply_to(config)
    }
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct GuestFrameCaptureConfigFile {
    mode: Option<String>,
    artifact_path: Option<String>,
    snapshot_cache: Option<bool>,
    checksum: Option<bool>,
    #[serde(default, alias = "enabled")]
    artifacts_enabled: Option<bool>,
    write_every_frame: Option<bool>,
}

impl GuestFrameCaptureConfigFile {
    fn apply_to(self, config: &mut GuestStartupConfig) -> Result<(), ConfigError> {
        if let Some(artifact_path) = self.artifact_path.as_deref() {
            config.frame_artifact_path = non_empty_trimmed(Some(artifact_path))
                .map(PathBuf::from)
                .unwrap_or_else(default_frame_artifact_path);
        }
        if let Some(snapshot_cache_enabled) = self.snapshot_cache {
            config.frame_snapshot_cache_enabled = snapshot_cache_enabled;
        }
        if let Some(frame_checksum_enabled) = self.checksum {
            config.frame_checksum_enabled = frame_checksum_enabled;
        }
        if let Some(mode) = self.mode.as_deref() {
            let (frame_artifacts_enabled, frame_artifact_every_frame) =
                parse_frame_capture_mode_value(mode).map_err(|mode| {
                    invalid_session_config_field(
                        "compositor.frameCapture.mode",
                        format!("{mode:?}: expected off, first-frame, or every-frame"),
                    )
                })?;
            config.frame_artifacts_enabled = frame_artifacts_enabled;
            config.frame_artifact_every_frame = frame_artifact_every_frame;
        } else {
            if let Some(frame_artifacts_enabled) = self.artifacts_enabled {
                config.frame_artifacts_enabled = frame_artifacts_enabled;
            }
            if let Some(frame_artifact_every_frame) = self.write_every_frame {
                config.frame_artifact_every_frame = frame_artifact_every_frame;
            }
        }
        Ok(())
    }
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct GuestTouchConfigFile {
    signal_path: Option<String>,
    latency_trace: Option<bool>,
    synthetic_tap: Option<GuestSyntheticTapConfigFile>,
    exit_after_present: Option<bool>,
}

impl GuestTouchConfigFile {
    fn apply_to(self, config: &mut GuestStartupConfig) -> Result<(), ConfigError> {
        if let Some(signal_path) = self.signal_path.as_deref() {
            config.touch_signal_path = non_empty_trimmed(Some(signal_path)).map(PathBuf::from);
        }
        if let Some(touch_latency_trace) = self.latency_trace {
            config.touch_latency_trace = touch_latency_trace;
        }
        if let Some(synthetic_tap) = self.synthetic_tap {
            config.synthetic_tap = Some(synthetic_tap.into_config()?);
        }
        if let Some(exit_after_touch_present) = self.exit_after_present {
            config.exit_after_touch_present = exit_after_touch_present;
        }
        Ok(())
    }
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct GuestSyntheticTapConfigFile {
    normalized_x_millis: Option<u16>,
    normalized_y_millis: Option<u16>,
    after_first_frame_delay_ms: Option<u64>,
    hold_ms: Option<u64>,
    after_app_id: Option<String>,
}

impl GuestSyntheticTapConfigFile {
    fn into_config(self) -> Result<GuestSyntheticTapConfig, ConfigError> {
        let normalized_x_millis = self.normalized_x_millis.unwrap_or(500);
        let normalized_y_millis = self.normalized_y_millis.unwrap_or(500);
        if normalized_x_millis > 1000 {
            return Err(invalid_session_config_field(
                "touch.syntheticTap.normalizedXMillis",
                format!("{normalized_x_millis}: expected 0..1000"),
            ));
        }
        if normalized_y_millis > 1000 {
            return Err(invalid_session_config_field(
                "touch.syntheticTap.normalizedYMillis",
                format!("{normalized_y_millis}: expected 0..1000"),
            ));
        }

        Ok(GuestSyntheticTapConfig {
            normalized_x_millis,
            normalized_y_millis,
            after_first_frame_delay_ms: self.after_first_frame_delay_ms.unwrap_or(250),
            hold_ms: self.hold_ms.unwrap_or(50),
            after_app_id: self
                .after_app_id
                .as_deref()
                .map(|value| parse_config_app_id("touch.syntheticTap.afterAppId", value))
                .transpose()?,
        })
    }
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct GuestWindowConfigFile {
    surface_width: Option<i32>,
    surface_height: Option<i32>,
}

impl GuestWindowConfigFile {
    fn apply_to(self, config: &mut GuestStartupConfig) -> Result<(), ConfigError> {
        if let Some(surface_width) = self.surface_width {
            config.toplevel_width = positive_i32_from_config("window.surfaceWidth", surface_width)?;
        }
        if let Some(surface_height) = self.surface_height {
            config.toplevel_height =
                positive_i32_from_config("window.surfaceHeight", surface_height)?;
        }
        Ok(())
    }
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct GuestRuntimeConfigFile {
    runtime_dir: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct GuestArtifactsConfigFile {
    system_binary_path: Option<String>,
}

fn parse_frame_capture_mode_value(mode: &str) -> Result<(bool, bool), String> {
    match mode.trim() {
        "off" => Ok((false, false)),
        "first-frame" | "first_frame" => Ok((true, false)),
        "every-frame" | "every_frame" => Ok((true, true)),
        _ => Err(mode.to_string()),
    }
}

fn parse_config_app_id(field: &'static str, value: &str) -> Result<AppId, ConfigError> {
    let value = non_empty_trimmed(Some(value))
        .ok_or_else(|| invalid_session_config_field(field, "expected a non-empty app id"))?;
    app::find_app_by_str(value)
        .map(|app| app.id)
        .ok_or_else(|| invalid_session_config_field(field, format!("{value:?}: unknown app id")))
}

fn parse_optional_config_shell_start_app_id(
    field: &'static str,
    value: Option<&str>,
) -> Result<Option<AppId>, ConfigError> {
    let Some(value) = non_empty_trimmed(value) else {
        return Ok(None);
    };
    if value == app::SHELL_APP_ID.as_str() {
        return Ok(None);
    }
    parse_config_app_id(field, value).map(Some)
}

fn positive_i32_from_config(field: &'static str, value: i32) -> Result<i32, ConfigError> {
    if value <= 0 {
        return Err(invalid_session_config_field(
            field,
            format!("{value:?}: expected a positive integer"),
        ));
    }
    Ok(value)
}

fn invalid_session_config_field(field: &'static str, message: impl Into<String>) -> ConfigError {
    ConfigError::InvalidSessionConfigField {
        field,
        message: message.into(),
    }
}

fn non_empty_trimmed(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use std::{
        ffi::OsString,
        fs,
        path::PathBuf,
        sync::{Mutex, OnceLock},
    };

    use shadow_ui_core::app::{CAMERA_APP_ID, TIMELINE_APP_ID};
    use tempfile::TempDir;

    use super::{
        DmabufFormatProfile, GuestStartupConfig, GuestSyntheticTapConfig, StartupAction,
        TransportRequest,
    };

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn with_env<T>(updates: Vec<(&str, Option<&str>)>, check: impl FnOnce() -> T) -> T {
        let _guard = env_lock().lock().unwrap_or_else(|error| error.into_inner());
        let mut updates_with_defaults = vec![
            ("SHADOW_GUEST_SESSION_CONFIG", None),
            ("SHADOW_APP_CLIENT", None),
            ("SHADOW_GUEST_CLIENT", None),
            ("XDG_RUNTIME_DIR", None),
            ("SHADOW_SYSTEM_BINARY_PATH", None),
            ("SHADOW_GUEST_START_APP_ID", None),
            ("SHADOW_GUEST_SHELL_START_APP_ID", None),
            ("SHADOW_GUEST_COMPOSITOR_TRANSPORT", None),
            ("SHADOW_GUEST_COMPOSITOR_EXIT_ON_CLIENT_DISCONNECT", None),
            ("SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME", None),
            ("SHADOW_GUEST_COMPOSITOR_EXIT_ON_FIRST_DMA_BUFFER", None),
            ("SHADOW_GUEST_COMPOSITOR_BOOT_SPLASH_DRM", None),
            ("SHADOW_GUEST_COMPOSITOR_ENABLE_DRM", None),
            ("SHADOW_GUEST_COMPOSITOR_GPU_SHELL", None),
            ("SHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH", None),
            ("SHADOW_GUEST_COMPOSITOR_TOPLEVEL_HEIGHT", None),
            ("SHADOW_GUEST_COMPOSITOR_DISABLE_DMABUF_GLOBAL", None),
            ("SHADOW_GUEST_COMPOSITOR_DMABUF_FEEDBACK", None),
            ("SHADOW_GUEST_COMPOSITOR_DMABUF_FORMAT_PROFILE", None),
            ("SHADOW_GUEST_COMPOSITOR_STRICT_GPU_RESIDENT", None),
            ("SHADOW_GUEST_TOUCH_SIGNAL_PATH", None),
            ("SHADOW_GUEST_TOUCH_LATENCY_TRACE", None),
            ("SHADOW_GUEST_FRAME_PATH", None),
            ("SHADOW_GUEST_FRAME_ARTIFACTS", None),
            ("SHADOW_GUEST_FRAME_WRITE_EVERY_FRAME", None),
            ("SHADOW_GUEST_FRAME_SNAPSHOT_CACHE", None),
            ("SHADOW_GUEST_FRAME_CHECKSUM", None),
            ("SHADOW_GUEST_CLIENT_ENV", None),
            ("SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE", None),
            ("SHADOW_GUEST_CLIENT_LINGER_MS", None),
            ("SHADOW_BLITZ_SOFTWARE_KEYBOARD", None),
            ("SHADOW_GUEST_COMPOSITOR_BACKGROUND_APP_LIMIT", None),
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

        let result = check();

        for (key, value) in previous {
            match value {
                Some(value) => unsafe { std::env::set_var(key, value) },
                None => unsafe { std::env::remove_var(key) },
            }
        }

        result
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
            assert!(config.dmabuf_global_enabled);
            assert!(!config.dmabuf_feedback_enabled);
            assert_eq!(config.dmabuf_format_profile, DmabufFormatProfile::Default);
            assert!(!config.strict_gpu_resident);
            assert!(!config.frame_snapshot_cache_enabled);
            assert!(!config.frame_checksum_enabled);
            assert!(!config.frame_artifacts_enabled);
            assert!(!config.frame_artifact_every_frame);
            assert!(config.software_keyboard_enabled);
            assert_eq!(config.background_app_resident_limit, 3);
        });
    }

    #[test]
    fn config_can_disable_software_keyboard() {
        with_env(vec![("SHADOW_BLITZ_SOFTWARE_KEYBOARD", Some("0"))], || {
            let config = GuestStartupConfig::from_env().expect("software-keyboard config");
            assert!(!config.software_keyboard_enabled);
        });
    }

    #[test]
    fn config_can_enable_software_keyboard_explicitly() {
        with_env(
            vec![("SHADOW_BLITZ_SOFTWARE_KEYBOARD", Some("true"))],
            || {
                let config = GuestStartupConfig::from_env().expect("software-keyboard config");
                assert!(config.software_keyboard_enabled);
            },
        );
    }

    #[test]
    fn config_can_override_background_app_limit() {
        with_env(
            vec![("SHADOW_GUEST_COMPOSITOR_BACKGROUND_APP_LIMIT", Some("1"))],
            || {
                let config = GuestStartupConfig::from_env().expect("background app limit config");
                assert_eq!(config.background_app_resident_limit, 1);
            },
        );
    }

    #[test]
    fn config_can_disable_dmabuf_global() {
        with_env(
            vec![("SHADOW_GUEST_COMPOSITOR_DISABLE_DMABUF_GLOBAL", Some("1"))],
            || {
                let config = GuestStartupConfig::from_env().expect("dmabuf-disabled config");
                assert!(!config.dmabuf_global_enabled);
            },
        );
    }

    #[test]
    fn config_can_enable_dmabuf_feedback() {
        with_env(
            vec![("SHADOW_GUEST_COMPOSITOR_DMABUF_FEEDBACK", Some("1"))],
            || {
                let config = GuestStartupConfig::from_env().expect("dmabuf-feedback config");
                assert!(config.dmabuf_feedback_enabled);
            },
        );
    }

    #[test]
    fn config_can_override_dmabuf_format_profile() {
        with_env(
            vec![(
                "SHADOW_GUEST_COMPOSITOR_DMABUF_FORMAT_PROFILE",
                Some("linear-only"),
            )],
            || {
                let config = GuestStartupConfig::from_env().expect("dmabuf-format-profile config");
                assert_eq!(
                    config.dmabuf_format_profile,
                    DmabufFormatProfile::LinearOnly
                );
            },
        );
    }

    #[test]
    fn config_can_enable_strict_gpu_resident() {
        with_env(
            vec![("SHADOW_GUEST_COMPOSITOR_STRICT_GPU_RESIDENT", Some("1"))],
            || {
                let config = GuestStartupConfig::from_env().expect("strict-gpu-resident config");
                assert!(config.strict_gpu_resident);
            },
        );
    }

    #[test]
    fn config_can_enable_frame_artifacts() {
        with_env(vec![("SHADOW_GUEST_FRAME_ARTIFACTS", Some("1"))], || {
            let config = GuestStartupConfig::from_env().expect("frame-artifact config");
            assert!(config.frame_artifacts_enabled);
        });
    }

    #[test]
    fn config_can_enable_frame_snapshot_cache() {
        with_env(
            vec![("SHADOW_GUEST_FRAME_SNAPSHOT_CACHE", Some("1"))],
            || {
                let config = GuestStartupConfig::from_env().expect("frame-snapshot-cache config");
                assert!(config.frame_snapshot_cache_enabled);
            },
        );
    }

    #[test]
    fn config_can_enable_frame_checksum_logging() {
        with_env(vec![("SHADOW_GUEST_FRAME_CHECKSUM", Some("1"))], || {
            let config = GuestStartupConfig::from_env().expect("frame-checksum config");
            assert!(config.frame_checksum_enabled);
        });
    }

    #[test]
    fn config_can_enable_frame_artifact_every_frame() {
        with_env(
            vec![("SHADOW_GUEST_FRAME_WRITE_EVERY_FRAME", Some("1"))],
            || {
                let config = GuestStartupConfig::from_env().expect("frame-artifact config");
                assert!(config.frame_artifact_every_frame);
            },
        );
    }

    #[test]
    fn config_can_load_from_session_config_file() {
        let temp_dir = TempDir::new().expect("temp dir");
        let session_config_path = temp_dir.path().join("session-config.json");
        fs::write(
            &session_config_path,
            r#"{
  "schemaVersion": 1,
  "startup": {
    "mode": "shell",
    "startAppId": "timeline"
  },
  "client": {
    "appClientPath": "/vendor/bin/shadow-client",
    "envAssignments": [
      { "key": "A", "value": "1" },
      { "key": "B", "value": "two" }
    ],
    "exitOnConfigure": true,
    "lingerMs": 42
  },
  "runtime": {
    "runtimeDir": "/data/local/tmp/pixel-runtime"
  },
  "artifacts": {
    "systemBinaryPath": "/data/local/tmp/shadow-system"
  },
  "window": {
    "surfaceWidth": 720,
    "surfaceHeight": 1280
  },
  "touch": {
    "signalPath": "/tmp/touch.signal",
    "latencyTrace": true,
    "syntheticTap": {
      "normalizedXMillis": 500,
      "normalizedYMillis": 500,
      "afterFirstFrameDelayMs": 250,
      "holdMs": 50,
      "afterAppId": "timeline"
    }
  },
  "compositor": {
    "transport": "direct",
    "exitOnClientDisconnect": true,
    "exitOnFirstFrame": true,
    "exitOnFirstDmaBuffer": true,
    "bootSplashDrm": true,
    "enableDrm": true,
    "gpuShell": true,
    "strictGpuResident": true,
    "dmabufGlobalEnabled": false,
    "dmabufFeedbackEnabled": true,
    "dmabufFormatProfile": "implicit-only",
    "softwareKeyboardEnabled": false,
    "backgroundAppResidentLimit": 1,
    "frameCapture": {
      "mode": "every-frame",
      "artifactPath": "/tmp/frame.ppm",
      "snapshotCache": true,
      "checksum": true
    }
  }
}"#,
        )
        .expect("write session config");
        let session_config_path = session_config_path.to_string_lossy().into_owned();

        with_env(
            vec![(
                "SHADOW_GUEST_SESSION_CONFIG",
                Some(session_config_path.as_str()),
            )],
            || {
                let config = GuestStartupConfig::from_env().expect("session config");
                assert_eq!(
                    config.startup_action,
                    StartupAction::Shell {
                        start_app_id: Some(TIMELINE_APP_ID),
                    }
                );
                assert_eq!(config.client.app_client_path, "/vendor/bin/shadow-client");
                assert_eq!(
                    config.client.runtime_dir,
                    PathBuf::from("/data/local/tmp/pixel-runtime")
                );
                assert_eq!(
                    config.client.system_binary_path,
                    Some(OsString::from("/data/local/tmp/shadow-system"))
                );
                assert_eq!(
                    config.client.env_assignments,
                    vec![
                        ("A".to_string(), "1".to_string()),
                        ("B".to_string(), "two".to_string()),
                    ]
                );
                assert!(config.client.exit_on_configure);
                assert_eq!(config.client.linger_ms, Some(42));
                assert_eq!(config.transport, TransportRequest::Direct);
                assert!(config.exit_on_client_disconnect);
                assert!(config.exit_on_first_frame);
                assert!(config.exit_on_first_dma_buffer);
                assert!(config.boot_splash_drm);
                assert!(config.drm_enabled);
                assert!(config.gpu_shell);
                assert!(config.strict_gpu_resident);
                assert!(!config.dmabuf_global_enabled);
                assert!(config.dmabuf_feedback_enabled);
                assert_eq!(
                    config.dmabuf_format_profile,
                    DmabufFormatProfile::ImplicitOnly
                );
                assert_eq!(
                    config.touch_signal_path,
                    Some(PathBuf::from("/tmp/touch.signal"))
                );
                assert!(config.touch_latency_trace);
                assert_eq!(
                    config.synthetic_tap,
                    Some(GuestSyntheticTapConfig {
                        normalized_x_millis: 500,
                        normalized_y_millis: 500,
                        after_first_frame_delay_ms: 250,
                        hold_ms: 50,
                        after_app_id: Some(TIMELINE_APP_ID),
                    })
                );
                assert!(config.frame_snapshot_cache_enabled);
                assert!(config.frame_checksum_enabled);
                assert_eq!(config.frame_artifact_path, PathBuf::from("/tmp/frame.ppm"));
                assert!(config.frame_artifacts_enabled);
                assert!(config.frame_artifact_every_frame);
                assert_eq!(config.toplevel_width, 720);
                assert_eq!(config.toplevel_height, 1280);
                assert!(!config.keyboard_seat_enabled);
                assert!(!config.software_keyboard_enabled);
                assert_eq!(config.background_app_resident_limit, 1);
            },
        );
    }

    #[test]
    fn config_can_ignore_host_only_sections_in_session_config_file() {
        let temp_dir = TempDir::new().expect("temp dir");
        let session_config_path = temp_dir.path().join("session-config.json");
        fs::write(
            &session_config_path,
            r#"{
  "schemaVersion": 1,
  "startup": {
    "mode": "app",
    "startAppId": "camera"
  },
  "client": {
    "appClientPath": "/vendor/bin/shadow-client"
  },
  "runtime": {
    "runtimeDir": "/data/local/tmp/pixel-runtime"
  },
  "session": {
    "timeoutSecs": 20,
    "launchEnvAssignments": [
      { "key": "SHADOW_SESSION_APP_PROFILE", "value": "pixel-shell" }
    ]
  },
  "verify": {
    "requiredMarkers": ["runtime-document-ready"],
    "expectClientProcess": true
  },
  "takeover": {
    "restoreInSession": false,
    "stopAllocator": false
  }
}"#,
        )
        .expect("write session config");
        let session_config_path = session_config_path.to_string_lossy().into_owned();

        with_env(
            vec![(
                "SHADOW_GUEST_SESSION_CONFIG",
                Some(session_config_path.as_str()),
            )],
            || {
                let config = GuestStartupConfig::from_env().expect("session config");
                assert_eq!(
                    config.startup_action,
                    StartupAction::App {
                        app_id: CAMERA_APP_ID,
                    }
                );
                assert_eq!(config.client.app_client_path, "/vendor/bin/shadow-client");
                assert_eq!(
                    config.client.runtime_dir,
                    PathBuf::from("/data/local/tmp/pixel-runtime")
                );
            },
        );
    }

    #[test]
    fn env_overlay_overrides_session_config_file() {
        let temp_dir = TempDir::new().expect("temp dir");
        let session_config_path = temp_dir.path().join("session-config.json");
        fs::write(
            &session_config_path,
            r#"{
  "schemaVersion": 1,
  "startup": {
    "mode": "shell",
    "startAppId": "timeline"
  },
  "client": {
    "appClientPath": "/file/client",
    "envAssignments": [
      { "key": "A", "value": "1" },
      { "key": "B", "value": "from-file" }
    ]
  },
  "runtime": {
    "runtimeDir": "/file/runtime"
  },
  "artifacts": {
    "systemBinaryPath": "/file/system"
  },
  "window": {
    "surfaceWidth": 640,
    "surfaceHeight": 1136
  },
  "touch": {
    "signalPath": "/file/touch.signal",
    "latencyTrace": true
  },
  "compositor": {
    "transport": "direct",
    "strictGpuResident": true,
    "dmabufGlobalEnabled": true,
    "backgroundAppResidentLimit": 4,
    "softwareKeyboardEnabled": false,
    "frameCapture": {
      "mode": "off",
      "artifactPath": "/file/frame.ppm"
    }
  }
}"#,
        )
        .expect("write session config");
        let session_config_path = session_config_path.to_string_lossy().into_owned();

        with_env(
            vec![
                (
                    "SHADOW_GUEST_SESSION_CONFIG",
                    Some(session_config_path.as_str()),
                ),
                ("SHADOW_GUEST_START_APP_ID", Some("camera")),
                ("SHADOW_APP_CLIENT", Some("/env/client")),
                ("SHADOW_GUEST_CLIENT", Some("/env/guest-client")),
                ("XDG_RUNTIME_DIR", Some("/env/runtime")),
                ("SHADOW_SYSTEM_BINARY_PATH", Some("/env/system")),
                ("SHADOW_GUEST_CLIENT_ENV", Some("B=2\nC=3")),
                ("SHADOW_GUEST_CLIENT_EXIT_ON_CONFIGURE", Some("1")),
                ("SHADOW_GUEST_CLIENT_LINGER_MS", Some("17")),
                ("SHADOW_GUEST_COMPOSITOR_TRANSPORT", Some("socket")),
                ("SHADOW_GUEST_COMPOSITOR_DISABLE_DMABUF_GLOBAL", Some("1")),
                ("SHADOW_GUEST_COMPOSITOR_BACKGROUND_APP_LIMIT", Some("2")),
                ("SHADOW_GUEST_COMPOSITOR_TOPLEVEL_WIDTH", Some("800")),
                ("SHADOW_GUEST_COMPOSITOR_TOPLEVEL_HEIGHT", Some("1400")),
                ("SHADOW_GUEST_TOUCH_SIGNAL_PATH", Some("")),
                ("SHADOW_GUEST_FRAME_PATH", Some("/env/frame.ppm")),
                ("SHADOW_GUEST_FRAME_ARTIFACTS", Some("1")),
                ("SHADOW_GUEST_FRAME_WRITE_EVERY_FRAME", Some("1")),
                ("SHADOW_BLITZ_SOFTWARE_KEYBOARD", Some("true")),
            ],
            || {
                let config = GuestStartupConfig::from_env().expect("overlay config");
                assert_eq!(
                    config.startup_action,
                    StartupAction::App {
                        app_id: CAMERA_APP_ID,
                    }
                );
                assert_eq!(config.client.app_client_path, "/env/client");
                assert_eq!(config.client.runtime_dir, PathBuf::from("/file/runtime"));
                assert_eq!(
                    config.client.system_binary_path,
                    Some(OsString::from("/env/system"))
                );
                assert_eq!(
                    config.client.env_assignments,
                    vec![
                        ("A".to_string(), "1".to_string()),
                        ("B".to_string(), "2".to_string()),
                        ("C".to_string(), "3".to_string()),
                    ]
                );
                assert!(config.client.exit_on_configure);
                assert_eq!(config.client.linger_ms, Some(17));
                assert_eq!(config.transport, TransportRequest::Socket);
                assert!(config.strict_gpu_resident);
                assert!(!config.dmabuf_global_enabled);
                assert_eq!(config.background_app_resident_limit, 2);
                assert_eq!(config.touch_signal_path, None);
                assert!(config.touch_latency_trace);
                assert_eq!(config.frame_artifact_path, PathBuf::from("/env/frame.ppm"));
                assert!(config.frame_artifacts_enabled);
                assert!(config.frame_artifact_every_frame);
                assert_eq!(config.toplevel_width, 800);
                assert_eq!(config.toplevel_height, 1400);
                assert!(config.software_keyboard_enabled);
            },
        );
    }

    #[test]
    fn file_backed_config_ignores_shadow_guest_client_compat_override() {
        let temp_dir = TempDir::new().expect("temp dir");
        let session_config_path = temp_dir.path().join("session-config.json");
        fs::write(
            &session_config_path,
            r#"{
  "schemaVersion": 1,
  "client": {
    "appClientPath": "/file/client"
  },
  "runtime": {
    "runtimeDir": "/file/runtime"
  }
}"#,
        )
        .expect("write session config");
        let session_config_path = session_config_path.to_string_lossy().into_owned();

        with_env(
            vec![
                (
                    "SHADOW_GUEST_SESSION_CONFIG",
                    Some(session_config_path.as_str()),
                ),
                ("SHADOW_GUEST_CLIENT", Some("/env/guest-client")),
                ("XDG_RUNTIME_DIR", Some("/env/runtime")),
            ],
            || {
                let config = GuestStartupConfig::from_env().expect("file-backed config");
                assert_eq!(config.client.app_client_path, "/file/client");
                assert_eq!(config.client.runtime_dir, PathBuf::from("/file/runtime"));
            },
        );
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
    fn config_rejects_missing_session_config_schema_version() {
        let temp_dir = TempDir::new().expect("temp dir");
        let session_config_path = temp_dir.path().join("session-config.json");
        fs::write(&session_config_path, r#"{"startup":{"mode":"client"}}"#)
            .expect("write session config");
        let session_config_path = session_config_path.to_string_lossy().into_owned();

        with_env(
            vec![(
                "SHADOW_GUEST_SESSION_CONFIG",
                Some(session_config_path.as_str()),
            )],
            || {
                let error =
                    GuestStartupConfig::from_env().expect_err("missing session config schema");
                assert_eq!(
                    error.to_string(),
                    "invalid SHADOW_GUEST_SESSION_CONFIG schemaVersion: missing required schemaVersion"
                );
            },
        );
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
