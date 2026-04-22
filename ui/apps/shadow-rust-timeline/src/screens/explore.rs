use std::collections::BTreeSet;

use shadow_sdk::{
    services::nostr::{timeline::NostrExploreProfileEntry, NostrEvent},
    ui::{
        body_text, caption_text, column, eyebrow_text, headline_text, maybe, panel,
        primary_button_state, row, secondary_button, secondary_button_state, status_chip,
        ActionButtonState, AsUnit, FlexExt, MainAxisAlignment, Tone, UiContext, WidgetView,
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
    let theme = ui.theme();
    let note_count = notes.len();
    column((
        shadow_sdk::ui::top_bar_with_back(
            theme,
            "Shadow Nostr",
            "Explore",
            Some(String::from("Real relay notes outside Home.")),
            TimelineApp::pop_route,
        ),
        panel(
            theme,
            column((
                eyebrow_text("Discovery", theme),
                body_text(
                    "Explore is where Shadow can show recent relay notes. Following from here updates Home, but Home itself stays follow-only.",
                    theme,
                ),
                row((
                    primary_button_state(
                        if sync_pending {
                            "Fetching..."
                        } else {
                            "Fetch relay notes"
                        },
                        theme,
                        if sync_pending || !socket_ready {
                            ActionButtonState::Disabled
                        } else {
                            ActionButtonState::Enabled
                        },
                        |app: &mut TimelineApp| {
                            app.begin_explore_sync();
                        },
                    ),
                    status_chip(
                        format!("{note_count} note{}", plural_suffix(note_count)),
                        Tone::Neutral,
                        theme,
                    ),
                    status_chip(status.message, status.tone, theme),
                ))
                .gap(10.0.px())
                .main_axis_alignment(MainAxisAlignment::Start),
                caption_text(
                    if socket_ready {
                        "Refresh pulls recent notes from the configured relays into the shared cache."
                    } else {
                        "The shared relay engine is unavailable in this session, so Explore can only show cached notes."
                    },
                    theme,
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
    let theme = ui.theme();
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
        panel(
            theme,
            column((
                eyebrow_text("Profiles", theme),
                caption_text(
                    "Fetch relay notes to discover accounts you can follow from Explore.",
                    theme,
                ),
            ))
            .gap(6.0.px()),
        ),
    );

    column((eyebrow_text("Profiles", theme), body)).gap(8.0.px())
}

fn explore_profile_card(
    ui: UiContext,
    account: Option<ActiveAccount>,
    is_following: bool,
    profile: NostrExploreProfileEntry,
    follow_pending: bool,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let open_pubkey = profile.pubkey.clone();
    let follow_pubkey = profile.pubkey.clone();
    let is_active_account = account
        .as_ref()
        .is_some_and(|account| account.npub == profile.pubkey);
    let follow_control = if is_active_account {
        status_chip("active account", Tone::Neutral, theme).boxed()
    } else if !socket_ready {
        status_chip("relay engine unavailable", Tone::Neutral, theme).boxed()
    } else if is_following {
        secondary_button_state(
            "Following",
            theme,
            ActionButtonState::Disabled,
            |_app: &mut TimelineApp| {},
        )
        .boxed()
    } else {
        primary_button_state(
            if follow_pending {
                "Updating..."
            } else {
                "Follow"
            },
            theme,
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

    panel(
        theme,
        column((
            row((
                column((
                    headline_text(profile_title(&profile.profile, &profile.pubkey), theme),
                    caption_text(short_id(&profile.pubkey), theme),
                    profile
                        .profile
                        .nip05
                        .clone()
                        .map(|nip05| caption_text(nip05, theme)),
                ))
                .gap(4.0.px())
                .flex(1.0),
                status_chip(relative_time(profile.updated_at), Tone::Neutral, theme),
            ))
            .gap(10.0.px())
            .main_axis_alignment(MainAxisAlignment::Start),
            caption_text(
                format!(
                    "{} recent note{} cached from this author.",
                    profile.note_count,
                    plural_suffix(profile.note_count)
                ),
                theme,
            ),
            body_text(profile.latest_note_preview, theme),
            row((
                secondary_button("Open profile", theme, move |app: &mut TimelineApp| {
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
