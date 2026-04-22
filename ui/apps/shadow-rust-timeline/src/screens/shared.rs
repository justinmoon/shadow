use shadow_sdk::{
    services::nostr::{timeline::NostrProfileSummary, NostrEvent},
    ui::{
        caption_text, column, eyebrow_text, maybe, panel, prose_text, row, selectable_card,
        status_chip, AsUnit, Tone, UiContext, WidgetView,
    },
};

use crate::{short_id, TimelineApp};

pub(crate) fn home_feed_empty_message(feed_scope: &crate::FeedScope) -> &'static str {
    match feed_scope.source {
        crate::FeedSource::Following { .. } => {
            "No followed-account notes match the current filter or cache state."
        }
        crate::FeedSource::NoContacts => {
            "Home is empty until this account follows someone. Use Explore or Account to add follows."
        }
        crate::FeedSource::Unavailable => "No active account is available.",
    }
}

pub(crate) fn feed_section(
    ui: UiContext,
    title: &str,
    empty_message: &str,
    notes: Vec<NostrEvent>,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let title = title.to_owned();
    let empty_message = empty_message.to_owned();
    let body = maybe(
        (!notes.is_empty()).then_some(
            column(
                notes
                    .into_iter()
                    .map(|note| note_card(ui, note))
                    .collect::<Vec<_>>(),
            )
            .gap(10.0.px()),
        ),
        panel(
            theme,
            column((
                eyebrow_text(title.clone(), theme),
                caption_text(empty_message, theme),
            ))
            .gap(6.0.px()),
        ),
    );

    column((eyebrow_text(title, theme), body)).gap(8.0.px())
}

pub(crate) fn note_card(ui: UiContext, note: NostrEvent) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let note_id = note.id.clone();

    selectable_card(
        theme,
        false,
        column((
            row((
                caption_text(short_id(&note.pubkey), theme),
                status_chip(relative_time(note.created_at), Tone::Neutral, theme),
            ))
            .gap(8.0.px()),
            prose_text(note.content, 15.0, theme),
        ))
        .gap(8.0.px()),
        move |app: &mut TimelineApp| {
            app.open_note(note_id.clone());
        },
    )
}

pub(crate) fn relative_time(created_at: u64) -> String {
    let Ok(duration) = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) else {
        return created_at.to_string();
    };
    let delta = duration.as_secs().saturating_sub(created_at);
    if delta < 60 {
        return format!("{delta}s");
    }
    if delta < 60 * 60 {
        return format!("{}m", delta / 60);
    }
    if delta < 60 * 60 * 24 {
        return format!("{}h", delta / (60 * 60));
    }
    format!("{}d", delta / (60 * 60 * 24))
}

pub(crate) fn profile_title(profile: &NostrProfileSummary, pubkey: &str) -> String {
    profile
        .display_name
        .clone()
        .unwrap_or_else(|| short_id(pubkey))
}

pub(crate) fn profile_metadata_status(profile: &NostrProfileSummary) -> (&'static str, Tone) {
    if profile.metadata_event_id.is_some() {
        ("metadata cached", Tone::Success)
    } else {
        ("no metadata yet", Tone::Neutral)
    }
}
