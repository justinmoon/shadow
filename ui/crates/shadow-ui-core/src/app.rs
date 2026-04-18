use crate::color::Color;

const SESSION_APP_PROFILE_ENV: &str = "SHADOW_SESSION_APP_PROFILE";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct AppId(&'static str);

impl AppId {
    pub const fn new(value: &'static str) -> Self {
        Self(value)
    }

    pub const fn as_str(self) -> &'static str {
        self.0
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AppModel {
    TypeScript,
    Rust,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TypeScriptAppRuntime {
    pub bundle_env: &'static str,
    pub input_path: &'static str,
    pub cache_dir: &'static str,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AppLaunchModel {
    TypeScript { runtime: TypeScriptAppRuntime },
    Rust,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AppLaunchSpec {
    pub id: AppId,
    pub binary_name: &'static str,
    pub wayland_app_id: &'static str,
    pub window_title: &'static str,
    pub model: AppLaunchModel,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DemoApp {
    pub id: AppId,
    pub model: AppModel,
    pub icon_label: &'static str,
    pub title: &'static str,
    pub subtitle: &'static str,
    pub lifecycle_hint: &'static str,
    pub binary_name: &'static str,
    pub wayland_app_id: &'static str,
    pub window_title: &'static str,
    pub typescript_runtime: Option<TypeScriptAppRuntime>,
    pub runtime_bundle_env: &'static str,
    pub runtime_input_path: &'static str,
    pub runtime_cache_dir: &'static str,
    pub icon_color: Color,
}

impl DemoApp {
    pub const fn launch_spec(self) -> AppLaunchSpec {
        let model = match self.typescript_runtime {
            Some(runtime) => AppLaunchModel::TypeScript { runtime },
            None => AppLaunchModel::Rust,
        };
        AppLaunchSpec {
            id: self.id,
            binary_name: self.binary_name,
            wayland_app_id: self.wayland_app_id,
            window_title: self.window_title,
            model,
        }
    }
}

impl AppLaunchSpec {
    pub const fn typescript_runtime(self) -> Option<TypeScriptAppRuntime> {
        match self.model {
            AppLaunchModel::TypeScript { runtime } => Some(runtime),
            AppLaunchModel::Rust => None,
        }
    }
}

#[path = "generated_apps.rs"]
mod generated_apps;
pub use self::generated_apps::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SessionAppProfile {
    VmShell,
    PixelShell,
}

impl SessionAppProfile {
    fn from_env() -> Option<Self> {
        match std::env::var(SESSION_APP_PROFILE_ENV).ok()?.trim() {
            "vm-shell" => Some(Self::VmShell),
            "pixel-shell" => Some(Self::PixelShell),
            _ => None,
        }
    }
}

fn visible_apps() -> &'static [DemoApp] {
    match SessionAppProfile::from_env() {
        Some(SessionAppProfile::VmShell) => &VM_SHELL_DEMO_APPS,
        Some(SessionAppProfile::PixelShell) => &PIXEL_SHELL_DEMO_APPS,
        None => &DEMO_APPS,
    }
}

pub fn find_app(id: AppId) -> Option<&'static DemoApp> {
    visible_apps().iter().find(|app| app.id == id)
}

pub fn launch_spec(id: AppId) -> Option<AppLaunchSpec> {
    find_app(id).copied().map(DemoApp::launch_spec)
}

pub fn find_app_by_str(value: &str) -> Option<&'static DemoApp> {
    visible_apps().iter().find(|app| app.id.as_str() == value)
}

pub fn find_app_by_wayland_app_id(value: &str) -> Option<&'static DemoApp> {
    visible_apps()
        .iter()
        .find(|app| app.wayland_app_id == value)
}

pub fn app_id_from_wayland_app_id(value: &str) -> Option<AppId> {
    if value == SHELL_WAYLAND_APP_ID {
        return Some(SHELL_APP_ID);
    }
    find_app_by_wayland_app_id(value).map(|app| app.id)
}

pub fn binary_name_for(id: AppId) -> Option<&'static str> {
    find_app(id).map(|app| app.binary_name)
}

pub fn home_apps() -> &'static [DemoApp] {
    visible_apps()
}

#[cfg(test)]
mod tests {
    use std::sync::{Mutex, OnceLock};

    use super::{
        app_id_from_wayland_app_id, binary_name_for, find_app, find_app_by_str, home_apps,
        launch_spec, AppId, AppLaunchModel, AppLaunchSpec, AppModel, DemoApp, CAMERA_APP,
        CAMERA_APP_ID, CAMERA_WAYLAND_APP_ID, CASHU_APP, CASHU_APP_ID, CASHU_WAYLAND_APP_ID,
        COUNTER_APP, COUNTER_APP_ID, COUNTER_WAYLAND_APP_ID, DEMO_APPS, PODCAST_APP,
        PODCAST_APP_ID, PODCAST_WAYLAND_APP_ID, SESSION_APP_PROFILE_ENV, SHELL_APP_ID,
        SHELL_WAYLAND_APP_ID, TIMELINE_APP, TIMELINE_APP_ID, TIMELINE_WAYLAND_APP_ID,
    };

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn assert_current_typescript_app(app: &DemoApp) {
        assert_eq!(app.model, AppModel::TypeScript);
        let runtime = app
            .typescript_runtime
            .expect("current manifest apps should have TypeScript runtime metadata");
        assert_eq!(runtime.bundle_env, app.runtime_bundle_env);
        assert_eq!(runtime.input_path, app.runtime_input_path);
        assert_eq!(runtime.cache_dir, app.runtime_cache_dir);
        assert_eq!(
            launch_spec(app.id),
            Some(AppLaunchSpec {
                id: app.id,
                binary_name: app.binary_name,
                wayland_app_id: app.wayland_app_id,
                window_title: app.window_title,
                model: AppLaunchModel::TypeScript { runtime },
            })
        );
    }

    #[test]
    fn rust_launch_spec_has_no_typescript_runtime() {
        let app = DemoApp {
            id: AppId::new("rust-notes"),
            model: AppModel::Rust,
            icon_label: "RN",
            title: "Rust Notes",
            subtitle: "Rust lane",
            lifecycle_hint: "Rust app placeholder.",
            binary_name: "shadow-rust-demo",
            wayland_app_id: "dev.shadow.rust-notes",
            window_title: "Rust Notes",
            typescript_runtime: None,
            runtime_bundle_env: "",
            runtime_input_path: "",
            runtime_cache_dir: "",
            icon_color: crate::color::ICON_PURPLE,
        };

        let spec = app.launch_spec();
        assert_eq!(spec.id, app.id);
        assert_eq!(spec.binary_name, "shadow-rust-demo");
        assert_eq!(spec.wayland_app_id, "dev.shadow.rust-notes");
        assert_eq!(spec.window_title, "Rust Notes");
        assert_eq!(spec.model, AppLaunchModel::Rust);
        assert_eq!(spec.typescript_runtime(), None);
    }

    #[test]
    fn counter_app_lookup_round_trips() {
        let app = find_app(COUNTER_APP_ID).expect("counter app present");
        assert_eq!(app, &COUNTER_APP);
        assert_eq!(COUNTER_APP_ID.as_str(), "counter");
        assert_eq!(find_app_by_str("counter"), Some(&COUNTER_APP));
        assert_eq!(binary_name_for(COUNTER_APP_ID), Some("shadow-blitz-demo"));
        assert_eq!(app.icon_label, "01");
        assert!(app.lifecycle_hint.contains("live counter"));
        assert_current_typescript_app(app);
        assert_eq!(
            app_id_from_wayland_app_id(COUNTER_WAYLAND_APP_ID),
            Some(COUNTER_APP_ID)
        );
        assert_eq!(
            app_id_from_wayland_app_id(SHELL_WAYLAND_APP_ID),
            Some(SHELL_APP_ID)
        );
        assert_eq!(home_apps()[0].id, COUNTER_APP_ID);
    }

    #[test]
    fn camera_app_lookup_round_trips() {
        let app = find_app(CAMERA_APP_ID).expect("camera app present");
        assert_eq!(app, &CAMERA_APP);
        assert_eq!(CAMERA_APP_ID.as_str(), "camera");
        assert_eq!(find_app_by_str("camera"), Some(&CAMERA_APP));
        assert_eq!(binary_name_for(CAMERA_APP_ID), Some("shadow-blitz-demo"));
        assert_eq!(app.icon_label, "CM");
        assert!(app.lifecycle_hint.contains("captured frame"));
        assert_current_typescript_app(app);
        assert_eq!(
            app_id_from_wayland_app_id(CAMERA_WAYLAND_APP_ID),
            Some(CAMERA_APP_ID)
        );
        assert_eq!(home_apps()[1].id, CAMERA_APP_ID);
    }

    #[test]
    fn timeline_app_lookup_round_trips() {
        let app = find_app(TIMELINE_APP_ID).expect("timeline app present");
        assert_eq!(app, &TIMELINE_APP);
        assert_eq!(TIMELINE_APP_ID.as_str(), "timeline");
        assert_eq!(find_app_by_str("timeline"), Some(&TIMELINE_APP));
        assert_eq!(binary_name_for(TIMELINE_APP_ID), Some("shadow-blitz-demo"));
        assert_eq!(app.icon_label, "TL");
        assert!(app.lifecycle_hint.contains("live draft"));
        assert_current_typescript_app(app);
        assert_eq!(
            app_id_from_wayland_app_id(TIMELINE_WAYLAND_APP_ID),
            Some(TIMELINE_APP_ID)
        );
        assert_eq!(home_apps()[2].id, TIMELINE_APP_ID);
    }

    #[test]
    fn podcast_app_lookup_round_trips() {
        let app = find_app(PODCAST_APP_ID).expect("podcast app present");
        assert_eq!(app, &PODCAST_APP);
        assert_eq!(PODCAST_APP_ID.as_str(), "podcast");
        assert_eq!(find_app_by_str("podcast"), Some(&PODCAST_APP));
        assert_eq!(binary_name_for(PODCAST_APP_ID), Some("shadow-blitz-demo"));
        assert_eq!(app.icon_label, "NS");
        assert!(app.lifecycle_hint.contains("episode"));
        assert_current_typescript_app(app);
        assert_eq!(
            app_id_from_wayland_app_id(PODCAST_WAYLAND_APP_ID),
            Some(PODCAST_APP_ID)
        );
        assert_eq!(home_apps()[3].id, PODCAST_APP_ID);
    }

    #[test]
    fn cashu_app_lookup_round_trips() {
        let app = find_app(CASHU_APP_ID).expect("cashu app present");
        assert_eq!(app, &CASHU_APP);
        assert_eq!(CASHU_APP_ID.as_str(), "cashu");
        assert_eq!(find_app_by_str("cashu"), Some(&CASHU_APP));
        assert_eq!(binary_name_for(CASHU_APP_ID), Some("shadow-blitz-demo"));
        assert_eq!(app.icon_label, "CU");
        assert!(app.lifecycle_hint.contains("trusted mints"));
        assert_current_typescript_app(app);
        assert_eq!(
            app_id_from_wayland_app_id(CASHU_WAYLAND_APP_ID),
            Some(CASHU_APP_ID)
        );
        assert_eq!(home_apps()[4].id, CASHU_APP_ID);
    }

    #[test]
    fn unknown_profile_env_falls_back_to_full_app_list() {
        let _guard = env_lock().lock().expect("env lock");
        std::env::set_var(SESSION_APP_PROFILE_ENV, "unknown-profile");
        assert_eq!(home_apps().len(), DEMO_APPS.len());
        std::env::remove_var(SESSION_APP_PROFILE_ENV);
    }
}
