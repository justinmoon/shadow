mod account;
mod explore;
mod note;
mod onboarding;
mod profile;
mod shared;
mod timeline;

use shadow_sdk::ui::{UiContext, WidgetView};

use crate::{tasks::TimelineTaskSnapshot, TimelineApp};

pub(crate) fn route_screen(
    ui: UiContext,
    app: &TimelineApp,
    task_snapshot: &TimelineTaskSnapshot,
) -> impl WidgetView<TimelineApp> {
    let socket_ready = crate::socket_available();
    match app.current_route() {
        crate::Route::Account => account::account_screen(
            ui,
            account::AccountScreenProps {
                account: app.account.clone(),
                feed_scope: app.cached_data.feed_scope().clone(),
                follow_input: app.follow_input.clone(),
                status: app.status.clone(),
                clipboard_pending: task_snapshot.clipboard_write.is_pending(),
                follow_pending: task_snapshot.follow_update.is_pending(),
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
                    sync_pending: task_snapshot.explore_sync.is_pending(),
                    follow_pending: task_snapshot.follow_update.is_pending(),
                },
            )
            .boxed()
        }
        crate::Route::Onboarding => onboarding::onboarding_screen(
            ui,
            onboarding::OnboardingScreenProps {
                nsec_input: app.nsec_input.clone(),
                status: app.status.clone(),
                action_pending: task_snapshot.account_action.is_pending(),
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
                publish_blocked: task_snapshot.publish.is_pending(),
                note_publish_pending: task_snapshot.publish_note_pending(),
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
                    publish_blocked: task_snapshot.publish.is_pending(),
                    reply_publish_pending: task_snapshot.publish_reply_pending_for(&id),
                    thread_sync_available: socket_ready,
                    thread_sync_pending: task_snapshot.thread_sync_pending_for(&id),
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
                    follow_pending: app.follow_update_pending_for(&pubkey),
                    socket_ready,
                },
            )
            .boxed()
        }
    }
}
