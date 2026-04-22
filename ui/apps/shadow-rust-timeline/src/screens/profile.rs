use shadow_sdk::{
    services::nostr::{timeline::NostrProfileSummary, NostrEvent},
    ui::{
        body_text, caption_text, column, headline_text, maybe, panel, primary_button,
        primary_button_state, status_chip, top_bar_with_back, ActionButtonState, AsUnit, UiContext,
        WidgetView,
    },
};

use super::shared::{feed_section, profile_metadata_status, profile_title};
use crate::{plural_suffix, short_id, ActiveAccount, RefreshSource, TimelineApp, TimelineStatus};

pub(crate) fn profile_screen(
    ui: UiContext,
    account: Option<ActiveAccount>,
    pubkey: String,
    profile: NostrProfileSummary,
    notes: Vec<NostrEvent>,
    status: TimelineStatus,
    is_following: bool,
    follow_pending: bool,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let metadata_status = profile_metadata_status(&profile);
    let note_count = notes.len();
    let follow_button = account.filter(|account| account.npub != pubkey).map(|_| {
        if is_following {
            let unfollow_pubkey = pubkey.clone();
            shadow_sdk::ui::secondary_button_state(
                if follow_pending {
                    "Updating follows..."
                } else {
                    "Unfollow"
                },
                theme,
                if follow_pending || !socket_ready {
                    ActionButtonState::Disabled
                } else {
                    ActionButtonState::Enabled
                },
                move |app: &mut TimelineApp| {
                    app.begin_follow_remove(unfollow_pubkey.clone());
                },
            )
            .boxed()
        } else {
            let follow_pubkey = pubkey.clone();
            primary_button_state(
                if follow_pending {
                    "Updating follows..."
                } else {
                    "Follow"
                },
                theme,
                if follow_pending || !socket_ready {
                    ActionButtonState::Disabled
                } else {
                    ActionButtonState::Enabled
                },
                move |app: &mut TimelineApp| {
                    app.follow_input = follow_pubkey.clone();
                    app.begin_follow_add();
                },
            )
            .boxed()
        }
    });

    column((
        top_bar_with_back(
            theme,
            "Shadow Nostr",
            profile_title(&profile, &pubkey),
            Some(short_id(&pubkey)),
            TimelineApp::pop_route,
        ),
        panel(
            theme,
            column((
                shadow_sdk::ui::eyebrow_text("Identity", theme),
                headline_text(profile_title(&profile, &pubkey), theme),
                caption_text(short_id(&pubkey), theme),
                profile
                    .nip05
                    .clone()
                    .map(|nip05| caption_text(nip05, theme)),
                profile.about.clone().map(|about| body_text(about, theme)),
                shadow_sdk::ui::row((
                    status_chip(metadata_status.0, metadata_status.1, theme),
                    status_chip(status.message, status.tone, theme),
                    caption_text(
                        format!("{note_count} note{} cached", plural_suffix(note_count)),
                        theme,
                    ),
                ))
                .gap(10.0.px()),
                primary_button("Refresh", theme, |app: &mut TimelineApp| {
                    app.begin_refresh(RefreshSource::Manual);
                }),
                maybe(follow_button, column(())),
            ))
            .gap(10.0.px()),
        ),
        feed_section(
            ui,
            "Recent notes",
            "This author has no cached kind-1 notes yet.",
            notes,
        ),
    ))
    .gap(12.0.px())
}
