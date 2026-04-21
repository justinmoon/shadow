use std::fmt;
use std::fs;
use std::path::PathBuf;

use serde::Deserialize;

pub const RUNTIME_SESSION_CONFIG_ENV: &str = "SHADOW_RUNTIME_SESSION_CONFIG";

#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
pub struct RuntimeServicesConfig {
    #[serde(default, rename = "audioBackend")]
    pub audio_backend: Option<String>,
    #[serde(default, rename = "cashuDataDir")]
    pub cashu_data_dir: Option<PathBuf>,
    #[serde(default, rename = "nostrDbPath")]
    pub nostr_db_path: Option<PathBuf>,
    #[serde(default, rename = "nostrServiceSocket")]
    pub nostr_service_socket: Option<PathBuf>,
}

#[derive(Debug, Deserialize)]
struct RuntimeSessionConfig {
    #[serde(default)]
    services: RuntimeServicesConfig,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeSessionConfigError {
    message: String,
}

impl RuntimeSessionConfigError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for RuntimeSessionConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for RuntimeSessionConfigError {}

pub fn runtime_services_config() -> Result<Option<RuntimeServicesConfig>, RuntimeSessionConfigError>
{
    let Some(config_path) = runtime_session_config_path() else {
        return Ok(None);
    };
    let encoded = fs::read_to_string(&config_path).map_err(|error| {
        RuntimeSessionConfigError::new(format!(
            "shadow runtime session config: read {}: {error}",
            config_path.display()
        ))
    })?;
    let config: RuntimeSessionConfig = serde_json::from_str(&encoded).map_err(|error| {
        RuntimeSessionConfigError::new(format!(
            "shadow runtime session config: decode {}: {error}",
            config_path.display()
        ))
    })?;
    Ok(Some(config.services))
}

fn runtime_session_config_path() -> Option<PathBuf> {
    std::env::var(RUNTIME_SESSION_CONFIG_ENV)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::{runtime_services_config, RUNTIME_SESSION_CONFIG_ENV};
    use crate::services::test_env_lock;
    use std::fs;
    use std::path::Path;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn with_temp_session_config<T>(contents: &str, f: impl FnOnce() -> T) -> T {
        let _guard = test_env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time")
            .as_nanos();
        let temp_dir = std::env::temp_dir().join(format!("shadow-sdk-session-config-{timestamp}"));
        let config_path = temp_dir.join("session-config.json");
        fs::create_dir_all(&temp_dir).expect("create temp dir");
        fs::write(&config_path, contents).expect("write session config");
        std::env::set_var(RUNTIME_SESSION_CONFIG_ENV, &config_path);

        let output = f();

        std::env::remove_var(RUNTIME_SESSION_CONFIG_ENV);
        let _ = fs::remove_dir_all(&temp_dir);
        output
    }

    #[test]
    fn runtime_services_config_returns_none_without_env() {
        let _guard = test_env_lock()
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        std::env::remove_var(RUNTIME_SESSION_CONFIG_ENV);

        assert_eq!(runtime_services_config().expect("load config"), None);
    }

    #[test]
    fn runtime_services_config_reads_minimal_services_subtree() {
        with_temp_session_config(
            r#"{
                "schemaVersion": 1,
                "services": {
                    "audioBackend": "memory",
                    "cashuDataDir": "/tmp/runtime-cashu",
                    "nostrDbPath": "/tmp/runtime-nostr.sqlite3",
                    "nostrServiceSocket": "/tmp/runtime-nostr.sock"
                },
                "runtime": {
                    "defaultAppId": "timeline"
                }
            }"#,
            || {
                let services = runtime_services_config()
                    .expect("load config")
                    .expect("services config");
                assert_eq!(services.audio_backend.as_deref(), Some("memory"));
                assert_eq!(
                    services.cashu_data_dir.as_deref(),
                    Some(Path::new("/tmp/runtime-cashu"))
                );
                assert_eq!(
                    services.nostr_db_path.as_deref(),
                    Some(Path::new("/tmp/runtime-nostr.sqlite3"))
                );
                assert_eq!(
                    services.nostr_service_socket.as_deref(),
                    Some(Path::new("/tmp/runtime-nostr.sock"))
                );
            },
        );
    }

    #[test]
    fn runtime_services_config_errors_for_invalid_json() {
        with_temp_session_config("{", || {
            let error = runtime_services_config().expect_err("reject invalid json");
            assert!(error.to_string().contains("decode"));
        });
    }
}
