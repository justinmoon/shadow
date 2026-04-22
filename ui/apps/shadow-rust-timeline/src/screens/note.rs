use shadow_sdk::{
    services::nostr::{
        timeline::{NostrProfileSummary, NostrThreadContext},
        NostrEvent,
    },
    ui::{
        body_text, caption_text, column, eyebrow_text, headline_text, maybe, multiline_editor,
        panel, primary_button, primary_button_state, prose_text, row, secondary_button,
        secondary_button_state, status_chip, top_bar_with_back, with_sheet, ActionButtonState,
        AsUnit, MainAxisAlignment, Tone, UiContext, WidgetView,
    },
};

use super::shared::{feed_section, profile_title, relative_time};
use crate::{short_id, ReplyDraft, TimelineApp, TimelineStatus};

pub(crate) fn note_screen(
    ui: UiContext,
    note: Option<NostrEvent>,
    profile: NostrProfileSummary,
    thread: NostrThreadContext,
    reply_draft: Option<ReplyDraft>,
    status: TimelineStatus,
    publish_pending: bool,
    thread_sync_available: bool,
    thread_sync_pending: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let body = match note {
        Some(note) => {
            let note_id = note.id.clone();
            let pubkey = note.pubkey.clone();
            let reply_note_id = note.id.clone();
            let parent = thread.parent.clone();
            let replies = thread.replies.clone();
            let composer = reply_draft
                .as_ref()
                .map(|draft| reply_sheet(ui, &note, draft.clone(), publish_pending));
            with_sheet(
                column((
                    top_bar_with_back(
                        theme,
                        "Shadow Nostr",
                        "Thread",
                        Some(format!(
                            "{}  •  {}",
                            profile_title(&profile, &note.pubkey),
                            relative_time(note.created_at)
                        )),
                        TimelineApp::pop_route,
                    ),
                    panel(
                        theme,
                        column((
                            eyebrow_text("Status", theme),
                            caption_text(status.message.clone(), theme),
                            maybe(
                                thread_sync_available.then_some(if thread_sync_pending {
                                    caption_text(
                                        "Talking to relays for missing thread context.",
                                        theme,
                                    )
                                    .boxed()
                                } else {
                                    primary_button(
                                        "Fetch thread",
                                        theme,
                                        move |app: &mut TimelineApp| {
                                            app.begin_thread_sync(note_id.clone());
                                        },
                                    )
                                    .boxed()
                                }),
                                caption_text(
                                    "Thread fetch is available when the shared Nostr engine is running.",
                                    theme,
                                ),
                            ),
                        ))
                        .gap(8.0.px()),
                    ),
                    maybe(
                        parent.map(|parent| {
                            let parent_id = parent.id.clone();
                            panel(
                                theme,
                                column((
                                    eyebrow_text("Replying to", theme),
                                    caption_text(
                                        format!(
                                            "{}  •  {}",
                                            short_id(&parent.pubkey),
                                            relative_time(parent.created_at)
                                        ),
                                        theme,
                                    ),
                                    prose_text(parent.content, 15.0, theme),
                                    secondary_button(
                                        "Open parent",
                                        theme,
                                        move |app: &mut TimelineApp| {
                                            app.open_note(parent_id.clone());
                                        },
                                    ),
                                ))
                                .gap(8.0.px()),
                            )
                        }),
                        panel(
                            theme,
                            column((
                                eyebrow_text("Reply chain", theme),
                                caption_text("No cached parent note for this entry yet.", theme),
                            ))
                            .gap(6.0.px()),
                        ),
                    ),
                    panel(
                        theme,
                        column((
                            eyebrow_text("Selected note", theme),
                            headline_text(profile_title(&profile, &note.pubkey), theme),
                            caption_text(short_id(&note.pubkey), theme),
                            prose_text(note.content, 17.0, theme),
                            caption_text(format!("event {}", short_id(&note.id)), theme),
                            row((
                                status_chip(relative_time(note.created_at), Tone::Neutral, theme),
                                note.root_event_id.clone().map(|root_id| {
                                    caption_text(format!("root {}", short_id(&root_id)), theme)
                                }),
                            ))
                            .gap(8.0.px()),
                            secondary_button_state(
                                if reply_draft.is_some() {
                                    "Reply draft open"
                                } else {
                                    "Reply"
                                },
                                theme,
                                if reply_draft.is_some() {
                                    ActionButtonState::Disabled
                                } else {
                                    ActionButtonState::Enabled
                                },
                                move |app: &mut TimelineApp| {
                                    app.open_reply_composer(reply_note_id.clone());
                                },
                            ),
                            secondary_button("Open profile", theme, move |app: &mut TimelineApp| {
                                app.open_profile(pubkey.clone());
                            }),
                        ))
                        .gap(10.0.px()),
                    ),
                    feed_section(ui, "Replies", "No cached direct replies yet.", replies),
                ))
                .gap(12.0.px()),
                theme,
                composer.map(|view| view.boxed()),
            )
        }
        None => column((
            top_bar_with_back(
                theme,
                "Shadow Nostr",
                "Note",
                Some(String::from("This note is no longer in the shared cache.")),
                TimelineApp::pop_route,
            ),
            panel(
                theme,
                column((
                    eyebrow_text("Unavailable", theme),
                    caption_text(
                        "Refresh the timeline or go back to pick another note.",
                        theme,
                    ),
                ))
                .gap(6.0.px()),
            ),
        ))
        .gap(12.0.px())
        .boxed(),
    };

    body
}

fn reply_sheet(
    ui: UiContext,
    note: &NostrEvent,
    draft: ReplyDraft,
    publish_pending: bool,
) -> impl WidgetView<TimelineApp> {
    let theme = ui.theme();
    let note_id = draft.note_id.clone();
    let note_preview = note.content.lines().next().unwrap_or("").trim();
    let note_preview = if note_preview.is_empty() {
        String::from("Write the first reply to this note.")
    } else {
        note_preview.to_owned()
    };
    let can_publish = !publish_pending && !draft.content.trim().is_empty();

    column((
        eyebrow_text("Reply draft", theme),
        headline_text("Compose reply", theme),
        caption_text(
            format!(
                "Replying to {}  •  {}",
                short_id(&note.pubkey),
                short_id(&note_id)
            ),
            theme,
        ),
        body_text(note_preview, theme),
        multiline_editor(
            draft.content,
            "Write a reply for the shared account and relay engine.",
            148.0,
            theme,
            |app: &mut TimelineApp, value| {
                app.set_reply_draft_content(value);
            },
        ),
        row((
            secondary_button("Close", theme, |app: &mut TimelineApp| {
                app.close_reply_composer();
            }),
            primary_button_state(
                if publish_pending {
                    "Posting..."
                } else {
                    "Post reply"
                },
                theme,
                if can_publish {
                    ActionButtonState::Enabled
                } else {
                    ActionButtonState::Disabled
                },
                |app: &mut TimelineApp| {
                    app.begin_reply_publish();
                },
            ),
        ))
        .gap(10.0.px())
        .main_axis_alignment(MainAxisAlignment::Start),
        caption_text(
            "This uses the shared account and the OS-owned signer approval prompt.",
            theme,
        ),
    ))
    .gap(10.0.px())
}
