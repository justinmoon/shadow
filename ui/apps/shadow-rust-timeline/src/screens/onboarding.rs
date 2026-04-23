use shadow_sdk::ui::{
    column, AsUnit, MainAxisAlignment, UiContext, WidgetView,
};

use crate::{TimelineApp, TimelineStatus};

pub(crate) fn onboarding_screen(
    ui: UiContext,
    nsec_input: String,
    status: TimelineStatus,
    action_pending: bool,
) -> impl WidgetView<TimelineApp> {
    column((
        ui.top_bar(
            "Shadow Nostr",
            "Set up account",
            Some(String::from("Import an nsec or create a new key.")),
        ),
        ui.panel(
            column((
                ui.eyebrow_text("First run"),
                ui.body_text(
                    "Shadow needs one active Nostr account before it can sync a real timeline.",
                ),
                ui.text_field(
                    nsec_input,
                    "Paste nsec to import",
                    |app: &mut TimelineApp, value| {
                        app.nsec_input = value;
                    },
                ),
                column((
                    ui.primary_button("Import nsec", |app: &mut TimelineApp| {
                        app.begin_account_import();
                    }),
                    ui.secondary_button("Generate new", |app: &mut TimelineApp| {
                        app.begin_account_generate();
                    }),
                ))
                .gap(10.0.px())
                .main_axis_alignment(MainAxisAlignment::Start),
                column((
                    ui.status_chip(status.message, status.tone),
                    ui.caption_text(
                        if action_pending {
                            "Waiting for the shared Nostr service..."
                        } else {
                            "Stored in the shared Nostr service once created."
                        },
                    ),
                ))
                .gap(8.0.px()),
            ))
            .gap(12.0.px()),
        ),
    ))
    .gap(12.0.px())
}
