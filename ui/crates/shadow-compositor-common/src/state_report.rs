use std::fmt::Write;

use shadow_ui_core::app::AppId;

pub fn sorted_unique_app_ids_csv(app_ids: impl IntoIterator<Item = AppId>) -> String {
    let mut app_ids: Vec<_> = app_ids.into_iter().map(AppId::as_str).collect();
    app_ids.sort_unstable();
    app_ids.dedup();
    app_ids.join(",")
}

pub fn render_control_state(
    focused_app: Option<AppId>,
    mapped: &str,
    launched: &str,
    shelved: &str,
    windows: usize,
    extra_fields: &[(&str, String)],
) -> String {
    let mut response = format!(
        "focused={}\nmapped={mapped}\nlaunched={launched}\nshelved={shelved}\nwindows={windows}\n",
        focused_app.map(AppId::as_str).unwrap_or(""),
    );
    for (key, value) in extra_fields {
        let _ = writeln!(response, "{key}={value}");
    }
    response
}

#[cfg(test)]
mod tests {
    use shadow_ui_core::app::{COUNTER_APP_ID, PODCAST_APP_ID, TIMELINE_APP_ID};

    use super::{render_control_state, sorted_unique_app_ids_csv};

    #[test]
    fn sorted_unique_app_ids_csv_sorts_and_deduplicates() {
        let app_ids = sorted_unique_app_ids_csv([
            TIMELINE_APP_ID,
            COUNTER_APP_ID,
            TIMELINE_APP_ID,
            PODCAST_APP_ID,
        ]);

        assert_eq!(app_ids, "counter,podcast,timeline");
    }

    #[test]
    fn render_control_state_uses_shared_prefix_and_extra_fields() {
        let extra_fields = vec![
            ("transport", "direct-client-fd".to_string()),
            ("control_socket", "/tmp/shadow.sock".to_string()),
        ];

        let response = render_control_state(
            Some(COUNTER_APP_ID),
            "counter",
            "counter,timeline",
            "timeline",
            2,
            &extra_fields,
        );

        assert_eq!(
            response,
            concat!(
                "focused=counter\n",
                "mapped=counter\n",
                "launched=counter,timeline\n",
                "shelved=timeline\n",
                "windows=2\n",
                "transport=direct-client-fd\n",
                "control_socket=/tmp/shadow.sock\n",
            )
        );
    }
}
