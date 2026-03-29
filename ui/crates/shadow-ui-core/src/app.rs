use crate::color::{Color, ICON_CYAN, ICON_ORANGE, ICON_PINK, ICON_PURPLE, ICON_YELLOW};

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

#[derive(Clone, Copy, Debug)]
pub struct DemoApp {
    pub id: AppId,
    pub title: &'static str,
    pub subtitle: &'static str,
    pub binary_name: &'static str,
    pub wayland_app_id: &'static str,
    pub icon_color: Color,
    pub prefer_cargo_run: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct HomeTile {
    pub label: &'static str,
    pub color: Color,
    pub app_id: Option<AppId>,
}

pub const COUNTER_APP_ID: AppId = AppId::new("counter");
pub const COUNTER_WAYLAND_APP_ID: &str = "dev.shadow.counter";
pub const COUNTER_APP: DemoApp = DemoApp {
    id: COUNTER_APP_ID,
    title: "Counter",
    subtitle: "Tap tracker",
    binary_name: "shadow-counter",
    wayland_app_id: COUNTER_WAYLAND_APP_ID,
    icon_color: ICON_CYAN,
    prefer_cargo_run: false,
};

pub const STATUS_APP_ID: AppId = AppId::new("status");
pub const STATUS_WAYLAND_APP_ID: &str = "dev.shadow.status";
pub const STATUS_APP: DemoApp = DemoApp {
    id: STATUS_APP_ID,
    title: "Status",
    subtitle: "Radio and profile controls",
    binary_name: "shadow-status",
    wayland_app_id: STATUS_WAYLAND_APP_ID,
    icon_color: ICON_YELLOW,
    prefer_cargo_run: false,
};

pub const BLITZ_DEMO_APP_ID: AppId = AppId::new("blitz-demo");
pub const BLITZ_DEMO_WAYLAND_APP_ID: &str = "dev.shadow.blitz";
pub const BLITZ_DEMO_APP: DemoApp = DemoApp {
    id: BLITZ_DEMO_APP_ID,
    title: "Blitz",
    subtitle: "TS state over stdio",
    binary_name: "shadow-blitz-demo",
    wayland_app_id: BLITZ_DEMO_WAYLAND_APP_ID,
    icon_color: ICON_PINK,
    prefer_cargo_run: true,
};

pub const DEMO_APPS: [DemoApp; 3] = [COUNTER_APP, STATUS_APP, BLITZ_DEMO_APP];
pub const DESKTOP_WAYLAND_APP_ID: &str = "dev.shadow.desktop";

pub const HOME_TILES: [HomeTile; 8] = [
    HomeTile {
        label: "Messages",
        color: ICON_CYAN,
        app_id: None,
    },
    HomeTile {
        label: "Camera",
        color: ICON_ORANGE,
        app_id: None,
    },
    HomeTile {
        label: STATUS_APP.title,
        color: STATUS_APP.icon_color,
        app_id: Some(STATUS_APP.id),
    },
    HomeTile {
        label: "Browser",
        color: ICON_CYAN,
        app_id: None,
    },
    HomeTile {
        label: BLITZ_DEMO_APP.title,
        color: BLITZ_DEMO_APP.icon_color,
        app_id: Some(BLITZ_DEMO_APP.id),
    },
    HomeTile {
        label: COUNTER_APP.title,
        color: COUNTER_APP.icon_color,
        app_id: Some(COUNTER_APP.id),
    },
    HomeTile {
        label: "Maps",
        color: ICON_PINK,
        app_id: None,
    },
    HomeTile {
        label: "Music",
        color: ICON_PURPLE,
        app_id: None,
    },
];

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
    find_app_by_wayland_app_id(value).map(|app| app.id)
}

pub fn binary_name_for(id: AppId) -> Option<&'static str> {
    find_app(id).map(|app| app.binary_name)
}
