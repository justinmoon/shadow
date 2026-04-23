use shadow_sdk::{
    services::nostr::{timeline::NostrProfileSummary, NostrEvent},
    ui::{column, maybe, row, ActionButtonState, AsUnit, UiContext, WidgetView},
};

use super::shared::{feed_section, profile_metadata_status, profile_title};
use crate::{plural_suffix, short_id, ActiveAccount, RefreshSource, TimelineApp, TimelineStatus};

pub(super) struct ProfileScreenProps {
    pub(super) account: Option<ActiveAccount>,
    pub(super) pubkey: String,
    pub(super) profile: NostrProfileSummary,
    pub(super) notes: Vec<NostrEvent>,
    pub(super) status: TimelineStatus,
    pub(super) is_following: bool,
    pub(super) follow_pending: bool,
    pub(super) socket_ready: bool,
}

pub(crate) fn profile_screen(
    ui: UiContext,
    props: ProfileScreenProps,
) -> impl WidgetView<TimelineApp> {
    let ProfileScreenProps {
        account,
        pubkey,
        profile,
        notes,
        status,
        is_following,
        follow_pending,
        socket_ready,
    } = props;
    let metadata_status = profile_metadata_status(&profile);
    let note_count = notes.len();
    let follow_button = account.filter(|account| account.npub != pubkey).map(|_| {
        if is_following {
            let unfollow_pubkey = pubkey.clone();
            ui.secondary_button_state(
                if follow_pending {
                    "Updating follows..."
                } else {
                    "Unfollow"
                },
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
            ui.primary_button_state(
                if follow_pending {
                    "Updating follows..."
                } else {
                    "Follow"
                },
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
        ui.top_bar_with_back(
            "Shadow Nostr",
            profile_title(&profile, &pubkey),
            Some(short_id(&pubkey)),
            TimelineApp::pop_route,
        ),
        ui.panel(
            column((
                ui.eyebrow_text("Identity"),
                ui.headline_text(profile_title(&profile, &pubkey)),
                ui.caption_text(short_id(&pubkey)),
                profile.nip05.clone().map(|nip05| ui.caption_text(nip05)),
                profile.about.clone().map(|about| ui.body_text(about)),
                row((
                    ui.status_chip(metadata_status.0, metadata_status.1),
                    ui.status_chip(status.message, status.tone),
                    ui.caption_text(format!(
                        "{note_count} note{} cached",
                        plural_suffix(note_count)
                    )),
                ))
                .gap(10.0.px()),
                ui.primary_button("Refresh", |app: &mut TimelineApp| {
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
