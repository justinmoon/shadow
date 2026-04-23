mod account;
mod explore;
mod note;
mod onboarding;
mod profile;
mod shared;
mod timeline;

use shadow_sdk::ui::{UiContext, WidgetView};

use crate::{tasks::FollowActionKind, TimelineApp};

pub(crate) fn route_screen(ui: UiContext, app: &TimelineApp) -> impl WidgetView<TimelineApp> {
    let socket_ready = crate::socket_available();
    let tasks = &app.tasks;
    let pending_follow_npub = tasks
        .follow_update
        .pending_job()
        .map(|job| match &job.action {
            FollowActionKind::Add { npub } | FollowActionKind::Remove { npub } => npub.as_str(),
        })
        .map(str::to_owned);
    match app.current_route() {
        crate::Route::Account => account::account_screen(
            ui,
            account::AccountScreenProps {
                account: app.account.clone(),
                feed_scope: app.cached_data.feed_scope().clone(),
                follow_input: app.follow_input.clone(),
                status: app.status.clone(),
                clipboard_pending: tasks.clipboard_write.is_pending(),
                pending_follow_npub: pending_follow_npub.clone(),
                socket_ready,
            },
        )
        .boxed(),
        crate::Route::Explore => {
            let explore = app.cached_data.explore_state();
            explore::explore_screen(
                ui,
                explore::ExploreScreenProps {
                    account: app.account.clone(),
                    followed_pubkeys: app.current_followed_pubkeys(),
                    status: app.status.clone(),
                    notes: explore.notes,
                    profiles: explore.profiles,
                    socket_ready,
                    sync_pending: tasks.explore_sync.is_pending(),
                    pending_follow_npub: pending_follow_npub.clone(),
                },
            )
            .boxed()
        }
        crate::Route::Onboarding => onboarding::onboarding_screen(
            ui,
            onboarding::OnboardingScreenProps {
                nsec_input: app.nsec_input.clone(),
                status: app.status.clone(),
                action_pending: tasks.account_action.is_pending(),
            },
        )
        .boxed(),
        crate::Route::Timeline => timeline::timeline_screen(
            ui,
            timeline::TimelineScreenProps {
                account: app.account.clone(),
                feed_scope: app.cached_data.feed_scope().clone(),
                status: app.status.clone(),
                notes: app.visible_notes(),
                filter_text: app.filter_text.clone(),
                note_draft: app.note_draft(),
                publish_blocked: tasks.publish.is_pending(),
                note_publish_pending: tasks.publish.pending_matches(|job| job.is_note()),
                socket_ready,
            },
        )
        .boxed(),
        crate::Route::Note { id } => {
            let note_state = app.note_state(&id);
            note::note_screen(
                ui,
                note::NoteScreenProps {
                    note: note_state.note,
                    profile: note_state.profile,
                    thread: note_state.thread,
                    reply_draft: app.reply_draft_for(&id),
                    status: app.status.clone(),
                    publish_blocked: tasks.publish.is_pending(),
                    reply_publish_pending: tasks.publish.pending_matches(|job| job.is_reply_to(&id)),
                    thread_sync_available: socket_ready,
                    thread_sync_pending: tasks
                        .thread_sync
                        .pending_matches(|job| job.note_id == id.as_str()),
                },
            )
            .boxed()
        }
        crate::Route::Profile { pubkey } => {
            let profile_state = app.profile_state(&pubkey);
            profile::profile_screen(
                ui,
                profile::ProfileScreenProps {
                    account: app.account.clone(),
                    pubkey: pubkey.clone(),
                    profile: profile_state.summary,
                    notes: profile_state.notes,
                    status: app.status.clone(),
                    is_following: app.is_following(&pubkey),
                    follow_pending: tasks.follow_update.pending_matches(|job| match &job.action {
                        FollowActionKind::Add { npub } | FollowActionKind::Remove { npub } => {
                            npub == pubkey.as_str()
                        }
                    }),
                    socket_ready,
                },
            )
            .boxed()
        }
    }
}
