use std::env;

pub const APP_TITLE_ENV: &str = "SHADOW_APP_TITLE";
pub const SURFACE_HEIGHT_ENV: &str = "SHADOW_APP_SURFACE_HEIGHT";
pub const SURFACE_WIDTH_ENV: &str = "SHADOW_APP_SURFACE_WIDTH";
pub const UNDECORATED_ENV: &str = "SHADOW_APP_UNDECORATED";
pub const WAYLAND_APP_ID_ENV: &str = "SHADOW_APP_WAYLAND_APP_ID";
pub const WAYLAND_INSTANCE_NAME_ENV: &str = "SHADOW_APP_WAYLAND_INSTANCE_NAME";

const LEGACY_APP_TITLE_ENV: &str = "SHADOW_BLITZ_APP_TITLE";
const LEGACY_SURFACE_HEIGHT_ENV: &str = "SHADOW_BLITZ_SURFACE_HEIGHT";
const LEGACY_SURFACE_WIDTH_ENV: &str = "SHADOW_BLITZ_SURFACE_WIDTH";
const LEGACY_UNDECORATED_ENV: &str = "SHADOW_BLITZ_UNDECORATED";
const LEGACY_WAYLAND_APP_ID_ENV: &str = "SHADOW_BLITZ_WAYLAND_APP_ID";
const LEGACY_WAYLAND_INSTANCE_NAME_ENV: &str = "SHADOW_BLITZ_WAYLAND_INSTANCE_NAME";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AppWindowDefaults<'a> {
    pub title: &'a str,
    pub surface_width: u32,
    pub surface_height: u32,
    pub wayland_app_id: Option<&'a str>,
    pub wayland_instance_name: Option<&'a str>,
}

impl<'a> AppWindowDefaults<'a> {
    pub const fn new(title: &'a str, surface_width: u32, surface_height: u32) -> Self {
        Self {
            title,
            surface_width,
            surface_height,
            wayland_app_id: None,
            wayland_instance_name: None,
        }
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
            undecorated: env_flag_any(&[UNDECORATED_ENV, LEGACY_UNDECORATED_ENV]),
            wayland_app_id,
            wayland_instance_name,
        }
    }
}

fn derive_wayland_instance_name(app_id: &str) -> String {
    app_id
        .rsplit_once('.')
        .map(|(_, suffix)| suffix.to_owned())
        .unwrap_or_else(|| app_id.to_owned())
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
        AppWindowDefaults, AppWindowEnvironment, APP_TITLE_ENV, LEGACY_APP_TITLE_ENV,
        LEGACY_SURFACE_HEIGHT_ENV, LEGACY_SURFACE_WIDTH_ENV, LEGACY_UNDECORATED_ENV,
        LEGACY_WAYLAND_APP_ID_ENV, LEGACY_WAYLAND_INSTANCE_NAME_ENV, SURFACE_HEIGHT_ENV,
        SURFACE_WIDTH_ENV, UNDECORATED_ENV, WAYLAND_APP_ID_ENV, WAYLAND_INSTANCE_NAME_ENV,
    };

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn clear_window_env() {
        for key in [
            APP_TITLE_ENV,
            SURFACE_WIDTH_ENV,
            SURFACE_HEIGHT_ENV,
            UNDECORATED_ENV,
            WAYLAND_APP_ID_ENV,
            WAYLAND_INSTANCE_NAME_ENV,
            LEGACY_APP_TITLE_ENV,
            LEGACY_SURFACE_WIDTH_ENV,
            LEGACY_SURFACE_HEIGHT_ENV,
            LEGACY_UNDECORATED_ENV,
            LEGACY_WAYLAND_APP_ID_ENV,
            LEGACY_WAYLAND_INSTANCE_NAME_ENV,
        ] {
            std::env::remove_var(key);
        }
    }

    fn defaults() -> AppWindowDefaults<'static> {
        AppWindowDefaults::new("Shadow Notes", 540, 1106)
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
        assert_eq!(parsed.surface_height, 1106);
        assert!(!parsed.undecorated);
        assert_eq!(parsed.wayland_app_id.as_deref(), Some("dev.shadow.notes"));
        assert_eq!(
            parsed.wayland_instance_name.as_deref(),
            Some("notes-window")
        );
    }

    #[test]
    fn window_env_honors_shadow_env_overrides() {
        let _guard = env_lock().lock().expect("env lock");
        clear_window_env();
        std::env::set_var(APP_TITLE_ENV, " Custom Title ");
        std::env::set_var(SURFACE_WIDTH_ENV, "720");
        std::env::set_var(SURFACE_HEIGHT_ENV, "1280");
        std::env::set_var(UNDECORATED_ENV, "");
        std::env::set_var(WAYLAND_APP_ID_ENV, "dev.shadow.custom");
        std::env::set_var(WAYLAND_INSTANCE_NAME_ENV, "custom-instance");

        let parsed = AppWindowEnvironment::from_env(defaults());
        assert_eq!(parsed.title, "Custom Title");
        assert_eq!(parsed.surface_width, 720);
        assert_eq!(parsed.surface_height, 1280);
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

        let parsed = AppWindowEnvironment::from_env(AppWindowDefaults::new("Timeline", 540, 1106));
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
        std::env::set_var(LEGACY_SURFACE_WIDTH_ENV, "900");
        std::env::set_var(LEGACY_SURFACE_HEIGHT_ENV, "1600");
        std::env::set_var(LEGACY_UNDECORATED_ENV, "");
        std::env::set_var(LEGACY_WAYLAND_APP_ID_ENV, "dev.shadow.legacy");
        std::env::set_var(LEGACY_WAYLAND_INSTANCE_NAME_ENV, "legacy-instance");

        let parsed = AppWindowEnvironment::from_env(defaults());
        assert_eq!(parsed.title, "Legacy Title");
        assert_eq!(parsed.surface_width, 900);
        assert_eq!(parsed.surface_height, 1600);
        assert!(parsed.undecorated);
        assert_eq!(parsed.wayland_app_id.as_deref(), Some("dev.shadow.legacy"));
        assert_eq!(
            parsed.wayland_instance_name.as_deref(),
            Some("legacy-instance")
        );
    }
}
