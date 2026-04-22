use shadow_sdk::ui::{
    caption_text, column, eyebrow_text, headline_text, maybe, panel, primary_button_state,
    prose_text, row, secondary_button, secondary_button_state, status_chip, text_field,
    top_bar_with_back, ActionButtonState, AsUnit, FlexExt, MainAxisAlignment, Tone, UiContext,
    WidgetView,
};

use crate::{short_id, ActiveAccount, FeedScope, TimelineApp, TimelineStatus};

pub(crate) fn account_screen(
    ui: UiContext,
    account: Option<ActiveAccount>,
    feed_scope: FeedScope,
    follow_input: String,
    status: TimelineStatus,
    clipboard_pending: bool,
    follow_pending: bool,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    match account {
        Some(account) => column((
            top_bar_with_back(
                theme,
                "Shadow Nostr",
                "Account",
                Some(String::from("Active account for this device.")),
                TimelineApp::pop_route,
            ),
            panel(
                theme,
                column((
                    eyebrow_text("Identity", theme),
                    headline_text("Active account", theme),
                    status_chip(account.source.label(), Tone::Neutral, theme),
                    caption_text("npub", theme),
                    prose_text(account.npub.clone(), 15.0, theme),
                    secondary_button(
                        if clipboard_pending {
                            "Copying npub..."
                        } else {
                            "Copy npub"
                        },
                        theme,
                        |app: &mut TimelineApp| {
                            app.begin_copy_account_npub();
                        },
                    ),
                    follow_manager(
                        ui,
                        &account,
                        &feed_scope,
                        follow_input,
                        follow_pending,
                        socket_ready,
                    ),
                    column((
                        status_chip(feed_scope.chip_label(), Tone::Neutral, theme),
                        status_chip(status.message, status.tone, theme),
                        caption_text(feed_scope.detail_text(), theme),
                        caption_text(
                            "Use the clipboard to move this device identity into another app.",
                            theme,
                        ),
                        caption_text(
                            "Replies and follow updates publish through the shared account and OS-owned signer approval.",
                            theme,
                        ),
                    ))
                    .gap(8.0.px()),
                ))
                .gap(10.0.px()),
            ),
        ))
        .gap(12.0.px())
        .boxed(),
        None => column((
            top_bar_with_back(
                theme,
                "Shadow Nostr",
                "Account",
                Some(String::from("No active account is available.")),
                TimelineApp::pop_route,
            ),
            panel(
                theme,
                column((
                    eyebrow_text("Unavailable", theme),
                    caption_text(
                        "Go back and import an nsec or generate an account first.",
                        theme,
                    ),
                ))
                .gap(6.0.px()),
            ),
        ))
        .gap(12.0.px())
        .boxed(),
    }
}

fn follow_manager(
    ui: UiContext,
    account: &ActiveAccount,
    feed_scope: &FeedScope,
    follow_input: String,
    follow_pending: bool,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let follows = feed_scope.authors.clone().unwrap_or_default();
    panel(
        theme,
        column((
            eyebrow_text("Home feed", theme),
            headline_text("Follow accounts", theme),
            caption_text(
                "Paste an npub or use Explore to add accounts to Home. This publishes a real contact-list event for the shared account.",
                theme,
            ),
            row((
                text_field(
                    follow_input,
                    "Paste npub to follow",
                    theme,
                    |app: &mut TimelineApp, value| {
                        app.follow_input = value;
                    },
                )
                .flex(1.0),
                primary_button_state(
                    if follow_pending {
                        "Updating..."
                    } else {
                        "Follow"
                    },
                    theme,
                    if follow_pending || !socket_ready {
                        ActionButtonState::Disabled
                    } else {
                        ActionButtonState::Enabled
                    },
                    |app: &mut TimelineApp| {
                        app.begin_follow_add();
                    },
                ),
            ))
            .gap(10.0.px())
            .main_axis_alignment(MainAxisAlignment::Start),
            maybe(
                (!follows.is_empty()).then_some(
                    column(
                        follows
                            .into_iter()
                            .map(|npub| follow_row(ui, account, npub, follow_pending, socket_ready))
                            .collect::<Vec<_>>(),
                    )
                    .gap(8.0.px()),
                ),
                caption_text(
                    if socket_ready {
                        "Home is empty until this account follows someone."
                    } else {
                        "Home is empty. Follow updates need the shared relay engine."
                    },
                    theme,
                ),
            ),
        ))
        .gap(10.0.px()),
    )
}

fn follow_row(
    ui: UiContext,
    account: &ActiveAccount,
    npub: String,
    follow_pending: bool,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let open_npub = npub.clone();
    let remove_npub = npub.clone();
    panel(
        theme,
        row((
            column((
                caption_text(short_id(&npub), theme),
                maybe(
                    (npub == account.npub).then_some(caption_text("active account", theme)),
                    caption_text("followed account", theme),
                ),
            ))
            .gap(4.0.px())
            .flex(1.0),
            secondary_button("Open", theme, move |app: &mut TimelineApp| {
                app.open_profile(open_npub.clone());
            }),
            secondary_button_state(
                if follow_pending {
                    "Updating..."
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
                    app.begin_follow_remove(remove_npub.clone());
                },
            ),
        ))
        .gap(10.0.px())
        .main_axis_alignment(MainAxisAlignment::Start),
    )
}
