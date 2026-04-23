use std::collections::BTreeSet;

use shadow_sdk::{
    services::nostr::{timeline::NostrExploreProfileEntry, NostrEvent},
    ui::{
        column, maybe, row, ActionButtonState, AsUnit, FlexExt, MainAxisAlignment, Tone,
        UiContext, WidgetView,
    },
};

use super::shared::{feed_section, profile_title, relative_time};
use crate::{plural_suffix, short_id, ActiveAccount, TimelineApp, TimelineStatus};

pub(crate) fn explore_screen(
    ui: UiContext,
    account: Option<ActiveAccount>,
    followed_pubkeys: Vec<String>,
    status: TimelineStatus,
    notes: Vec<NostrEvent>,
    profiles: Vec<NostrExploreProfileEntry>,
    socket_ready: bool,
    sync_pending: bool,
    follow_pending: bool,
) -> impl WidgetView<TimelineApp> {
    let note_count = notes.len();
    column((
        ui.top_bar_with_back(
            "Shadow Nostr",
            "Explore",
            Some(String::from("Real relay notes outside Home.")),
            TimelineApp::pop_route,
        ),
        ui.panel(
            column((
                ui.eyebrow_text("Discovery"),
                ui.body_text(
                    "Explore is where Shadow can show recent relay notes. Following from here updates Home, but Home itself stays follow-only.",
                ),
                row((
                    ui.primary_button_state(
                        if sync_pending {
                            "Fetching..."
                        } else {
                            "Fetch relay notes"
                        },
                        if sync_pending || !socket_ready {
                            ActionButtonState::Disabled
                        } else {
                            ActionButtonState::Enabled
                        },
                        |app: &mut TimelineApp| {
                            app.begin_explore_sync();
                        },
                    ),
                    ui.status_chip(
                        format!("{note_count} note{}", plural_suffix(note_count)),
                        Tone::Neutral,
                    ),
                    ui.status_chip(status.message, status.tone),
                ))
                .gap(10.0.px())
                .main_axis_alignment(MainAxisAlignment::Start),
                ui.caption_text(
                    if socket_ready {
                        "Refresh pulls recent notes from the configured relays into the shared cache."
                    } else {
                        "The shared relay engine is unavailable in this session, so Explore can only show cached notes."
                    },
                ),
            ))
            .gap(10.0.px()),
        ),
        explore_profiles_section(
            ui,
            account,
            followed_pubkeys,
            profiles,
            follow_pending,
            socket_ready,
        ),
        feed_section(
            ui,
            "Recent relay notes",
            "No cached relay notes yet. Fetch relay notes to discover profiles to follow.",
            notes,
        ),
    ))
    .gap(12.0.px())
}

fn explore_profiles_section(
    ui: UiContext,
    account: Option<ActiveAccount>,
    followed_pubkeys: Vec<String>,
    profiles: Vec<NostrExploreProfileEntry>,
    follow_pending: bool,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let followed = followed_pubkeys.into_iter().collect::<BTreeSet<_>>();
    let body = maybe(
        (!profiles.is_empty()).then_some(
            column(
                profiles
                    .into_iter()
                    .map(|profile| {
                        explore_profile_card(
                            ui,
                            account.clone(),
                            followed.contains(&profile.pubkey),
                            profile,
                            follow_pending,
                            socket_ready,
                        )
                    })
                    .collect::<Vec<_>>(),
            )
            .gap(10.0.px()),
        ),
        ui.panel(
            column((
                ui.eyebrow_text("Profiles"),
                ui.caption_text(
                    "Fetch relay notes to discover accounts you can follow from Explore.",
                ),
            ))
            .gap(6.0.px()),
        ),
    );

    column((ui.eyebrow_text("Profiles"), body)).gap(8.0.px())
}

fn explore_profile_card(
    ui: UiContext,
    account: Option<ActiveAccount>,
    is_following: bool,
    profile: NostrExploreProfileEntry,
    follow_pending: bool,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let open_pubkey = profile.pubkey.clone();
    let follow_pubkey = profile.pubkey.clone();
    let is_active_account = account
        .as_ref()
        .is_some_and(|account| account.npub == profile.pubkey);
    let follow_control = if is_active_account {
        ui.status_chip("active account", Tone::Neutral).boxed()
    } else if !socket_ready {
        ui.status_chip("relay engine unavailable", Tone::Neutral).boxed()
    } else if is_following {
        ui.secondary_button_state(
            "Following",
            ActionButtonState::Disabled,
            |_app: &mut TimelineApp| {},
        )
        .boxed()
    } else {
        ui.primary_button_state(
            if follow_pending {
                "Updating..."
            } else {
                "Follow"
            },
            if follow_pending {
                ActionButtonState::Disabled
            } else {
                ActionButtonState::Enabled
            },
            move |app: &mut TimelineApp| {
                app.begin_follow_add_for(follow_pubkey.clone());
            },
        )
        .boxed()
    };

    ui.panel(
        column((
            row((
                column((
                    ui.headline_text(profile_title(&profile.profile, &profile.pubkey)),
                    ui.caption_text(short_id(&profile.pubkey)),
                    profile
                        .profile
                        .nip05
                        .clone()
                        .map(|nip05| ui.caption_text(nip05)),
                ))
                .gap(4.0.px())
                .flex(1.0),
                ui.status_chip(relative_time(profile.updated_at), Tone::Neutral),
            ))
            .gap(10.0.px())
            .main_axis_alignment(MainAxisAlignment::Start),
            ui.caption_text(
                format!(
                    "{} recent note{} cached from this author.",
                    profile.note_count,
                    plural_suffix(profile.note_count)
                ),
            ),
            ui.body_text(profile.latest_note_preview),
            row((
                ui.secondary_button("Open profile", move |app: &mut TimelineApp| {
                    app.open_profile(open_pubkey.clone());
                }),
                follow_control,
            ))
            .gap(10.0.px())
            .main_axis_alignment(MainAxisAlignment::Start),
        ))
        .gap(10.0.px()),
    )
}
