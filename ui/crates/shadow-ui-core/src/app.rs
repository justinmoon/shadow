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
pub struct AppRuntimeMetadata {
    pub bundle_env: &'static str,
    pub input_path: &'static str,
    pub cache_dir: &'static str,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AppLaunchModel {
    TypeScript { runtime: AppRuntimeMetadata },
    Rust,
}

pub type AppLaunchEnv = (&'static str, &'static str);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ManifestAppLaunch {
    TypeScript {
        runtime: AppRuntimeMetadata,
        launch_env: &'static [AppLaunchEnv],
    },
    Rust {
        launch_env: &'static [AppLaunchEnv],
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AppLaunchSpec {
    pub id: AppId,
    pub binary_name: &'static str,
    pub wayland_app_id: &'static str,
    pub window_title: &'static str,
    pub model: AppLaunchModel,
    pub launch_env: &'static [AppLaunchEnv],
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
    pub manifest_launch: ManifestAppLaunch,
    pub icon_color: Color,
}

impl DemoApp {
    pub const fn launch_spec(self) -> AppLaunchSpec {
        self.manifest_launch.launch_spec(
            self.id,
            self.binary_name,
            self.wayland_app_id,
            self.window_title,
        )
    }
}

impl AppLaunchSpec {
    pub const fn typescript_runtime(self) -> Option<AppRuntimeMetadata> {
        match self.model {
            AppLaunchModel::TypeScript { runtime } => Some(runtime),
            AppLaunchModel::Rust => None,
        }
    }
}

impl ManifestAppLaunch {
    pub const fn model(self) -> AppLaunchModel {
        match self {
            Self::TypeScript { runtime, .. } => AppLaunchModel::TypeScript { runtime },
            Self::Rust { .. } => AppLaunchModel::Rust,
        }
    }

    pub const fn typescript_runtime(self) -> Option<AppRuntimeMetadata> {
        match self {
            Self::TypeScript { runtime, .. } => Some(runtime),
            Self::Rust { .. } => None,
        }
    }

    pub const fn runtime_bundle_env(self) -> &'static str {
        match self {
            Self::TypeScript { runtime, .. } => runtime.bundle_env,
            Self::Rust { .. } => "",
        }
    }

    pub const fn runtime_input_path(self) -> &'static str {
        match self {
            Self::TypeScript { runtime, .. } => runtime.input_path,
            Self::Rust { .. } => "",
        }
    }

    pub const fn runtime_cache_dir(self) -> &'static str {
        match self {
            Self::TypeScript { runtime, .. } => runtime.cache_dir,
            Self::Rust { .. } => "",
        }
    }

    pub const fn launch_env(self) -> &'static [AppLaunchEnv] {
        match self {
            Self::TypeScript { launch_env, .. } | Self::Rust { launch_env } => launch_env,
        }
    }

    pub const fn launch_spec(
        self,
        id: AppId,
        binary_name: &'static str,
        wayland_app_id: &'static str,
        window_title: &'static str,
    ) -> AppLaunchSpec {
        AppLaunchSpec {
            id,
            binary_name,
            wayland_app_id,
            window_title,
            model: self.model(),
            launch_env: self.launch_env(),
        }
    }
}

#[path = "generated_apps.rs"]
mod generated_apps;
#[path = "generated_manifest_launch.rs"]
mod generated_manifest_launch;
pub use self::generated_apps::*;
pub use self::generated_manifest_launch::*;

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
        launch_spec, AppId, AppLaunchModel, AppLaunchSpec, AppModel, DemoApp,
        ManifestAppLaunch, CAMERA_APP, CAMERA_APP_ID, CAMERA_WAYLAND_APP_ID, CASHU_APP,
        CASHU_APP_ID, CASHU_WAYLAND_APP_ID, COUNTER_APP, COUNTER_APP_ID, COUNTER_WAYLAND_APP_ID,
        DEMO_APPS, PIXEL_SHELL_DEMO_APPS, PODCAST_APP, PODCAST_APP_ID, PODCAST_WAYLAND_APP_ID,
        RUST_DEMO_APP, RUST_DEMO_APP_ID, RUST_DEMO_WAYLAND_APP_ID, RUST_TIMELINE_APP,
        RUST_TIMELINE_APP_ID, RUST_TIMELINE_WAYLAND_APP_ID, SESSION_APP_PROFILE_ENV,
        SHELL_APP_ID, SHELL_WAYLAND_APP_ID, TIMELINE_APP, TIMELINE_APP_ID,
        TIMELINE_WAYLAND_APP_ID, VM_SHELL_DEMO_APPS,
    };

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    fn with_session_profile<T>(profile: Option<&str>, run: impl FnOnce() -> T) -> T {
        let _guard = env_lock().lock().expect("env lock");
        let previous = std::env::var(SESSION_APP_PROFILE_ENV).ok();
        match profile {
            Some(profile) => std::env::set_var(SESSION_APP_PROFILE_ENV, profile),
            None => std::env::remove_var(SESSION_APP_PROFILE_ENV),
        }
        let result = run();
        match previous {
            Some(previous) => std::env::set_var(SESSION_APP_PROFILE_ENV, previous),
            None => std::env::remove_var(SESSION_APP_PROFILE_ENV),
        }
        result
    }

    fn assert_manifest_launch_compat(app: &DemoApp) {
        assert_eq!(
            app.launch_spec(),
            app.manifest_launch.launch_spec(
                app.id,
                app.binary_name,
                app.wayland_app_id,
                app.window_title,
            )
        );
    }

    fn assert_current_typescript_app(app: &DemoApp) {
        assert_eq!(app.model, AppModel::TypeScript);
        assert_manifest_launch_compat(app);
        let ManifestAppLaunch::TypeScript { runtime, launch_env } = app.manifest_launch else {
            panic!("current manifest apps should have TypeScript launch metadata");
        };
        assert_eq!(
            launch_spec(app.id),
            Some(AppLaunchSpec {
                id: app.id,
                binary_name: app.binary_name,
                wayland_app_id: app.wayland_app_id,
                window_title: app.window_title,
                model: AppLaunchModel::TypeScript { runtime },
                launch_env,
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
            manifest_launch: ManifestAppLaunch::Rust { launch_env: &[] },
            icon_color: crate::color::ICON_PURPLE,
        };

        let spec = app.launch_spec();
        assert_eq!(spec.id, app.id);
        assert_eq!(spec.binary_name, "shadow-rust-demo");
        assert_eq!(spec.wayland_app_id, "dev.shadow.rust-notes");
        assert_eq!(spec.window_title, "Rust Notes");
        assert_eq!(spec.model, AppLaunchModel::Rust);
        assert!(spec.launch_env.is_empty());
        assert_eq!(spec.typescript_runtime(), None);
        assert_manifest_launch_compat(&app);
    }

    #[test]
    fn counter_app_lookup_round_trips() {
        with_session_profile(None, || {
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
        });
    }

    #[test]
    fn camera_app_lookup_round_trips() {
        with_session_profile(None, || {
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
        });
    }

    #[test]
    fn timeline_app_lookup_round_trips() {
        with_session_profile(None, || {
            let app = find_app(TIMELINE_APP_ID).expect("timeline app present");
            assert_eq!(app, &TIMELINE_APP);
            assert_eq!(TIMELINE_APP_ID.as_str(), "timeline");
            assert_eq!(find_app_by_str("timeline"), Some(&TIMELINE_APP));
            assert_eq!(binary_name_for(TIMELINE_APP_ID), Some("shadow-blitz-demo"));
            assert_eq!(app.icon_label, "TL");
            assert!(app.lifecycle_hint.contains("cached feed"));
            assert_current_typescript_app(app);
            assert_eq!(
                app_id_from_wayland_app_id(TIMELINE_WAYLAND_APP_ID),
                Some(TIMELINE_APP_ID)
            );
            assert_eq!(home_apps()[2].id, TIMELINE_APP_ID);
        });
    }

    #[test]
    fn podcast_app_lookup_round_trips() {
        with_session_profile(None, || {
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
        });
    }

    #[test]
    fn cashu_app_lookup_round_trips() {
        with_session_profile(None, || {
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
        });
    }

    #[test]
    fn rust_demo_app_lookup_round_trips() {
        with_session_profile(None, || {
            let app = find_app(RUST_DEMO_APP_ID).expect("rust demo app present");
            assert_eq!(app, &RUST_DEMO_APP);
            assert_eq!(RUST_DEMO_APP_ID.as_str(), "rust-demo");
            assert_eq!(find_app_by_str("rust-demo"), Some(&RUST_DEMO_APP));
            assert_eq!(binary_name_for(RUST_DEMO_APP_ID), Some("shadow-rust-demo"));
            assert_eq!(app.icon_label, "RS");
            assert!(app.lifecycle_hint.contains("native binary launch path"));
            assert_eq!(app.model, AppModel::Rust);
            assert_manifest_launch_compat(app);
            assert_eq!(
                app.manifest_launch,
                ManifestAppLaunch::Rust {
                    launch_env: &[("SHADOW_RUNTIME_CAMERA_ALLOW_MOCK", "1")],
                }
            );
            assert_eq!(
                launch_spec(RUST_DEMO_APP_ID),
                Some(AppLaunchSpec {
                    id: RUST_DEMO_APP_ID,
                    binary_name: "shadow-rust-demo",
                    wayland_app_id: RUST_DEMO_WAYLAND_APP_ID,
                    window_title: "Shadow Rust Demo",
                    model: AppLaunchModel::Rust,
                    launch_env: &[("SHADOW_RUNTIME_CAMERA_ALLOW_MOCK", "1")],
                })
            );
            assert_eq!(
                RUST_DEMO_APP.manifest_launch.launch_env(),
                &[("SHADOW_RUNTIME_CAMERA_ALLOW_MOCK", "1")]
            );
            assert_eq!(
                app_id_from_wayland_app_id(RUST_DEMO_WAYLAND_APP_ID),
                Some(RUST_DEMO_APP_ID)
            );
            assert_eq!(home_apps()[5].id, RUST_DEMO_APP_ID);
        });
    }

    #[test]
    fn rust_timeline_app_lookup_round_trips() {
        with_session_profile(None, || {
            let app = find_app(RUST_TIMELINE_APP_ID).expect("rust timeline app present");
            assert_eq!(app, &RUST_TIMELINE_APP);
            assert_eq!(RUST_TIMELINE_APP_ID.as_str(), "rust-timeline");
            assert_eq!(find_app_by_str("rust-timeline"), Some(&RUST_TIMELINE_APP));
            assert_eq!(
                binary_name_for(RUST_TIMELINE_APP_ID),
                Some("shadow-rust-timeline")
            );
            assert_eq!(app.icon_label, "NR");
            assert!(app.lifecycle_hint.contains("cache-backed feed"));
            assert_eq!(app.model, AppModel::Rust);
            assert_manifest_launch_compat(app);
            assert_eq!(
                app.manifest_launch,
                ManifestAppLaunch::Rust {
                    launch_env: &[
                        ("SHADOW_RUST_TIMELINE_LIMIT", "18"),
                        (
                            "SHADOW_RUST_TIMELINE_RELAY_URLS",
                            "wss://relay.primal.net/,wss://relay.damus.io/",
                        ),
                        ("SHADOW_RUST_TIMELINE_SYNC_ON_START", "1"),
                    ],
                }
            );
            assert_eq!(
                launch_spec(RUST_TIMELINE_APP_ID),
                Some(AppLaunchSpec {
                    id: RUST_TIMELINE_APP_ID,
                    binary_name: "shadow-rust-timeline",
                    wayland_app_id: RUST_TIMELINE_WAYLAND_APP_ID,
                    window_title: "Shadow Rust Timeline",
                    model: AppLaunchModel::Rust,
                    launch_env: &[
                        ("SHADOW_RUST_TIMELINE_LIMIT", "18"),
                        (
                            "SHADOW_RUST_TIMELINE_RELAY_URLS",
                            "wss://relay.primal.net/,wss://relay.damus.io/",
                        ),
                        ("SHADOW_RUST_TIMELINE_SYNC_ON_START", "1"),
                    ],
                })
            );
            assert_eq!(
                RUST_TIMELINE_APP.manifest_launch.launch_env(),
                &[
                    ("SHADOW_RUST_TIMELINE_LIMIT", "18"),
                    (
                        "SHADOW_RUST_TIMELINE_RELAY_URLS",
                        "wss://relay.primal.net/,wss://relay.damus.io/",
                    ),
                    ("SHADOW_RUST_TIMELINE_SYNC_ON_START", "1"),
                ]
            );
            assert_eq!(
                app_id_from_wayland_app_id(RUST_TIMELINE_WAYLAND_APP_ID),
                Some(RUST_TIMELINE_APP_ID)
            );
            assert_eq!(home_apps()[6].id, RUST_TIMELINE_APP_ID);
        });
    }

    #[test]
    fn vm_shell_profile_includes_rust_apps() {
        with_session_profile(Some("vm-shell"), || {
            assert_eq!(home_apps(), &VM_SHELL_DEMO_APPS);
            assert!(home_apps().iter().any(|app| app.id == RUST_DEMO_APP_ID));
            assert!(home_apps().iter().any(|app| app.id == RUST_TIMELINE_APP_ID));
        });
    }

    #[test]
    fn pixel_shell_profile_stays_typescript_only() {
        with_session_profile(Some("pixel-shell"), || {
            assert_eq!(home_apps(), &PIXEL_SHELL_DEMO_APPS);
            assert!(home_apps()
                .iter()
                .all(|app| app.model == AppModel::TypeScript));
            assert!(home_apps().iter().all(|app| app.id != RUST_DEMO_APP_ID));
            assert!(home_apps().iter().all(|app| app.id != RUST_TIMELINE_APP_ID));
            assert_eq!(find_app(RUST_DEMO_APP_ID), None);
            assert_eq!(find_app(RUST_TIMELINE_APP_ID), None);
        });
    }

    #[test]
    fn unknown_profile_env_falls_back_to_full_app_list() {
        with_session_profile(Some("unknown-profile"), || {
            assert_eq!(home_apps().len(), DEMO_APPS.len());
        });
    }
}
