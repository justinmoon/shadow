use crate::color::{
    Color, ICON_BLUE, ICON_CYAN, ICON_GREEN, ICON_ORANGE, ICON_PINK, ICON_PURPLE, ICON_RED,
    ICON_YELLOW,
};

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
    pub icon_color: Color,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
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
};

pub const DEMO_APPS: [DemoApp; 1] = [COUNTER_APP];

pub const HOME_TILES: [HomeTile; 8] = [
    HomeTile {
        label: "Phone",
        color: ICON_GREEN,
        app_id: None,
    },
    HomeTile {
        label: "Messages",
        color: ICON_BLUE,
        app_id: None,
    },
    HomeTile {
        label: "Camera",
        color: ICON_ORANGE,
        app_id: None,
    },
    HomeTile {
        label: "Settings",
        color: ICON_RED,
        app_id: None,
    },
    HomeTile {
        label: COUNTER_APP.title,
        color: COUNTER_APP.icon_color,
        app_id: Some(COUNTER_APP.id),
    },
    HomeTile {
        label: "Files",
        color: ICON_YELLOW,
        app_id: None,
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

#[cfg(test)]
mod tests {
    use super::{
        app_id_from_wayland_app_id, binary_name_for, find_app, find_app_by_str, COUNTER_APP,
        COUNTER_APP_ID, COUNTER_WAYLAND_APP_ID, HOME_TILES,
    };

    #[test]
    fn counter_app_lookup_round_trips() {
        let app = find_app(COUNTER_APP_ID).expect("counter app present");
        assert_eq!(app, &COUNTER_APP);
        assert_eq!(COUNTER_APP_ID.as_str(), "counter");
        assert_eq!(find_app_by_str("counter"), Some(&COUNTER_APP));
        assert_eq!(binary_name_for(COUNTER_APP_ID), Some("shadow-counter"));
        assert_eq!(
            app_id_from_wayland_app_id(COUNTER_WAYLAND_APP_ID),
            Some(COUNTER_APP_ID)
        );
        assert_eq!(HOME_TILES[4].app_id, Some(COUNTER_APP_ID));
    }
}
