use shadow_sdk::ui::{
    body_text, caption_text, column, eyebrow_text, panel, primary_button, secondary_button,
    status_chip, text_field, top_bar, AsUnit, MainAxisAlignment, UiContext, WidgetView,
};

use crate::{TimelineApp, TimelineStatus};

pub(crate) fn onboarding_screen(
    ui: UiContext,
    nsec_input: String,
    status: TimelineStatus,
    action_pending: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    column((
        top_bar(
            theme,
            "Shadow Nostr",
            "Set up account",
            Some(String::from("Import an nsec or create a new key.")),
        ),
        panel(
            theme,
            column((
                eyebrow_text("First run", theme),
                body_text(
                    "Shadow needs one active Nostr account before it can sync a real timeline.",
                    theme,
                ),
                text_field(
                    nsec_input,
                    "Paste nsec to import",
                    theme,
                    |app: &mut TimelineApp, value| {
                        app.nsec_input = value;
                    },
                ),
                column((
                    primary_button("Import nsec", theme, |app: &mut TimelineApp| {
                        app.begin_account_import();
                    }),
                    secondary_button("Generate new", theme, |app: &mut TimelineApp| {
                        app.begin_account_generate();
                    }),
                ))
                .gap(10.0.px())
                .main_axis_alignment(MainAxisAlignment::Start),
                column((
                    status_chip(status.message, status.tone, theme),
                    caption_text(
                        if action_pending {
                            "Waiting for the shared Nostr service..."
                        } else {
                            "Stored in the shared Nostr service once created."
                        },
                        theme,
                    ),
                ))
                .gap(8.0.px()),
            ))
            .gap(12.0.px()),
        ),
    ))
    .gap(12.0.px())
}
