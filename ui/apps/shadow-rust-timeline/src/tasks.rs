mod finish;
mod start;

use shadow_sdk::{
    services::{
        clipboard::{run_write_text_task, ClipboardWriteRequest},
        nostr::{
            run_account_task,
            timeline::{
                publish_note_or_reply, run_refresh_home_feed_task, run_sync_explore_feed_task,
                run_sync_thread_task, run_update_contact_list_task,
                NostrContactListUpdateAction, NostrContactListUpdateOutcome,
                NostrContactListUpdateRequest, NostrExploreSyncOutcome, NostrExploreSyncRequest,
                NostrHomeRefreshOutcome, NostrHomeRefreshRequest, NostrThreadSyncOutcome,
                NostrThreadSyncRequest, NostrTimelinePublishRequest,
            },
            NostrAccountSummary, NostrAccountTask, NostrPublishReceipt,
        },
    },
    ui::{with_tasks, TaskHandle, TaskSlot, WidgetView},
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

#[derive(Clone, Debug, Default)]
pub(crate) struct TimelineTasks {
    account_action: TaskSlot<NostrAccountTask>,
    clipboard_write: TaskSlot<ClipboardWriteRequest>,
    explore_sync: TaskSlot<NostrExploreSyncRequest>,
    follow_update: TaskSlot<NostrContactListUpdateRequest>,
    publish: TaskSlot<NostrTimelinePublishRequest>,
    refresh: TaskSlot<NostrHomeRefreshRequest>,
    thread_sync: TaskSlot<NostrThreadSyncRequest>,
}

impl TimelineTasks {
    pub(crate) fn account_action_pending(&self) -> bool {
        self.account_action.is_pending()
    }

    pub(crate) fn clipboard_write_pending(&self) -> bool {
        self.clipboard_write.is_pending()
    }

    pub(crate) fn explore_sync_pending(&self) -> bool {
        self.explore_sync.is_pending()
    }

    pub(crate) fn follow_update_pending(&self) -> bool {
        self.follow_update.is_pending()
    }

    pub(crate) fn pending_follow_update_target(&self) -> Option<&str> {
        self.follow_update
            .pending()
            .map(|pending| follow_update_target(pending.job()))
    }

    pub(crate) fn publish_pending(&self) -> bool {
        self.publish.is_pending()
    }

    pub(crate) fn refresh_pending(&self) -> bool {
        self.refresh.is_pending()
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

    pub(crate) fn thread_sync_pending(&self) -> bool {
        self.thread_sync.is_pending()
    }

    pub(crate) fn start_account_action(&mut self, job: NostrAccountTask) -> bool {
        self.account_action.start(job)
    }

    pub(crate) fn finish_account_action(&mut self, task: TaskHandle<NostrAccountTask>) -> bool {
        self.account_action.finish_handle(task).is_some()
    }

    pub(crate) fn start_clipboard_write(&mut self, job: ClipboardWriteRequest) -> bool {
        self.clipboard_write.start(job)
    }

    pub(crate) fn finish_clipboard_write(
        &mut self,
        task: TaskHandle<ClipboardWriteRequest>,
    ) -> bool {
        self.clipboard_write.finish_handle(task).is_some()
    }

    pub(crate) fn start_explore_sync(&mut self, job: NostrExploreSyncRequest) -> bool {
        self.explore_sync.start(job)
    }

    pub(crate) fn finish_explore_sync(
        &mut self,
        task: TaskHandle<NostrExploreSyncRequest>,
    ) -> bool {
        self.explore_sync.finish_handle(task).is_some()
    }

    pub(crate) fn start_follow_update(&mut self, job: NostrContactListUpdateRequest) -> bool {
        self.follow_update.start(job)
    }

    pub(crate) fn finish_follow_update(
        &mut self,
        task: TaskHandle<NostrContactListUpdateRequest>,
    ) -> Option<NostrContactListUpdateRequest> {
        self.follow_update.finish_handle(task)
    }

    pub(crate) fn start_publish(&mut self, job: NostrTimelinePublishRequest) -> bool {
        self.publish.start(job)
    }

    pub(crate) fn finish_publish(
        &mut self,
        task: TaskHandle<NostrTimelinePublishRequest>,
    ) -> Option<NostrTimelinePublishRequest> {
        self.publish.finish_handle(task)
    }

    pub(crate) fn start_refresh(&mut self, job: NostrHomeRefreshRequest) -> bool {
        self.refresh.start(job)
    }

    pub(crate) fn finish_refresh(&mut self, task: TaskHandle<NostrHomeRefreshRequest>) -> bool {
        self.refresh.finish_handle(task).is_some()
    }

    pub(crate) fn start_thread_sync(&mut self, job: NostrThreadSyncRequest) -> bool {
        self.thread_sync.start(job)
    }

    pub(crate) fn finish_thread_sync(&mut self, task: TaskHandle<NostrThreadSyncRequest>) -> bool {
        self.thread_sync.finish_handle(task).is_some()
    }
}

pub(crate) fn decorate_with_tasks(
    content: impl WidgetView<TimelineApp>,
    tasks: &TimelineTasks,
) -> impl WidgetView<TimelineApp> {
    with_tasks(
        content,
        [
            tasks
                .account_action
                .decoration(run_account_task, TimelineApp::finish_account_action),
            tasks
                .clipboard_write
                .decoration(run_write_text_task, TimelineApp::finish_clipboard_write),
            tasks
                .explore_sync
                .decoration(run_sync_explore_feed_task, TimelineApp::finish_explore_sync),
            tasks
                .follow_update
                .decoration(run_update_contact_list_task, TimelineApp::finish_follow_update),
            tasks
                .thread_sync
                .decoration(run_sync_thread_task, TimelineApp::finish_thread_sync),
            tasks
                .publish
                .decoration(run_publish, TimelineApp::finish_publish),
            tasks
                .refresh
                .decoration(run_refresh_home_feed_task, TimelineApp::finish_refresh),
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
        assert!(tasks.start_follow_update(NostrContactListUpdateRequest {
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
        assert!(tasks.start_follow_update(NostrContactListUpdateRequest {
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
            .finish_follow_update(pending)
            .expect("matching finished follow update");

        assert_eq!(follow_update_target(&finished), "npub-target");
        assert!(!tasks.follow_update_pending());
    }
}
