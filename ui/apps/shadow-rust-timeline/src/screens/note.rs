use shadow_sdk::{
    services::nostr::{
        timeline::{NostrProfileSummary, NostrThreadContext},
        NostrEvent,
    },
    ui::{
        column, maybe, row, ActionButtonState, AsUnit, MainAxisAlignment, Tone, UiContext,
        WidgetView,
    },
};

use super::shared::{feed_section, profile_title, relative_time};
use crate::{short_id, ReplyDraft, TimelineApp, TimelineStatus};

pub(super) struct NoteScreenProps {
    pub(super) note: Option<NostrEvent>,
    pub(super) profile: NostrProfileSummary,
    pub(super) thread: NostrThreadContext,
    pub(super) reply_draft: Option<ReplyDraft>,
    pub(super) status: TimelineStatus,
    pub(super) publish_blocked: bool,
    pub(super) reply_publish_pending: bool,
    pub(super) thread_sync_available: bool,
    pub(super) thread_sync_pending: bool,
}

pub(crate) fn note_screen(ui: UiContext, props: NoteScreenProps) -> impl WidgetView<TimelineApp> {
    let NoteScreenProps {
        note,
        profile,
        thread,
        reply_draft,
        status,
        publish_blocked,
        reply_publish_pending,
        thread_sync_available,
        thread_sync_pending,
    } = props;
    let body = match note {
        Some(note) => {
            let note_id = note.id.clone();
            let pubkey = note.pubkey.clone();
            let reply_note_id = note.id.clone();
            let parent = thread.parent.clone();
            let replies = thread.replies.clone();
            let composer = reply_draft.as_ref().map(|draft| {
                reply_sheet(
                    ui,
                    &note,
                    draft.clone(),
                    publish_blocked,
                    reply_publish_pending,
                )
            });
            ui.with_sheet(
                column((
                    ui.top_bar_with_back(
                        "Shadow Nostr",
                        "Thread",
                        Some(format!(
                            "{}  •  {}",
                            profile_title(&profile, &note.pubkey),
                            relative_time(note.created_at)
                        )),
                        TimelineApp::pop_route,
                    ),
                    ui.panel(
                        column((
                            ui.eyebrow_text("Status"),
                            ui.caption_text(status.message.clone()),
                            maybe(
                                thread_sync_available.then_some(if thread_sync_pending {
                                    ui.caption_text(
                                        "Talking to relays for missing thread context.",
                                    )
                                    .boxed()
                                } else {
                                    ui.primary_button(
                                        "Fetch thread",
                                        move |app: &mut TimelineApp| {
                                            app.begin_thread_sync(note_id.clone());
                                        },
                                    )
                                    .boxed()
                                }),
                                ui.caption_text(
                                    "Thread fetch is available when the shared Nostr engine is running.",
                                ),
                            ),
                        ))
                        .gap(8.0.px()),
                    ),
                    maybe(
                        parent.map(|parent| {
                            let parent_id = parent.id.clone();
                            ui.panel(
                                column((
                                    ui.eyebrow_text("Replying to"),
                                    ui.caption_text(
                                        format!(
                                            "{}  •  {}",
                                            short_id(&parent.pubkey),
                                            relative_time(parent.created_at)
                                        ),
                                    ),
                                    ui.prose_text(parent.content, 15.0),
                                    ui.secondary_button(
                                        "Open parent",
                                        move |app: &mut TimelineApp| {
                                            app.open_note(parent_id.clone());
                                        },
                                    ),
                                ))
                                .gap(8.0.px()),
                            )
                        }),
                        ui.panel(
                            column((
                                ui.eyebrow_text("Reply chain"),
                                ui.caption_text("No cached parent note for this entry yet."),
                            ))
                            .gap(6.0.px()),
                        ),
                    ),
                    ui.panel(
                        column((
                            ui.eyebrow_text("Selected note"),
                            ui.headline_text(profile_title(&profile, &note.pubkey)),
                            ui.caption_text(short_id(&note.pubkey)),
                            ui.prose_text(note.content, 17.0),
                            ui.caption_text(format!("event {}", short_id(&note.id))),
                            row((
                                ui.status_chip(relative_time(note.created_at), Tone::Neutral),
                                note.root_event_id.clone().map(|root_id| {
                                    ui.caption_text(format!("root {}", short_id(&root_id)))
                                }),
                            ))
                            .gap(8.0.px()),
                            ui.secondary_button_state(
                                if reply_draft.is_some() {
                                    "Reply draft open"
                                } else if publish_blocked {
                                    "Busy..."
                                } else {
                                    "Reply"
                                },
                                if reply_draft.is_some() || publish_blocked {
                                    ActionButtonState::Disabled
                                } else {
                                    ActionButtonState::Enabled
                                },
                                move |app: &mut TimelineApp| {
                                    app.open_reply_composer(reply_note_id.clone());
                                },
                            ),
                            ui.secondary_button("Open profile", move |app: &mut TimelineApp| {
                                app.open_profile(pubkey.clone());
                            }),
                        ))
                        .gap(10.0.px()),
                    ),
                    feed_section(ui, "Replies", "No cached direct replies yet.", replies),
                ))
                .gap(12.0.px()),
                composer.map(|view| view.boxed()),
            )
        }
        None => column((
            ui.top_bar_with_back(
                "Shadow Nostr",
                "Note",
                Some(String::from("This note is no longer in the shared cache.")),
                TimelineApp::pop_route,
            ),
            ui.panel(
                column((
                    ui.eyebrow_text("Unavailable"),
                    ui.caption_text("Refresh the timeline or go back to pick another note."),
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
    publish_blocked: bool,
    reply_publish_pending: bool,
) -> impl WidgetView<TimelineApp> {
    let note_id = draft.note_id.clone();
    let note_preview = note.content.lines().next().unwrap_or("").trim();
    let note_preview = if note_preview.is_empty() {
        String::from("Write the first reply to this note.")
    } else {
        note_preview.to_owned()
    };
    let can_publish = !publish_blocked && !draft.content.trim().is_empty();

    column((
        ui.eyebrow_text("Reply draft"),
        ui.headline_text("Compose reply"),
        ui.caption_text(format!(
            "Replying to {}  •  {}",
            short_id(&note.pubkey),
            short_id(&note_id)
        )),
        ui.body_text(note_preview),
        ui.multiline_editor(
            draft.content,
            "Write a reply for the shared account and relay engine.",
            148.0,
            |app: &mut TimelineApp, value| {
                app.set_reply_draft_content(value);
            },
        ),
        row((
            ui.secondary_button("Close", |app: &mut TimelineApp| {
                app.close_reply_composer();
            }),
            ui.primary_button_state(
                if reply_publish_pending {
                    "Posting..."
                } else {
                    "Post reply"
                },
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
        ui.caption_text("This uses the shared account and the OS-owned signer approval prompt."),
    ))
    .gap(10.0.px())
}
