use shadow_sdk::{
    services::nostr::NostrEvent,
    ui::{
        body_text, caption_text, column, eyebrow_text, headline_text, maybe, multiline_editor,
        panel, primary_button, primary_button_state, row, secondary_button, secondary_button_state,
        status_chip, text_field, top_bar, with_sheet, ActionButtonState, AsUnit, FlexExt,
        MainAxisAlignment, UiContext, WidgetView,
    },
};

use super::shared::{feed_section, home_feed_empty_message};
use crate::{plural_suffix, ActiveAccount, FeedScope, RefreshSource, TimelineApp, TimelineStatus};

pub(crate) fn timeline_screen(
    ui: UiContext,
    account: Option<ActiveAccount>,
    feed_scope: FeedScope,
    status: TimelineStatus,
    notes: Vec<NostrEvent>,
    filter_text: String,
    note_draft: Option<String>,
    publish_blocked: bool,
    note_publish_pending: bool,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let note_count = notes.len();
    let compose_open = note_draft.is_some();
    let composer = note_draft.map(|draft| {
        note_compose_sheet(
            ui,
            draft,
            publish_blocked,
            note_publish_pending,
            socket_ready,
        )
    });

    with_sheet(
        column((
            top_bar(
                theme,
                "Shadow Nostr",
                "Timeline",
                Some(feed_scope.detail_text()),
            ),
            controls_section(
                ui,
                account,
                &feed_scope,
                &status,
                note_count,
                filter_text,
                compose_open,
                publish_blocked,
            ),
            feed_section(ui, "Feed", home_feed_empty_message(&feed_scope), notes),
        ))
        .gap(12.0.px()),
        theme,
        composer.map(|view| view.boxed()),
    )
}

fn controls_section(
    ui: UiContext,
    account: Option<ActiveAccount>,
    feed_scope: &FeedScope,
    status: &TimelineStatus,
    note_count: usize,
    filter_text: String,
    compose_open: bool,
    publish_blocked: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    panel(
        theme,
        column((
            row((
                text_field(
                    filter_text,
                    "Filter notes, authors, ids",
                    theme,
                    |app: &mut TimelineApp, value| {
                        app.filter_text = value;
                    },
                )
                .flex(1.0),
                secondary_button("Clear", theme, |app: &mut TimelineApp| {
                    app.filter_text.clear();
                }),
            ))
            .gap(10.0.px())
            .main_axis_alignment(MainAxisAlignment::Start),
            row((
                primary_button("Refresh", theme, |app: &mut TimelineApp| {
                    app.begin_refresh(RefreshSource::Manual);
                }),
                maybe(
                    account.as_ref().map(|_| {
                        secondary_button_state(
                            if compose_open {
                                "Compose open"
                            } else if publish_blocked {
                                "Busy..."
                            } else {
                                "Compose"
                            },
                            theme,
                            if compose_open || publish_blocked {
                                ActionButtonState::Disabled
                            } else {
                                ActionButtonState::Enabled
                            },
                            |app: &mut TimelineApp| {
                                app.open_note_composer();
                            },
                        )
                    }),
                    column(()),
                ),
                maybe(
                    account.as_ref().map(|_| {
                        secondary_button("Account", theme, |app: &mut TimelineApp| {
                            app.open_account();
                        })
                    }),
                    column(()),
                ),
                maybe(
                    account.as_ref().map(|_| {
                        secondary_button("Explore", theme, |app: &mut TimelineApp| {
                            app.open_explore();
                        })
                    }),
                    column(()),
                ),
            ))
            .gap(10.0.px())
            .main_axis_alignment(MainAxisAlignment::Start),
            row((
                status_chip(
                    feed_scope.chip_label(),
                    shadow_sdk::ui::Tone::Neutral,
                    theme,
                ),
                status_chip(status.message.clone(), status.tone, theme),
                caption_text(
                    format!("{note_count} note{} visible", plural_suffix(note_count)),
                    theme,
                ),
            ))
            .gap(10.0.px()),
        ))
        .gap(12.0.px()),
    )
}

fn note_compose_sheet(
    ui: UiContext,
    draft: String,
    publish_blocked: bool,
    note_publish_pending: bool,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let can_publish = socket_ready && !publish_blocked && !draft.trim().is_empty();

    column((
        eyebrow_text("Compose", theme),
        headline_text("New note", theme),
        body_text(
            "Publish a top-level note through the shared account and OS-owned signer. After publish, Shadow opens the new note directly.",
            theme,
        ),
        multiline_editor(
            draft,
            "Write a note.",
            148.0,
            theme,
            |app: &mut TimelineApp, value| {
                app.set_note_draft_content(value);
            },
        ),
        row((
            secondary_button("Close", theme, |app: &mut TimelineApp| {
                app.close_note_composer();
            }),
            primary_button_state(
                if note_publish_pending {
                    "Posting..."
                } else {
                    "Post note"
                },
                theme,
                if can_publish {
                    ActionButtonState::Enabled
                } else {
                    ActionButtonState::Disabled
                },
                |app: &mut TimelineApp| {
                    app.begin_note_publish();
                },
            ),
        ))
        .gap(10.0.px())
        .main_axis_alignment(MainAxisAlignment::Start),
        caption_text(
            if socket_ready {
                "This uses the shared account and the OS-owned signer approval prompt."
            } else {
                "The shared relay engine is unavailable in this session."
            },
            theme,
        ),
    ))
    .gap(10.0.px())
}
