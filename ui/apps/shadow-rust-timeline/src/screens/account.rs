use shadow_sdk::ui::{
    column, maybe, row, ActionButtonState, AsUnit, FlexExt, MainAxisAlignment, Tone, UiContext,
    WidgetView,
};

use crate::{short_id, ActiveAccount, FeedScope, TimelineApp, TimelineStatus};

pub(super) struct AccountScreenProps {
    pub(super) account: Option<ActiveAccount>,
    pub(super) feed_scope: FeedScope,
    pub(super) follow_input: String,
    pub(super) status: TimelineStatus,
    pub(super) clipboard_pending: bool,
    pub(super) pending_follow_npub: Option<String>,
    pub(super) socket_ready: bool,
}

pub(crate) fn account_screen(
    ui: UiContext,
    props: AccountScreenProps,
) -> impl WidgetView<TimelineApp> {
    let AccountScreenProps {
        account,
        feed_scope,
        follow_input,
        status,
        clipboard_pending,
        pending_follow_npub,
        socket_ready,
    } = props;
    match account {
        Some(account) => column((
            ui.top_bar_with_back(
                "Shadow Nostr",
                "Account",
                Some(String::from("Active account for this device.")),
                TimelineApp::pop_route,
            ),
            ui.panel(
                column((
                    ui.eyebrow_text("Identity"),
                    ui.headline_text("Active account"),
                    ui.status_chip(account.source.label(), Tone::Neutral),
                    ui.caption_text("npub"),
                    ui.prose_text(account.npub.clone(), 15.0),
                    ui.secondary_button(
                        if clipboard_pending {
                            "Copying npub..."
                        } else {
                            "Copy npub"
                        },
                        |app: &mut TimelineApp| {
                            app.begin_copy_account_npub();
                        },
                    ),
                    follow_manager(
                        ui,
                        &account,
                        &feed_scope,
                        follow_input,
                        pending_follow_npub,
                        socket_ready,
                    ),
                    column((
                        ui.status_chip(feed_scope.chip_label(), Tone::Neutral),
                        ui.status_chip(status.message, status.tone),
                        ui.caption_text(feed_scope.detail_text()),
                        ui.caption_text(
                            "Use the clipboard to move this device identity into another app.",
                        ),
                        ui.caption_text(
                            "Replies and follow updates publish through the shared account and OS-owned signer approval.",
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
            ui.top_bar_with_back(
                "Shadow Nostr",
                "Account",
                Some(String::from("No active account is available.")),
                TimelineApp::pop_route,
            ),
            ui.panel(
                column((
                    ui.eyebrow_text("Unavailable"),
                    ui.caption_text(
                        "Go back and import an nsec or generate an account first.",
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
    pending_follow_npub: Option<String>,
    socket_ready: bool,
) -> impl WidgetView<TimelineApp> {
    let follows = feed_scope.authors.clone().unwrap_or_default();
    let follow_input_pending = pending_follow_npub
        .as_deref()
        .is_some_and(|pending| pending == follow_input.trim());
    ui.panel(
        column((
            ui.eyebrow_text("Home feed"),
            ui.headline_text("Follow accounts"),
            ui.caption_text(
                "Paste an npub or use Explore to add accounts to Home. This publishes a real contact-list event for the shared account.",
            ),
            row((
                ui.text_field(
                    follow_input,
                    "Paste npub to follow",
                    |app: &mut TimelineApp, value| {
                        app.follow_input = value;
                    },
                )
                .flex(1.0),
                ui.primary_button_state(
                    if follow_input_pending {
                        "Updating..."
                    } else {
                        "Follow"
                    },
                    if follow_input_pending || !socket_ready {
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
                        follows.into_iter().map(|npub| {
                            let follow_pending = pending_follow_npub
                                .as_deref()
                                .is_some_and(|pending| pending == npub.as_str());
                            follow_row(ui, account, npub, follow_pending, socket_ready)
                        })
                        .collect::<Vec<_>>(),
                    )
                    .gap(8.0.px()),
                ),
                ui.caption_text(
                    if socket_ready {
                        "Home is empty until this account follows someone."
                    } else {
                        "Home is empty. Follow updates need the shared relay engine."
                    },
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
    let open_npub = npub.clone();
    let remove_npub = npub.clone();
    ui.panel(
        row((
            column((
                ui.caption_text(short_id(&npub)),
                maybe(
                    (npub == account.npub).then_some(ui.caption_text("active account")),
                    ui.caption_text("followed account"),
                ),
            ))
            .gap(4.0.px())
            .flex(1.0),
            ui.secondary_button("Open", move |app: &mut TimelineApp| {
                app.open_profile(open_npub.clone());
            }),
            ui.secondary_button_state(
                if follow_pending {
                    "Updating..."
                } else {
                    "Unfollow"
                },
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
