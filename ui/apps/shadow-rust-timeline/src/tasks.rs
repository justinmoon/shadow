mod finish;
mod start;

use shadow_sdk::{
    services::{
        clipboard::{run_write_text_task, ClipboardWriteRequest},
        nostr::{
            run_account_task,
            timeline::{
                publish_note_or_reply, run_refresh_home_feed_task, run_sync_explore_feed_task,
                run_sync_thread_task, run_update_contact_list_task, NostrContactListUpdateAction,
                NostrContactListUpdateOutcome, NostrContactListUpdateRequest,
                NostrExploreSyncOutcome, NostrExploreSyncRequest, NostrHomeRefreshOutcome,
                NostrHomeRefreshRequest, NostrThreadSyncOutcome, NostrThreadSyncRequest,
                NostrTimelinePublishRequest,
            },
            NostrAccountSummary, NostrAccountTask, NostrPublishReceipt,
        },
    },
    ui::{with_tasks, TaskSlotBinding, WidgetView},
};

use crate::TimelineApp;

#[derive(Clone, Copy, Debug)]
pub(crate) enum RefreshSource {
    Startup,
    Manual,
    FollowUpdate,
}

pub(crate) type FollowActionKind = NostrContactListUpdateAction;
pub(crate) type RefreshOutcome = NostrHomeRefreshOutcome;
pub(crate) type ExploreSyncOutcome = NostrExploreSyncOutcome;
pub(crate) type ThreadSyncOutcome = NostrThreadSyncOutcome;
pub(crate) type FollowUpdateOutcome = NostrContactListUpdateOutcome;
pub(crate) type PublishOutcome = NostrPublishReceipt;
pub(crate) type AccountActionOutcome = NostrAccountSummary;

type TimelineTask<Job, Output> = TaskSlotBinding<TimelineApp, Job, Output>;

#[derive(Clone, Debug)]
pub(crate) struct TimelineTasks {
    account_action: TimelineTask<NostrAccountTask, AccountActionOutcome>,
    clipboard_write: TimelineTask<ClipboardWriteRequest, ()>,
    explore_sync: TimelineTask<NostrExploreSyncRequest, ExploreSyncOutcome>,
    follow_update: TimelineTask<NostrContactListUpdateRequest, FollowUpdateOutcome>,
    publish: TimelineTask<NostrTimelinePublishRequest, PublishOutcome>,
    refresh: TimelineTask<NostrHomeRefreshRequest, RefreshOutcome>,
    thread_sync: TimelineTask<NostrThreadSyncRequest, ThreadSyncOutcome>,
}

impl Default for TimelineTasks {
    fn default() -> Self {
        Self {
            account_action: TimelineTask::new(run_account_task, TimelineApp::finish_account_action),
            clipboard_write: TimelineTask::new(
                run_write_text_task,
                TimelineApp::finish_clipboard_write,
            ),
            explore_sync: TimelineTask::new(
                run_sync_explore_feed_task,
                TimelineApp::finish_explore_sync,
            ),
            follow_update: TimelineTask::new(
                run_update_contact_list_task,
                TimelineApp::finish_follow_update,
            ),
            publish: TimelineTask::new(run_publish, TimelineApp::finish_publish),
            refresh: TimelineTask::new(run_refresh_home_feed_task, TimelineApp::finish_refresh),
            thread_sync: TimelineTask::new(run_sync_thread_task, TimelineApp::finish_thread_sync),
        }
    }
}

impl TimelineTasks {
    pub(crate) fn pending_follow_update_target(&self) -> Option<&str> {
        self.follow_update
            .pending()
            .map(|pending| follow_update_target(pending.job()))
    }

    pub(crate) fn publish_note_pending(&self) -> bool {
        self.publish
            .pending_matches(NostrTimelinePublishRequest::is_note)
    }

    pub(crate) fn publish_reply_pending_for(&self, note_id: &str) -> bool {
        self.publish.pending_matches(|job| job.is_reply_to(note_id))
    }

    pub(crate) fn follow_update_pending_for(&self, pubkey: &str) -> bool {
        self.follow_update
            .pending_matches(|job| follow_update_target(job) == pubkey)
    }

    pub(crate) fn thread_sync_pending_for(&self, note_id: &str) -> bool {
        self.thread_sync
            .pending_matches(|job| job.note_id == note_id)
    }
}

pub(crate) fn decorate_with_tasks(
    content: impl WidgetView<TimelineApp>,
    tasks: &TimelineTasks,
) -> impl WidgetView<TimelineApp> {
    with_tasks(
        content,
        [
            tasks.account_action.decoration(),
            tasks.clipboard_write.decoration(),
            tasks.explore_sync.decoration(),
            tasks.follow_update.decoration(),
            tasks.thread_sync.decoration(),
            tasks.publish.decoration(),
            tasks.refresh.decoration(),
        ],
    )
}

fn run_publish(job: NostrTimelinePublishRequest) -> Result<PublishOutcome, String> {
    publish_note_or_reply(job).map_err(|error| error.to_string())
}

fn follow_update_target(job: &NostrContactListUpdateRequest) -> &str {
    match &job.action {
        FollowActionKind::Add { npub } | FollowActionKind::Remove { npub } => npub,
    }
}

#[cfg(test)]
mod tests {
    use shadow_sdk::services::nostr::timeline::NostrContactListUpdateRequest;

    use super::{FollowActionKind, TimelineTasks};

    #[test]
    fn follow_update_helpers_track_pending_target() {
        let mut tasks = TimelineTasks::default();
        assert!(tasks.follow_update.start(NostrContactListUpdateRequest {
            account_npub: String::from("npub-account"),
            action: FollowActionKind::Add {
                npub: String::from("npub-target"),
            },
            relay_urls: Vec::new(),
        }));

        assert_eq!(tasks.pending_follow_update_target(), Some("npub-target"));
        assert!(tasks.follow_update_pending_for("npub-target"));
        assert!(!tasks.follow_update_pending_for("npub-other"));
    }

    #[test]
    fn follow_update_finish_returns_matching_pending_job() {
        let mut tasks = TimelineTasks::default();
        assert!(tasks.follow_update.start(NostrContactListUpdateRequest {
            account_npub: String::from("npub-account"),
            action: FollowActionKind::Remove {
                npub: String::from("npub-target"),
            },
            relay_urls: vec![String::from("wss://relay.example")],
        }));

        let pending = tasks
            .follow_update
            .pending_cloned()
            .expect("pending follow update");
        let finished = tasks
            .follow_update
            .finish(pending)
            .expect("matching finished follow update");

        assert_eq!(follow_update_target(&finished), "npub-target");
        assert!(!tasks.follow_update.is_pending());
    }
}
