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
    pub binary_name: &'static str,
}

pub const COUNTER_APP_ID: AppId = AppId::new("counter");
pub const COUNTER_APP: DemoApp = DemoApp {
    id: COUNTER_APP_ID,
    title: "Counter",
    binary_name: "shadow-counter",
};

pub const DEMO_APPS: [DemoApp; 1] = [COUNTER_APP];

pub fn find_app(id: AppId) -> Option<&'static DemoApp> {
    DEMO_APPS.iter().find(|app| app.id == id)
}

pub fn binary_name_for(id: AppId) -> Option<&'static str> {
    find_app(id).map(|app| app.binary_name)
}

#[cfg(test)]
mod tests {
    use super::{binary_name_for, find_app, COUNTER_APP, COUNTER_APP_ID};

    #[test]
    fn counter_app_lookup_round_trips() {
        let app = find_app(COUNTER_APP_ID).expect("counter app present");
        assert_eq!(app, &COUNTER_APP);
        assert_eq!(COUNTER_APP_ID.as_str(), "counter");
        assert_eq!(binary_name_for(COUNTER_APP_ID), Some("shadow-counter"));
    }
}
