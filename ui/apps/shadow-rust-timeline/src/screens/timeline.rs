use shadow_sdk::{
    services::nostr::NostrEvent,
    ui::{
        caption_text, column, maybe, panel, primary_button, row, secondary_button, status_chip,
        text_field, top_bar, AsUnit, FlexExt, MainAxisAlignment, UiContext, WidgetView,
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
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let note_count = notes.len();

    column((
        top_bar(
            theme,
            "Shadow Nostr",
            "Timeline",
            Some(feed_scope.detail_text()),
        ),
        controls_section(ui, account, &feed_scope, &status, note_count, filter_text),
        feed_section(ui, "Feed", home_feed_empty_message(&feed_scope), notes),
    ))
    .gap(12.0.px())
}

fn controls_section(
    ui: UiContext,
    account: Option<ActiveAccount>,
    feed_scope: &FeedScope,
    status: &TimelineStatus,
    note_count: usize,
    filter_text: String,
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
