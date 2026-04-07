use crate::color::{Color, ICON_CYAN, ICON_ORANGE};

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
pub struct DemoApp {
    pub id: AppId,
    pub title: &'static str,
    pub subtitle: &'static str,
    pub binary_name: &'static str,
    pub wayland_app_id: &'static str,
    pub window_title: &'static str,
    pub runtime_bundle_env: &'static str,
    pub runtime_input_path: &'static str,
    pub runtime_cache_dir: &'static str,
    pub icon_color: Color,
}

pub const COUNTER_APP_ID: AppId = AppId::new("counter");
pub const COUNTER_WAYLAND_APP_ID: &str = "dev.shadow.counter";
pub const COUNTER_WINDOW_TITLE: &str = "Shadow Counter";
pub const COUNTER_RUNTIME_BUNDLE_ENV: &str = "SHADOW_RUNTIME_APP_COUNTER_BUNDLE_PATH";
pub const COUNTER_RUNTIME_INPUT_PATH: &str = "runtime/app-counter/app.tsx";
pub const COUNTER_RUNTIME_CACHE_DIR: &str = "build/runtime/app-counter-host";
pub const TIMELINE_APP_ID: AppId = AppId::new("timeline");
pub const TIMELINE_WAYLAND_APP_ID: &str = "dev.shadow.timeline";
pub const TIMELINE_WINDOW_TITLE: &str = "Shadow Timeline";
pub const TIMELINE_RUNTIME_BUNDLE_ENV: &str = "SHADOW_RUNTIME_APP_TIMELINE_BUNDLE_PATH";
pub const TIMELINE_RUNTIME_INPUT_PATH: &str = "runtime/app-nostr-timeline/app.tsx";
pub const TIMELINE_RUNTIME_CACHE_DIR: &str = "build/runtime/app-nostr-timeline-host";
pub const SHELL_APP_ID: AppId = AppId::new("shell");
pub const SHELL_WAYLAND_APP_ID: &str = "dev.shadow.shell";
pub const COUNTER_APP: DemoApp = DemoApp {
    id: COUNTER_APP_ID,
    title: "Counter",
    subtitle: "Solid runtime",
    binary_name: "shadow-blitz-demo",
    wayland_app_id: COUNTER_WAYLAND_APP_ID,
    window_title: COUNTER_WINDOW_TITLE,
    runtime_bundle_env: COUNTER_RUNTIME_BUNDLE_ENV,
    runtime_input_path: COUNTER_RUNTIME_INPUT_PATH,
    runtime_cache_dir: COUNTER_RUNTIME_CACHE_DIR,
    icon_color: ICON_CYAN,
};
pub const TIMELINE_APP: DemoApp = DemoApp {
    id: TIMELINE_APP_ID,
    title: "Timeline",
    subtitle: "Local Nostr client",
    binary_name: "shadow-blitz-demo",
    wayland_app_id: TIMELINE_WAYLAND_APP_ID,
    window_title: TIMELINE_WINDOW_TITLE,
    runtime_bundle_env: TIMELINE_RUNTIME_BUNDLE_ENV,
    runtime_input_path: TIMELINE_RUNTIME_INPUT_PATH,
    runtime_cache_dir: TIMELINE_RUNTIME_CACHE_DIR,
    icon_color: ICON_ORANGE,
};

pub const DEMO_APPS: [DemoApp; 2] = [COUNTER_APP, TIMELINE_APP];

pub fn find_app(id: AppId) -> Option<&'static DemoApp> {
    DEMO_APPS.iter().find(|app| app.id == id)
}

pub fn find_app_by_str(value: &str) -> Option<&'static DemoApp> {
    DEMO_APPS.iter().find(|app| app.id.as_str() == value)
}

pub fn find_app_by_wayland_app_id(value: &str) -> Option<&'static DemoApp> {
    DEMO_APPS.iter().find(|app| app.wayland_app_id == value)
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
    &DEMO_APPS
}

#[cfg(test)]
mod tests {
    use super::{
        app_id_from_wayland_app_id, binary_name_for, find_app, find_app_by_str, home_apps,
        COUNTER_APP, COUNTER_APP_ID, COUNTER_WAYLAND_APP_ID, SHELL_APP_ID, SHELL_WAYLAND_APP_ID,
        TIMELINE_APP, TIMELINE_APP_ID, TIMELINE_WAYLAND_APP_ID,
    };

    #[test]
    fn counter_app_lookup_round_trips() {
        let app = find_app(COUNTER_APP_ID).expect("counter app present");
        assert_eq!(app, &COUNTER_APP);
        assert_eq!(COUNTER_APP_ID.as_str(), "counter");
        assert_eq!(find_app_by_str("counter"), Some(&COUNTER_APP));
        assert_eq!(binary_name_for(COUNTER_APP_ID), Some("shadow-blitz-demo"));
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
    fn timeline_app_lookup_round_trips() {
        let app = find_app(TIMELINE_APP_ID).expect("timeline app present");
        assert_eq!(app, &TIMELINE_APP);
        assert_eq!(TIMELINE_APP_ID.as_str(), "timeline");
        assert_eq!(find_app_by_str("timeline"), Some(&TIMELINE_APP));
        assert_eq!(binary_name_for(TIMELINE_APP_ID), Some("shadow-blitz-demo"));
        assert_eq!(
            app_id_from_wayland_app_id(TIMELINE_WAYLAND_APP_ID),
            Some(TIMELINE_APP_ID)
        );
        assert_eq!(home_apps()[1].id, TIMELINE_APP_ID);
    }
}
